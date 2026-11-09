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

test_expect_success 'setup prefixed checkout with racy stat data' '
	test_create_repo prefixed &&
	(
		cd prefixed &&
		mkdir out &&
		echo right >out/file &&
		git --work-tree=out add file &&
		# Force content comparisons without depending on the clock.
		test-tool chmtime =1 .git/index
	)
'

test_expect_success 'prefixed checkout with missing source' '
	git -C prefixed checkout-index --prefix=out/ file &&
	test_path_is_missing prefixed/file
'

test_expect_success 'prefixed checkout with unrelated source' '
	test_when_finished "rm -f prefixed/file" &&
	echo wrong >prefixed/file &&
	git -C prefixed checkout-index --prefix=out/ file
'

test_expect_success PIPE,PERL 'prefixed checkout with FIFO source' '
	test_when_finished "rm -f prefixed/file" &&
	mkfifo prefixed/file &&
	# Bound the writer even if checkout never opens the FIFO.
	{
		perl -e '\''
			$SIG{ALRM} = sub { exit 0 };
			alarm 10;
			open my $out, ">", "prefixed/file" or die $!;
			print $out "wrong\n";
		'\'' &
	} &&
	writer_pid=$! &&
	test_when_finished "kill $writer_pid 2>/dev/null; wait $writer_pid 2>/dev/null || :" &&
	git -C prefixed checkout-index --prefix=out/ file
'

test_expect_success 'prefixed checkout detects racy destination changes' '
	test_create_repo prefixed-dirty &&
	(
		cd prefixed-dirty &&
		git config core.trustctime false &&
		mkdir out &&
		echo right >out/file &&
		test-tool chmtime =1234567890 out/file &&
		git --work-tree=out add file &&
		test-tool chmtime =1 .git/index &&
		cp out/file file &&
		echo wrong >out/file &&
		test-tool chmtime =1234567890 out/file &&
		test_must_fail git checkout-index --prefix=out/ file &&
		git checkout-index --force --prefix=out/ file &&
		test_cmp file out/file
	)
'

test_expect_success 'prefixed content comparison uses indexed filter attributes' '
	test_create_repo prefixed-filter &&
	(
		cd prefixed-filter &&
		git config filter.lower.clean "tr A-Z a-z" &&
		git config filter.lower.smudge "tr a-z A-Z" &&
		git config filter.reject.clean "echo wrong" &&
		mkdir out &&
		echo RIGHT >out/file &&
		echo "file filter=lower" >out/.gitattributes &&
		git --work-tree=out add file &&
		test-tool chmtime =1 .git/index &&
		cat >.gitattributes <<-\EOF &&
		/file filter=lower
		/out/file filter=reject
		EOF
		git checkout-index --prefix=out/ file &&
		echo RIGHT >expect &&
		test_cmp expect out/file
	)
'

test_expect_success SYMLINKS 'prefixed checkout compares destination symlink' '
	test_create_repo prefixed-link &&
	(
		cd prefixed-link &&
		mkdir out &&
		ln -s right out/link &&
		git --work-tree=out add link &&
		test-tool chmtime =1 .git/index &&
		ln -s wrong link &&
		git checkout-index --prefix=out/ link &&
		test "$(test_readlink out/link)" = right
	)
'

test_expect_success 'prefixed checkout compares destination gitlink' '
	test_create_repo prefixed-gitlink &&
	(
		cd prefixed-gitlink &&
		test_create_repo sub &&
		git -C sub commit --allow-empty -m first &&
		first=$(git -C sub rev-parse HEAD) &&
		mkdir out &&
		git clone sub out/sub &&
		git -C sub commit --allow-empty -m second &&
		second=$(git -C sub rev-parse HEAD) &&
		git update-index --add --cacheinfo 160000,$first,sub &&
		git checkout-index --prefix=out/ sub &&
		git update-index --cacheinfo 160000,$second,sub &&
		test_must_fail git checkout-index --prefix=out/ sub
	)
'

for gitdir_type in directory file
do
	test_expect_success "setup gitlink prefix paths with .git $gitdir_type" '
		test_create_repo "gitlink-prefix-$gitdir_type" &&
		(
			cd "gitlink-prefix-$gitdir_type" &&
			test_create_repo sub &&
			git -C sub commit --allow-empty -m first &&
			git -C sub commit --allow-empty -m second &&
			mkdir out &&
			git clone sub out/sub &&
			if test "$gitdir_type" = file
			then
				git -C out/sub init --separate-git-dir=../sub.git &&
				echo "gitdir: ../sub.git" >out/sub/.git
			fi &&
			git -C sub commit --allow-empty -m third &&
			git update-index --add --cacheinfo \
				160000,$(git -C sub rev-parse HEAD~2),sub
		)
	'

	test_expect_success "absolute gitlink prefix with .git $gitdir_type" '
		(
			cd "gitlink-prefix-$gitdir_type" &&
			# Neither repository has the indexed commit checked out.
			git update-index --cacheinfo \
				160000,$(git -C sub rev-parse HEAD~2),sub &&
			test_must_fail git checkout-index --prefix="$PWD/out/" sub 2>err &&
			test_grep "sub already exists, no checkout" err &&
			git update-index --cacheinfo \
				160000,$(git -C out/sub rev-parse HEAD),sub &&
			git checkout-index --prefix="$PWD/out/" sub
		)
	'

	test_expect_success SYMLINKS "symlinked gitlink prefix with .git $gitdir_type" '
		(
			cd "gitlink-prefix-$gitdir_type" &&
			first=$(git -C sub rev-parse HEAD~2) &&
			git -C sub reset --hard HEAD~1 &&
			ln -s out via &&
			git update-index --cacheinfo \
				160000,$(git -C out/sub rev-parse HEAD),sub &&
			git checkout-index --prefix=via/ sub &&
			git update-index --cacheinfo 160000,$first,sub &&
			test_must_fail git checkout-index --prefix=via/ sub 2>err &&
			test_grep "sub already exists, no checkout" err
		)
	'
done

test_expect_success 'prefixed checkout ignores source fsmonitor validity' '
	test_create_repo prefixed-fsmonitor &&
	(
		cd prefixed-fsmonitor &&
		echo right >file &&
		git add file &&
		write_script .git/hooks/fsmonitor-test <<-\EOF &&
		printf "token\0"
		EOF
		git config core.fsmonitor .git/hooks/fsmonitor-test &&
		git update-index --fsmonitor --fsmonitor-valid file &&
		git ls-files -f >actual &&
		echo "h file" >expect &&
		test_cmp expect actual &&
		mkdir out &&
		echo wrong >out/file &&
		test_must_fail git checkout-index --prefix=out/ file &&
		git checkout-index --force --prefix=out/ file &&
		test_cmp file out/file
	)
'

test_done

