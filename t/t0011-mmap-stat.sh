#!/bin/sh

test_description='stat data for files with writable shared mappings'

. ./test-lib.sh

test_lazy_prereq STAT_GEN_COUNT '
	test_have_prereq MACOS &&
	test-tool genzeros 16384 >probe &&
	test-tool mmap unreliable probe >actual &&
	test "$(cat actual)" = 0
'

stop_mapper () {
	printf "quit\n" >&9 &&
	exec 9>&- &&
	exec 8<&- &&
	wait "$mapper_pid" &&
	rm -f commands replies
}

start_mapper () {
	git reset --quiet HEAD -- plain &&
	git show HEAD:plain >plain &&
	test-tool chmtime -10 plain &&
	git update-index --refresh &&
	start_mapping "$1" plain
}

start_mapping () {
	mkfifo commands replies &&
	{
		test-tool mmap "$1" "$2" <commands >replies &
	} &&
	mapper_pid=$! &&
	exec 9>commands &&
	exec 8<replies &&
	test_when_finished stop_mapper &&
	read -r reply <&8 &&
	test "$reply" = ready
}

mapper () {
	printf "%s\n" "$1" >&9 &&
	read -r reply <&8 &&
	test "$reply" = "$2"
}

check_dirty () {
	test_must_fail git diff-files --quiet -- plain &&
	test_must_fail git diff --quiet -- plain &&
	printf "%s plain\n" "${1- M}" >expect &&
	git status --porcelain --untracked-files=no -- plain >actual &&
	test_cmp expect actual
}

test_expect_success STAT_GEN_COUNT 'setup ordinary files with non-racy timestamps' '
	test-tool genzeros 16384 >plain &&
	test-tool chmtime -10 plain &&
	echo other >other &&
	git add plain other &&
	git commit -m baseline
'

test_expect_success STAT_GEN_COUNT 'generation query rejects a different inode' '
	test-tool mmap unreliable plain >actual &&
	test "$(cat actual)" = 0 &&
	test-tool mmap identity plain >actual &&
	test "$(cat actual)" = 1
'

test_expect_success STAT_GEN_COUNT 'a failed generation query is not trusted' '
	test-tool mmap unreliable missing >actual &&
	test "$(cat actual)" = 1
'

test_expect_success STAT_GEN_COUNT 'an unchanged shared mapping is clean' '
	start_mapper shared &&
	test-tool mmap unreliable plain >actual &&
	test "$(cat actual)" = 1 &&
	git diff --exit-code -- plain &&
	git status --porcelain --untracked-files=no -- plain >actual &&
	test_must_be_empty actual
'

test_expect_success STAT_GEN_COUNT 'mapped content comparison applies clean filters' '
	start_mapper shared &&
	test_when_finished "rm -f .git/info/attributes" &&
	echo "plain filter=mmap" >.git/info/attributes &&
	write_script clean-filter <<-\EOF &&
	tr B "\000"
	EOF
	test_config filter.mmap.clean ./clean-filter &&
	mapper "write B" written &&
	git rev-parse :plain >expect &&
	git hash-object --no-filters plain >actual &&
	test "$(cat expect)" != "$(cat actual)" &&
	git diff --exit-code -- plain
'

test_expect_success STAT_GEN_COUNT 'diff and status detect mmap writes with unchanged timestamps' '
	start_mapper shared &&
	mapper "write B" written &&
	mapper stat unchanged &&
	check_dirty
'

test_expect_success STAT_GEN_COUNT 'index refresh does not hide a subsequent mapped write' '
	start_mapper shared &&
	mapper "write B" written &&
	git add plain &&
	git diff --exit-code -- plain &&
	mapper "write C" written &&
	mapper stat unchanged &&
	check_dirty MM
'

test_expect_success STAT_GEN_COUNT 'a shared mapping that can gain write protection is checked' '
	start_mapper upgrade &&
	test-tool mmap unreliable plain >actual &&
	test "$(cat actual)" = 1 &&
	mapper protect writable &&
	mapper "write B" written &&
	mapper stat unchanged &&
	check_dirty
'

test_expect_success STAT_GEN_COUNT 'private writes do not modify the file' '
	start_mapper private &&
	git rev-parse :plain >expect &&
	mapper "write B" written &&
	git hash-object --path=plain plain >actual &&
	test_cmp expect actual &&
	git diff --exit-code -- plain
'

test_expect_success STAT_GEN_COUNT 'read-only mappings remain clean' '
	start_mapper readonly &&
	git diff --exit-code -- plain
'

test_expect_success STAT_GEN_COUNT 'assume-unchanged remains an explicit opt-out' '
	start_mapper shared &&
	test_when_finished "git update-index --no-assume-unchanged plain" &&
	git update-index --assume-unchanged plain &&
	mapper "write B" written &&
	git diff --exit-code -- plain &&
	git status --porcelain --untracked-files=no -- plain >actual &&
	test_must_be_empty actual
'

test_expect_success STAT_GEN_COUNT 'skip-worktree remains an explicit opt-out' '
	start_mapper shared &&
	test_when_finished "git update-index --no-skip-worktree plain" &&
	git update-index --skip-worktree plain &&
	mapper "write B" written &&
	git diff --exit-code -- plain &&
	git status --porcelain --untracked-files=no -- plain >actual &&
	test_must_be_empty actual
'

test_expect_success STAT_GEN_COUNT 'fsmonitor validity does not hide mapped writes' '
	start_mapper shared &&
	write_script fsmonitor-hook <<-\EOF &&
	printf "token\0"
	EOF
	test_config core.fsmonitor ./fsmonitor-hook &&
	test_config core.fsmonitorHookVersion 2 &&
	git update-index --fsmonitor &&
	git update-index --fsmonitor-valid plain &&
	git ls-files -f plain >actual &&
	test_grep "^h plain$" actual &&
	mapper "write B" written &&
	mapper stat unchanged &&
	check_dirty
'

test_expect_success STAT_GEN_COUNT 'preloading the index does not hide mapped writes' '
	start_mapper shared &&
	mapper "write B" written &&
	mapper stat unchanged &&
	test_must_fail env GIT_TEST_PRELOAD_INDEX=1 git diff --exit-code -- plain >actual &&
	test_file_not_empty actual
'

test_expect_success STAT_GEN_COUNT 'prefixed checkout compares mapped destination bytes' '
	test_when_finished "rm -rf out" &&
	mkdir out &&
	git show HEAD:plain >plain &&
	git show HEAD:plain >out/plain &&
	test-tool chmtime -10 out/plain &&
	git --work-tree=out add plain &&
	start_mapping shared out/plain &&
	write_script fsmonitor-hook <<-\EOF &&
	printf "token\0"
	EOF
	test_config core.fsmonitor ./fsmonitor-hook &&
	test_config core.fsmonitorHookVersion 2 &&
	git update-index --fsmonitor &&
	git update-index --fsmonitor-valid plain &&
	git checkout-index --prefix=out/ plain &&
	mapper "write B" written &&
	mapper stat unchanged &&
	test_must_fail git checkout-index --prefix=out/ plain
'

test_expect_success STAT_GEN_COUNT 'prefixed comparison uses the indexed path for clean filters' '
	test_when_finished "rm -rf out; rm -f .git/info/attributes" &&
	mkdir out &&
	git show HEAD:plain >out/plain &&
	test-tool chmtime -10 out/plain &&
	git --work-tree=out add plain &&
	start_mapping shared out/plain &&
	write_script clean-filter <<-\EOF &&
	tr B "\000"
	EOF
	test_config filter.mmap.clean ./clean-filter &&
	printf "%s\n" "plain filter=mmap" "out/plain -filter" >.git/info/attributes &&
	mapper "write B" written &&
	git checkout-index --prefix=out/ plain
'

test_done
