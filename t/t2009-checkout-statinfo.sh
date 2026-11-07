#!/bin/sh

test_description='checkout should leave clean stat info'

GIT_TEST_DEFAULT_INITIAL_BRANCH_NAME=main
export GIT_TEST_DEFAULT_INITIAL_BRANCH_NAME

. ./test-lib.sh

test_expect_success 'setup' '

	echo hello >world &&
	git update-index --add world &&
	git commit -m initial &&
	git branch side &&
	echo goodbye >world &&
	git update-index --add world &&
	git commit -m second

'

test_expect_success 'branch switching' '

	git reset --hard &&
	test "$(git diff-files --raw)" = "" &&

	git checkout main &&
	test "$(git diff-files --raw)" = "" &&

	git checkout side &&
	test "$(git diff-files --raw)" = "" &&

	git checkout main &&
	test "$(git diff-files --raw)" = ""

'

test_expect_success 'path checkout' '

	git reset --hard &&
	test "$(git diff-files --raw)" = "" &&

	git checkout main world &&
	test "$(git diff-files --raw)" = "" &&

	git checkout side world &&
	test "$(git diff-files --raw)" = "" &&

	git checkout main world &&
	test "$(git diff-files --raw)" = ""

'

test_expect_success 'prefixed checkout checks the destination when the source is absent' '
	test_create_repo prefixed &&
	(
		cd prefixed &&
		mkdir out &&
		echo right >out/file &&
		test-tool chmtime -10 out/file &&
		git --work-tree=out add file &&
		git checkout-index --prefix=out/ file &&
		test_path_is_missing file
	)
'

test_expect_success 'prefixed checkout does not compare an unrelated source file' '
	test_when_finished "rm -f prefixed/file" &&
	echo wrong >prefixed/file &&
	git -C prefixed checkout-index --prefix=out/ file
'

test_expect_success PIPE 'prefixed checkout does not read an unrelated FIFO' '
	test_when_finished "rm -f prefixed/file" &&
	mkfifo prefixed/file &&
	{
		printf "wrong\n" >prefixed/file &
	} &&
	writer_pid=$! &&
	test_when_finished "kill $writer_pid 2>/dev/null; wait $writer_pid 2>/dev/null || :" &&
	git -C prefixed checkout-index --prefix=out/ file
'

test_done

