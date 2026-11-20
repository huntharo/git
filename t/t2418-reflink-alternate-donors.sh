#!/bin/sh

test_description='bounded automatic reflink donors and preservation of clone groups'
. ./test-lib.sh
. "$TEST_DIRECTORY"/lib-reflink.sh



inode () {
	test-tool reflink metadata "$1" | sed "/^birth /d" | awk "{print \$2}"
}


test_expect_success 'setup automatic main plus retained old donor' '
	git init -q auto/main &&
	git -C auto/main config checkout.reflink true &&
	make_blob_file auto/main/file 64 old &&
	echo old >auto/main/other &&
	git -C auto/main add . &&
	git -C auto/main commit -qm old &&
	git -C auto/main tag old &&
	reflink_stable_source auto/main &&
	git -C auto/main worktree add -q --reflink --detach ../B old &&
	git -C auto/main worktree add -q --reflink -b a ../A old &&
	reflink_stable_source auto/B &&
	reflink_stable_source auto/A &&
	make_blob_file auto/main/file 64 new &&
	git -C auto/main commit -qam new &&
	reflink_stable_source auto/main
'

test_expect_success REFLINK 'main losing the old extent leaves A and B shared' '
	test_not_shared auto/main/file auto/A/file &&
	test_shared auto/A/file auto/B/file &&
	inode auto/A/file >before.inode &&
	git -C auto/A switch -q a &&
	git -C auto/A reset -q --hard &&
	inode auto/A/file >after.inode &&
	test_cmp before.inode after.inode &&
	test_shared auto/A/file auto/B/file &&
	test_cmp auto/A/file auto/B/file
'

test_expect_success REFLINK 'other-file branch transitions preserve the existing clone inode' '
	echo changed >auto/B/other &&
	git -C auto/B commit -qam other-only &&
	git -C auto/B branch other-only &&
	inode auto/A/file >before.inode &&
	git -C auto/A switch -q other-only &&
	git -C auto/A reset -q --hard a &&
	inode auto/A/file >after.inode &&
	test_cmp before.inode after.inode &&
	test_shared auto/A/file auto/B/file &&
	git -C auto/A diff-files --exit-code &&
	reflink_stable_source auto/B
'

for workers in 1 8
do
	test_expect_success REFLINK "creation finds retained blob outside main ($workers workers)" '
		test_when_finished "git -C auto/main worktree remove -f ../new" &&
		rm -f trace.json &&
		GIT_TRACE2_EVENT="$TRACE_JSON" \
		git -C auto/main -c checkout.workers=$workers \
			-c checkout.thresholdForParallelism=0 \
			worktree add -q --reflink --detach ../new old &&
		test_shared auto/B/file auto/new/file &&
		test_cmp auto/B/file auto/new/file &&
		git -C auto/new diff-files --exit-code
	'

	test_expect_success REFLINK "missing and dirty rewrites find alternate donor ($workers workers)" '
		for how in missing dirty
		do
			if test "$how" = missing
			then rm auto/A/file
			else echo dirty >auto/A/file
			fi &&
			git -C auto/A -c checkout.workers=$workers \
				-c checkout.thresholdForParallelism=0 reset -q --hard &&
			test_shared auto/B/file auto/A/file &&
			test_cmp auto/B/file auto/A/file &&
			git -C auto/A diff-files --exit-code || return 1
		done
	'
done

test_expect_success REFLINK 'explicit CLI, marker and configured sources remain single-source' '
	test_when_finished "git -C auto/main worktree remove -f ../explicit" &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" \
	git -C auto/main worktree add -q --reflink-source="$(pwd)/auto/main" \
		--detach ../explicit old &&
	test_not_shared auto/B/file auto/explicit/file &&
	test_reflink_count alternate-enumeration 0 trace.json &&
	rm auto/explicit/file &&
	git -C auto/explicit checkout -- file &&
	test_not_shared auto/B/file auto/explicit/file &&
	rm auto/A/file trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" \
	git -C auto/A -c checkout.reflinkSource="$(pwd)/auto/main" checkout -- file &&
	test_not_shared auto/A/file auto/B/file &&
	test_reflink_count alternate-enumeration 0 trace.json
'

test_expect_success REFLINK 'alternate donors retain dirty and racy eligibility checks' '
	git -C auto/main worktree remove -f ../A &&
	echo dirty >auto/B/file &&
	git -C auto/main worktree add -q --reflink --detach ../A old &&
	test_not_shared auto/A/file auto/B/file &&
	git -C auto/B -c checkout.reflink=false reset -q --hard &&
	# A future file mtime is racy against the newly written real index timestamp.
	test-tool chmtime +60 auto/B/file &&
	git -C auto/B update-index --refresh &&
	rm auto/A/file &&
	git -C auto/A checkout -- file &&
	test_not_shared auto/A/file auto/B/file
'

test_expect_success REFLINK 'repeated misses read at most four alternate indexes in deterministic order' '
	git init -q bounded/main &&
	make_blob_file bounded/main/file 64 old &&
	cp bounded/main/file bounded/main/second &&
	git -C bounded/main add . &&
	git -C bounded/main commit -qm old &&
	git -C bounded/main tag old &&
	make_blob_file bounded/main/file 64 new &&
	cp bounded/main/file bounded/main/second &&
	git -C bounded/main commit -qam new &&
	for name in d c b a
	do
		git -C bounded/main worktree add -q --no-reflink --detach ../$name HEAD || return 1
	done &&
	git -C bounded/main worktree add -q --no-reflink --detach ../z old &&
	reflink_stable_source bounded/z &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" git -C bounded/main \
		worktree add -q --reflink --detach ../target old &&
	test_reflink_count alternate-enumeration 1 trace.json &&
	test_reflink_count alternate-index-read 4 trace.json &&
	test_reflink_count alternate-lookup 8 trace.json &&
	test_write_lines a b c d >expect.sources &&
	sed -n "s/.*\"key\":\"alternate-source\",\"value\":\"\([^\"]*\)\".*/\1/p" trace.json |
		sed "s|.*/||" >actual.sources &&
	test_cmp expect.sources actual.sources &&
	test_not_shared bounded/z/file bounded/target/file &&
	# An explicit selection can reach beyond the bounded automatic set.
	rm bounded/target/file &&
	git -C bounded/target -c checkout.reflinkSource="$(pwd)/bounded/z" checkout -- file &&
	test_shared bounded/z/file bounded/target/file
'

test_expect_success REFLINK 'automatic main hit never initializes alternate search' '
	test_when_finished "git -C bounded/main worktree remove -f ../fast" &&
	reflink_stable_source bounded/main &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" git -C bounded/main \
		worktree add -q --reflink --detach ../fast HEAD &&
	test_reflink_count alternate-enumeration 0 trace.json &&
	test_reflink_count alternate-index-read 0 trace.json &&
	test_shared bounded/main/file bounded/fast/file
'

test_expect_success 'setup same-size historical representation with a later correct donor' '
	git init -q representation/main &&
	git -C representation/main config extensions.worktreeConfig true &&
	make_blob_file representation/main/file 64 raw &&
	git -C representation/main add . &&
	git -C representation/main commit -qm raw &&
	git -C representation/main worktree add -q --no-reflink --detach ../B &&
	reflink_stable_source representation/B &&
	git -C representation/main config --worktree core.attributesFile "$TRASH_DIRECTORY/representation.attrs" &&
	git -C representation/main config --worktree filter.rot13.clean "tr A-Za-z N-ZA-Mn-za-m" &&
	git -C representation/main config --worktree filter.rot13.smudge "tr A-Za-z N-ZA-Mn-za-m" &&
	echo "file filter=rot13" >representation.attrs &&
	rm representation/main/file &&
	git -C representation/main checkout-index -fu --all &&
	# Age/refresh while normalization still proves the donor clean.
	reflink_stable_source representation/main &&
	>representation.attrs &&
	! cmp -s representation/main/file representation/B/file
'

for workers in 1 8
do
	test_expect_success REFLINK "checkout retries a wrong same-size primary snapshot ($workers workers)" '
		test_when_finished "git -C representation/main worktree remove -f ../target" &&
		rm -f trace.json &&
		GIT_TRACE2_EVENT="$TRACE_JSON" git -C representation/main \
			-c checkout.workers=$workers -c checkout.thresholdForParallelism=0 \
			worktree add -q --reflink --detach ../target &&
		test_reflink_count verify-failed 1 trace.json &&
		test_reflink_count cloned 1 trace.json &&
		test_shared representation/B/file representation/target/file &&
		test_cmp representation/B/file representation/target/file
	'
done

test_expect_success REFLINK 'alternate index failures are cached and later donors remain eligible' '
	git -C representation/main worktree add -q --no-reflink --detach ../A &&
	bad_index=$(git -C representation/A rev-parse --absolute-git-dir)/index &&
	printf broken >"$bad_index" &&
	test_when_finished "git -C representation/main worktree remove -f ../A" &&
	test_when_finished "git -C representation/main worktree remove -f ../target" &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" git -C representation/main \
		worktree add -q --reflink --detach ../target &&
	test_shared representation/B/file representation/target/file &&
	test_reflink_count alternate-index-read 2 trace.json
'

test_expect_success REFLINK,SYMLINKS 'alternate donor leading directories stay confined' '
	git init -q leading/main &&
	mkdir leading/main/dir &&
	make_blob_file leading/main/dir/file 64 old &&
	git -C leading/main add . &&
	git -C leading/main commit -qm old &&
	git -C leading/main tag old &&
	git -C leading/main worktree add -q --no-reflink --detach ../B &&
	reflink_stable_source leading/B &&
	mv leading/B/dir leading/held &&
	ln -s ../held leading/B/dir &&
	make_blob_file leading/main/dir/file 64 new &&
	git -C leading/main commit -qam new &&
	inode leading/held/file >before.inode &&
	git -C leading/main worktree add -q --reflink --detach ../target old &&
	test_not_shared leading/held/file leading/target/dir/file &&
	inode leading/held/file >after.inode &&
	test_cmp before.inode after.inode &&
	git -C leading/target diff-files --exit-code
'

test_done
