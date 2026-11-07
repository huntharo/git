#!/bin/sh

test_description='reflink checkout uses the ordinary stat cache'
. ./test-lib.sh
. "$TEST_DIRECTORY"/lib-reflink.sh

test_expect_success 'setup non-racy source' '
	git config checkout.workers 1 &&
	make_blob_file a 128 &&
	make_blob_file b 128 &&
	git add a b &&
	git commit -qm base &&
	reflink_stable_source
'

test_expect_success REFLINK 'raw snapshot comparison reads each cloned byte' '
	test_when_finished "git worktree remove -f measured" &&
	GIT_TRACE2_EVENT="$TRACE_JSON" \
	git worktree add -q --detach --reflink measured &&
	test_reflink_count output-compared 2 trace.json &&
	test_reflink_count output-read-bytes 262144 trace.json &&
	test_shared a measured/a &&
	test_shared b measured/b
'

for workers in 1 8
do
	test_expect_success REFLINK "no-op operations preserve inodes and extents ($workers workers)" '
		test_when_finished "git worktree remove -f wt" &&
		git -c checkout.workers=$workers -c checkout.thresholdForParallelism=0 \
			worktree add -q --detach --reflink wt &&
		test_shared a wt/a &&
		test_shared b wt/b &&
		ls -di wt/a wt/b >before &&
		test-tool reflink private-bytes wt >before.usage &&
		# Disable cloning, so a rewrite cannot be hidden by re-sharing.
		git -C wt -c checkout.reflink=false status --porcelain >status &&
		test_must_be_empty status &&
		git -C wt -c checkout.reflink=false reset -q --hard &&
		git -C wt -c checkout.reflink=false checkout -- . &&
		git -C wt -c checkout.reflink=false restore . &&
		git -C wt -c checkout.reflink=false checkout-index -af &&
		git -C wt -c checkout.reflink=false switch -q --detach HEAD &&
		ls -di wt/a wt/b >after &&
		test-tool reflink private-bytes wt >after.usage &&
		test_cmp before after &&
		test_cmp before.usage after.usage &&
		test_shared a wt/a &&
		test_shared b wt/b &&
		test_cmp a wt/a &&
		test_cmp b wt/b
	'

	test_expect_success REFLINK "racy source falls back with correct contents ($workers workers)" '
		test_when_finished "git worktree remove -f wt; reflink_stable_source" &&
		# Future mtimes are racy with both second and nanosecond indexes.
		test-tool chmtime =+10 a b &&
		git update-index --refresh &&
		rm -f trace.json &&
		GIT_TRACE2_EVENT="$TRACE_JSON" \
		git -c checkout.workers=$workers -c checkout.thresholdForParallelism=0 \
			worktree add -q --detach --reflink wt &&
		test_reflink_count source-dirty 2 trace.json &&
		test_reflink_count cloned 0 trace.json &&
		test_cmp a wt/a &&
		test_cmp b wt/b &&
		test_not_shared a wt/a &&
		git -C wt diff-files --quiet
	'
done

test_expect_success REFLINK 'assume-unchanged does not admit a dirty donor' '
	test_when_finished "git worktree remove -f wt; git update-index --no-assume-unchanged a; git checkout -- a; reflink_stable_source" &&
	git update-index --assume-unchanged a &&
	echo dirty >>a &&
	git worktree add -q --detach --reflink wt &&
	git show HEAD:a >expect &&
	test_cmp expect wt/a &&
	test_not_shared a wt/a &&
	test_shared b wt/b
'

test_expect_success REFLINK 'source worktree filter config does not leak converted bytes' '
	test_when_finished "rm -rf filtered-source filtered-wt plain-wt" &&
	git init -q filtered-source &&
	git -C filtered-source config extensions.worktreeConfig true &&
	git -C filtered-source config --worktree filter.rot13.clean \
		"tr A-Za-z N-ZA-Mn-za-m" &&
	git -C filtered-source config --worktree filter.rot13.smudge \
		"tr A-Za-z N-ZA-Mn-za-m" &&
	echo "a filter=rot13" >filtered-source/.gitattributes &&
	make_blob_file filtered-source/a 128 &&
	git -C filtered-source add . &&
	git -C filtered-source commit -qm filtered &&
	reflink_stable_source filtered-source &&
	git -C filtered-source worktree add -q --detach --no-checkout \
		--no-reflink ../plain-wt &&
	git -C filtered-source worktree add -q --detach --no-checkout \
		--reflink ../filtered-wt &&
	# worktree add copies config.worktree; remove the inherited drivers.
	git -C plain-wt config --worktree --remove-section filter.rot13 &&
	git -C filtered-wt config --worktree --remove-section filter.rot13 &&
	git -C plain-wt -c checkout.reflink=false reset -q --hard &&
	git -C filtered-wt reset -q --hard &&
	# The driver exists only in the source. The recipient writes raw blobs.
	git -C filtered-source show HEAD:a >expect &&
	test_cmp expect filtered-wt/a &&
	test_cmp plain-wt/a filtered-wt/a &&
	test_not_shared filtered-source/a filtered-wt/a &&
	git -C filtered-wt diff-files --quiet
'

test_done
