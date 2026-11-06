#!/bin/sh

test_description='reflink checkout: sharing survives later operations

A worktree made with "git worktree add --reflink" keeps cloning from
its reflink source in later checkouts: switching branches, reset --hard,
restore, checkout-index, rebase, fast-forward merges and pulls. Files
whose content the reflink source does not have are written the ordinary
way. Parallel checkout clones in its workers, and nothing a user sees
(output, hooks, progress) depends on whether a file was cloned.
'

. ./test-lib.sh
. "$TEST_DIRECTORY"/lib-reflink.sh
. "$TEST_DIRECTORY"/lib-parallel-checkout.sh

# The files of the "src" branch that are big enough for test_shared.
big_files="a b c dir/e"

# traced <git command>: run it with a fresh trace2 event trace in trace.json
traced () {
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" "$@"
}

# shared_with_source <worktree> <path>...: each <path> in <worktree>
# shares its data blocks with the same path in the main worktree.
shared_with_source () {
	wt=$1 &&
	shift &&
	for p in "$@"
	do
		test_shared "$wt/$p" "$p" || return 1
	done
}

# add_wt <worktree> <commit> <option>...: "git worktree add" with
# <option>s, removed (with a branch named after it, if one was made)
# when the test ends.
add_wt () {
	wt=$1 &&
	commit=$2 &&
	shift 2 &&
	test_when_finished "git worktree remove -f $wt &&
		{ git branch -D $wt >/dev/null 2>&1 || :; }" &&
	git worktree add -q "$@" "$wt" "$commit"
}

test_expect_success 'setup' '
	git symbolic-ref HEAD refs/heads/src &&
	git config checkout.workers 1 &&
	mkdir dir &&
	for f in $big_files
	do
		make_blob_file $f 64 "$f-1" || return 1
	done &&
	test_write_lines 1 2 3 4 5 6 7 8 9 10 >m &&
	git add . &&
	git commit -q -m base &&
	git tag base &&

	make_blob_file a 64 a-2 &&
	test_write_lines one 2 3 4 5 6 7 8 9 10 >m &&
	git commit -q -a -m src &&

	git checkout -q -b other &&
	make_blob_file a 64 a-3 &&
	make_blob_file b 64 b-3 &&
	make_blob_file d 64 d-3 &&
	git rm -q c &&
	git add a b d &&
	git commit -q -m other &&
	git checkout -q src &&

	# scratch files of the tests below
	cat >>.git/info/exclude <<-\EOF &&
	/wt*
	/trace*
	/counters
	/*.count
	/*.tree
	/*.index
	/*.status
	/*.out
	/*.err
	/expect*
	/actual*
	EOF
	git status --porcelain >actual &&
	test_must_be_empty actual
'

test_expect_success REFLINK 'switch away and back clones again' '
	add_wt wt-switch src --reflink -b wt-switch &&
	shared_with_source wt-switch $big_files &&

	traced git -C wt-switch switch -q other &&
	test_reflink_count cloned 0 trace.json &&
	test_reflink_count no-donor 3 trace.json &&
	test_not_shared wt-switch/a a &&
	test_not_shared wt-switch/b b &&
	shared_with_source wt-switch dir/e &&

	traced git -C wt-switch switch -q wt-switch &&
	test_reflink_count cloned 3 trace.json &&
	test_reflink_count no-donor 0 trace.json &&
	shared_with_source wt-switch $big_files &&
	test_same_as_checkout wt-switch src &&
	test "$(git symbolic-ref HEAD)" = refs/heads/src
'

# unaware_git <arg>...: run git the way a version without reflink
# checkout would: every file it writes is written the ordinary way. (Such
# a git ignores checkout.reflink and the reflink-source file.)
unaware_git () {
	git -c checkout.reflink=false "$@"
}

test_expect_success REFLINK 'a reflink-unaware git unshares only the files it writes' '
	add_wt wt-unaware src --reflink --detach &&
	shared_with_source wt-unaware $big_files &&

	unaware_git -C wt-unaware checkout -q --detach other &&
	shared_with_source wt-unaware dir/e &&
	unaware_git -C wt-unaware checkout -q --detach src &&
	# a, b and c are back to what the source has, but private copies
	test_not_shared wt-unaware/a a &&
	test_not_shared wt-unaware/b b &&
	test_not_shared wt-unaware/c c &&
	shared_with_source wt-unaware dir/e &&
	test_same_as_checkout wt-unaware src
'

test_expect_success REFLINK 'a later reflink-aware checkout reshares what it writes' '
	add_wt wt-mixed src --reflink --detach &&
	unaware_git -C wt-mixed checkout -q --detach other &&
	unaware_git -C wt-mixed checkout -q --detach src &&

	# nothing to write, so the private copies stay private
	traced git -C wt-mixed checkout -q --detach src &&
	test_reflink_count cloned 0 trace.json &&
	test_not_shared wt-mixed/a a &&

	# base differs from src in a and m: those are written, and cloned
	unaware_git -C wt-mixed checkout -q --detach base &&
	traced git -C wt-mixed checkout -q --detach src &&
	test_reflink_count cloned 2 trace.json &&
	shared_with_source wt-mixed a dir/e &&
	test_not_shared wt-mixed/b b &&
	test_not_shared wt-mixed/c c &&
	test_same_as_checkout wt-mixed src
'

test_expect_success REFLINK 'reset --hard after edits clones the reset files' '
	add_wt wt-reset src --reflink --detach &&
	echo dirty >>wt-reset/a &&
	rm wt-reset/b &&
	echo dirty >wt-reset/dir/e &&
	traced git -C wt-reset reset -q --hard &&
	test_reflink_count cloned 3 trace.json &&
	shared_with_source wt-reset $big_files &&
	test_same_as_checkout wt-reset src
'

test_expect_success REFLINK 'restore and checkout -- <path> clone again' '
	add_wt wt-restore src --reflink --detach &&
	echo dirty >>wt-restore/a &&
	rm wt-restore/b &&
	traced git -C wt-restore restore a b &&
	test_reflink_count cloned 2 trace.json &&
	shared_with_source wt-restore a b &&

	echo dirty >>wt-restore/c &&
	rm wt-restore/dir/e &&
	traced git -C wt-restore checkout -- c dir/e &&
	test_reflink_count cloned 2 trace.json &&
	shared_with_source wt-restore $big_files &&
	test_same_as_checkout wt-restore src
'

test_expect_success REFLINK 'checkout-index -f -a and -u clone' '
	add_wt wt-ci src --reflink --detach &&
	echo dirty >>wt-ci/a &&
	echo dirty >>wt-ci/b &&
	rm wt-ci/c &&
	traced git -C wt-ci checkout-index -f -a &&
	test_reflink_count cloned 3 trace.json &&
	shared_with_source wt-ci $big_files &&
	# without -u the index does not know the new files yet
	git -C wt-ci update-index -q --refresh &&

	rm wt-ci/a wt-ci/dir/e &&
	traced git -C wt-ci checkout-index -u -a &&
	test_reflink_count cloned 2 trace.json &&
	shared_with_source wt-ci $big_files &&
	git -C wt-ci diff-files --exit-code &&

	rm wt-ci/b &&
	traced git -C wt-ci checkout-index -u -- b &&
	test_reflink_count cloned 1 trace.json &&
	shared_with_source wt-ci b &&
	test_same_as_checkout wt-ci src
'

test_expect_success REFLINK 'rebase onto the source branch clones its files' '
	add_wt wt-rebase base --reflink -b wt-rebase &&
	make_blob_file wt-rebase/t 64 t-local &&
	git -C wt-rebase add t &&
	git -C wt-rebase commit -q -m local &&
	traced git -C wt-rebase rebase -q src &&
	test_reflink_count cloned 2 trace.json &&
	test_reflink_count no-donor 1 trace.json &&
	shared_with_source wt-rebase $big_files &&
	git -C wt-rebase cat-file blob HEAD:t >expect &&
	test_cmp expect wt-rebase/t &&
	test_same_as_checkout wt-rebase wt-rebase
'

test_expect_success REFLINK 'merge --ff-only clones what the source has' '
	add_wt wt-ff base --reflink -b wt-ff &&
	test_not_shared wt-ff/a a &&
	traced git -C wt-ff merge -q --ff-only src &&
	test_reflink_count cloned 2 trace.json &&
	shared_with_source wt-ff $big_files &&
	test_same_as_checkout wt-ff src
'

test_expect_success REFLINK 'pull from the repository itself clones what the source has' '
	add_wt wt-pull base --reflink -b wt-pull &&
	traced git -C wt-pull pull -q --ff-only . src &&
	test_reflink_count cloned 2 trace.json &&
	shared_with_source wt-pull $big_files &&
	test_same_as_checkout wt-pull src
'

test_expect_success REFLINK 'merge writes new content normally, clones the rest' '
	add_wt wt-merge base --reflink -b wt-merge &&
	test_write_lines 1 2 3 4 5 6 7 8 9 ten >wt-merge/m &&
	make_blob_file wt-merge/u 64 u-local &&
	git -C wt-merge add m u &&
	git -C wt-merge commit -q -m local &&
	traced git -C wt-merge merge -q --no-edit src &&
	test_reflink_count cloned 1 trace.json &&
	test_reflink_count no-donor 1 trace.json &&
	shared_with_source wt-merge $big_files &&
	test_write_lines one 2 3 4 5 6 7 8 9 ten >expect &&
	test_cmp expect wt-merge/m &&
	git -C wt-merge cat-file blob HEAD:u >expect &&
	test_cmp expect wt-merge/u &&
	test_same_as_checkout wt-merge wt-merge
'

test_expect_success 'operations in a reflink worktree give the usual result' '
	add_wt wt-fallback base --reflink -b wt-fallback &&
	git -C wt-fallback switch -q other &&
	test_same_as_checkout wt-fallback other &&
	git -C wt-fallback switch -q wt-fallback &&
	test_same_as_checkout wt-fallback base &&

	echo dirty >>wt-fallback/a &&
	rm wt-fallback/b &&
	git -C wt-fallback reset -q --hard src &&
	test_same_as_checkout wt-fallback src &&

	echo dirty >>wt-fallback/a &&
	rm wt-fallback/b &&
	git -C wt-fallback restore a &&
	git -C wt-fallback checkout -- b &&
	test_same_as_checkout wt-fallback src &&

	echo dirty >>wt-fallback/c &&
	git -C wt-fallback checkout-index -f -u -a &&
	test_same_as_checkout wt-fallback src &&

	git -C wt-fallback reset -q --hard base &&
	test_write_lines 1 2 3 4 5 6 7 8 9 ten >wt-fallback/m &&
	git -C wt-fallback commit -q -a -m local &&
	git -C wt-fallback rebase -q src &&
	test_same_as_checkout wt-fallback wt-fallback &&

	git -C wt-fallback reset -q --hard base &&
	git -C wt-fallback pull -q --ff-only . src &&
	test_same_as_checkout wt-fallback src
'

test_expect_success 'parallel checkout in a reflink worktree gives the usual result' '
	add_wt wt-pfallback base --reflink -b wt-pfallback &&
	git -C wt-pfallback -c checkout.workers=4 \
		-c checkout.thresholdForParallelism=0 switch -q other &&
	test_same_as_checkout wt-pfallback other
'

test_expect_success REFLINK 'parallel checkout clones in the workers' '
	traced git -c checkout.workers=4 -c checkout.thresholdForParallelism=0 \
		worktree add -q --reflink -b wt-par wt-par src &&
	test_when_finished "git worktree remove -f wt-par && git branch -D wt-par" &&
	test_reflink_count cloned 5 trace.json &&
	# each of the 4 workers cloned, the parent did not
	grep "\"category\":\"reflink\",\"name\":\"cloned\"" trace.json >counters &&
	test_line_count = 4 counters &&
	shared_with_source wt-par $big_files &&
	test_same_as_checkout wt-par src &&

	git -C wt-par switch -q other &&
	traced git -C wt-par -c checkout.workers=4 \
		-c checkout.thresholdForParallelism=0 switch -q wt-par &&
	test_reflink_count cloned 3 trace.json &&
	shared_with_source wt-par $big_files &&
	test_same_as_checkout wt-par src
'

test_expect_success 'reflink does not change the number of checkout workers' '
	test_when_finished "git worktree remove -f wt-pw-r &&
		git worktree remove -f wt-pw-n" &&
	test_checkout_workers 4 git -c checkout.workers=4 \
		-c checkout.thresholdForParallelism=0 \
		worktree add -q --reflink --detach wt-pw-r src &&
	test_checkout_workers 4 git -c checkout.workers=4 \
		-c checkout.thresholdForParallelism=0 \
		worktree add -q --no-reflink --detach wt-pw-n src &&

	test_checkout_workers 3 git -C wt-pw-r -c checkout.workers=4 \
		-c checkout.thresholdForParallelism=0 switch -q --detach other &&
	test_checkout_workers 3 git -C wt-pw-n -c checkout.workers=4 \
		-c checkout.thresholdForParallelism=0 switch -q --detach other &&

	test_checkout_workers 0 git -C wt-pw-r -c checkout.workers=4 \
		-c checkout.thresholdForParallelism=100 switch -q --detach src &&
	test_checkout_workers 0 git -C wt-pw-n -c checkout.workers=4 \
		-c checkout.thresholdForParallelism=100 switch -q --detach src
'

# run_ops <worktree>: run checkouts in <worktree>, saving what they
# print to <worktree>.out and <worktree>.err.
run_ops () {
	(
		cd "$1" &&
		exec >../"$1".out 2>../"$1".err &&
		GIT_PROGRESS_DELAY=0 &&
		export GIT_PROGRESS_DELAY &&
		echo "== switch --progress" &&
		git switch --progress --detach other &&
		echo "== switch" &&
		git switch --detach src &&
		echo "== checkout --progress ." &&
		echo dirty >>a &&
		rm b &&
		git checkout --progress . &&
		echo "== checkout <paths>" &&
		rm a c &&
		git checkout a b c &&
		echo "== checkout <commit> <paths>" &&
		echo dirty >>c &&
		rm dir/e &&
		git checkout src a c dir/e &&
		echo "== checkout -- <paths>" &&
		rm a &&
		git checkout -- a &&
		echo "== restore" &&
		rm dir/e &&
		git restore dir/e &&
		echo "== checkout --progress <commit>" &&
		git checkout --progress --detach other &&
		echo "== checkout <commit>" &&
		git checkout --detach src &&
		echo "== reset --hard" &&
		echo dirty >>a &&
		rm c &&
		git reset --hard &&
		echo "== reset --hard <commit>" &&
		git reset --hard other &&
		git reset --hard src &&
		echo "== checkout-index" &&
		rm a b &&
		git checkout-index -a &&
		git status --porcelain
	)
}

test_expect_success 'output and hooks are the same with and without reflink' '
	test_hook post-checkout <<-\EOF &&
	echo "post-checkout $*" >>"$(git rev-parse --git-dir)/hook.log" &&
	git status --porcelain >>"$(git rev-parse --git-dir)/hook.log"
	EOF
	add_wt wt-out-r src --reflink --detach &&
	add_wt wt-out-n src --no-reflink --detach &&
	rm -f trace.json &&
	(
		GIT_TRACE2_EVENT="$TRACE_JSON" &&
		export GIT_TRACE2_EVENT &&
		run_ops wt-out-r
	) &&
	if test_have_prereq REFLINK
	then
		test_reflink_count cloned 21 trace.json
	fi &&
	run_ops wt-out-n &&
	test_cmp wt-out-n.out wt-out-r.out &&
	test_cmp wt-out-n.err wt-out-r.err &&

	test_grep "Updating files: 100% (4/4), done" wt-out-r.err &&
	cat >expect <<-EOF &&
	Updated 2 paths from the index
	Updated 2 paths from the index
	Updated 2 paths from $(git rev-parse --short src^{tree})
	EOF
	grep "^Updated" wt-out-r.err >actual &&
	test_cmp expect actual &&

	test_cmp .git/worktrees/wt-out-n/hook.log .git/worktrees/wt-out-r/hook.log &&
	src=$(git rev-parse src) &&
	other=$(git rev-parse other) &&
	cat >expect <<-EOF &&
	post-checkout $ZERO_OID $src 1
	post-checkout $src $other 1
	post-checkout $other $src 1
	post-checkout $src $src 0
	post-checkout $src $src 0
	post-checkout $src $src 0
	post-checkout $src $src 0
	post-checkout $src $src 0
	post-checkout $src $other 1
	post-checkout $other $src 1
	EOF
	test_cmp expect .git/worktrees/wt-out-r/hook.log &&
	test_same_as_checkout wt-out-r src
'

test_done
