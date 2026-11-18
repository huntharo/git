#!/bin/sh

test_description='verified checkout and re-share with real Git LFS'

. ./test-lib.sh
. "$TEST_DIRECTORY"/lib-reflink.sh

test_lazy_prereq RESHARE '
	case $(uname -s) in
	Darwin) test-tool reflink probe . ;;
	*) test-tool reflink dedupe-probe . ;;
	esac
'

test_lazy_prereq GIT_LFS '
	git lfs version
'

test_lazy_prereq SHA256SUM '
	command -v shasum || command -v sha256sum
'

sha256 () {
	if command -v sha256sum >/dev/null
	then
		sha256sum <"$1"
	else
		shasum -a 256 <"$1"
	fi | cut -d" " -f1
}

lfs_pair () {
	for wt in ordinary shared
	do
		case $wt in
		ordinary) option=--no-reflink ;;
		shared) option=--reflink-source=. ;;
		esac &&
		git -C source "$@" worktree add -q --detach "$option" "../$wt" \
			2>"$wt.err" || return 1
	done &&
	test_cmp "ordinary/$asset" "shared/$asset" &&
	test_cmp ordinary/control shared/control &&
	git -C ordinary ls-files -s >ordinary.index &&
	git -C shared ls-files -s >shared.index &&
	test_cmp ordinary.index shared.index
}

remove_pair () {
	for wt in ordinary shared
	do
		if test -d "$wt"
		then
			git -C source worktree remove -f "../$wt" || return 1
		fi
	done
}

verify_hydrated () {
	test "$(wc -c <"$1")" -eq "$bytes" &&
	test "$(sha256 "$1")" = "$digest" &&
	test_cmp payload "$1"
}

test_expect_success GIT_LFS,SHA256SUM 'setup LFS payload, committed pointer, and local bare remote' '
	sane_unset GIT_LFS_SKIP_SMUDGE GIT_LFS_SKIP_DOWNLOAD_ERRORS &&
	asset="data and quote'\''.lfs" &&
	git init -q source &&
	git init -q --bare remote.git &&
	git -C source remote add origin "$TRASH_DIRECTORY/remote.git" &&
	git -C source config lfs.storage "$TRASH_DIRECTORY/warm" &&
	git -C source lfs install --local --skip-repo &&
	echo "*.lfs filter=lfs diff=lfs merge=lfs -text" >source/.gitattributes &&
	test-tool genrandom payload 131072 >payload &&
	cp payload "source/$asset" &&
	make_blob_file source/control 64 &&
	git -C source add . &&
	git -C source commit -qm hydrated &&
	git -C source lfs push origin HEAD &&
	bytes=$(wc -c <payload) &&
	digest=$(sha256 payload) &&
	git -C source show "HEAD:$asset" >pointer &&
	printf "version https://git-lfs.github.com/spec/v1\noid sha256:%s\nsize %d\n" \
		"$digest" "$bytes" >expect &&
	test_cmp expect pointer &&
	test-tool chmtime =-60 "source/$asset" source/control source/.gitattributes &&
	git -C source update-index --refresh &&
	cp source/.git/index source.index &&
	git lfs version
'

test_expect_success GIT_LFS,SHA256SUM 'process and single-file smudge agree with ordinary checkout; filter runs once per checkout' '
	test_when_finished remove_pair &&
	write_script record-lfs <<-\EOF &&
	echo "$1" >>"$LFS_LOG"
	exec git-lfs "$@"
	EOF
	test_when_finished "git -C source lfs install --local --skip-repo" &&
	for filter in process smudge
	do
		if test "$filter" = smudge
		then
			git -C source config --unset filter.lfs.process || return 1
		fi &&
		(
			LFS_LOG="$TRASH_DIRECTORY/calls" &&
			export LFS_LOG &&
			>calls &&
			case $filter in
			process)
				lfs_pair -c "filter.lfs.process=\"$TRASH_DIRECTORY/record-lfs\" filter-process"
				;;
			smudge)
				lfs_pair -c "filter.lfs.smudge=\"$TRASH_DIRECTORY/record-lfs\" smudge -- %f"
				;;
			esac &&
			verify_hydrated "shared/$asset" &&
			test_line_count = 2 calls &&
			if test_have_prereq REFLINK
			then
				test_shared "source/$asset" "shared/$asset" &&
				test_shared source/control shared/control
			fi &&
			git -C shared status --porcelain >status &&
			test_must_be_empty status &&
			test_cmp source.index source/.git/index &&
			remove_pair
		) || return 1
	done
'

test_expect_success GIT_LFS,SHA256SUM 'skip-smudge, fetch exclusion and absent driver keep pointer bytes' '
	test_when_finished remove_pair &&
	(
		GIT_LFS_SKIP_SMUDGE=1 &&
		export GIT_LFS_SKIP_SMUDGE &&
		lfs_pair
	) &&
	test_cmp pointer "shared/$asset" &&
	test_not_shared "source/$asset" "shared/$asset" &&
	remove_pair &&
	for key in "lfs.fetchexclude=*.lfs" "lfs.fetchinclude=other/*"
	do
		lfs_pair -c "$key" &&
		test_cmp pointer "shared/$asset" &&
		remove_pair || return 1
	done &&
	# An unknown driver is distinct from a configured but failed driver.
	git -C source config --remove-section filter.lfs &&
	test_when_finished "git -C source lfs install --local --skip-repo" &&
	lfs_pair &&
	test_cmp pointer "shared/$asset" &&
	remove_pair
'

test_expect_success GIT_LFS,SHA256SUM,REFLINK 'matching pointer donors share only when the recipient writes the pointer' '
	GIT_LFS_SKIP_SMUDGE=1 git -C source worktree add -q --no-reflink --detach ../pointer-donor &&
	test_when_finished "git -C source worktree remove -f ../pointer-donor" &&
	test-tool chmtime =-60 "pointer-donor/$asset" &&
	GIT_LFS_SKIP_SMUDGE=1 git -C pointer-donor update-index --refresh &&
	GIT_LFS_SKIP_SMUDGE=1 git -C source worktree add -q --detach \
		--reflink-source=../pointer-donor ../kept-pointer &&
	test_when_finished "git -C source worktree remove -f ../kept-pointer" &&
	test_cmp pointer "kept-pointer/$asset" &&
	test_shared "pointer-donor/$asset" "kept-pointer/$asset" &&
	git -C source worktree add -q --detach --reflink-source=../pointer-donor ../hydrated &&
	test_when_finished "git -C source worktree remove -f ../hydrated" &&
	verify_hydrated "hydrated/$asset" &&
	test_not_shared "pointer-donor/$asset" "hydrated/$asset"
'

test_expect_success GIT_LFS,SHA256SUM 'cold caches fetch from the local bare remote before sharing' '
	test_when_finished remove_pair &&
	test_when_finished "git -C source config lfs.storage \"$TRASH_DIRECTORY/warm\"" &&
	for wt in ordinary shared
	do
		case $wt in
		ordinary) option=--no-reflink ;;
		shared) option=--reflink-source=. ;;
		esac &&
		# Use the default cache here: the local-only transfer adapter
		# can pick up a custom storage path when resolving the remote.
		git -C source config --unset-all lfs.storage || return 1
		GIT_TRACE_PACKET="$TRASH_DIRECTORY/$wt.packet" \
			git -C source worktree add -q --detach "$option" "../$wt" &&
		test_grep "status=delayed" "$wt.packet" &&
		verify_hydrated "$wt/$asset" &&
		find source/.git/lfs/objects -type f >objects &&
		test_line_count = 1 objects &&
		verify_hydrated "$(cat objects)" &&
		mv source/.git/lfs "cold-$wt" &&
		git -C source config lfs.storage "$TRASH_DIRECTORY/warm" || return 1
	done &&
	remove_pair
'

test_expect_success GIT_LFS,SHA256SUM 'required download failures survive with an eligible hydrated donor' '
	test_when_finished remove_pair &&
	mkdir empty-remote &&
	git init -q --bare empty-remote &&
	test_when_finished "git -C source config lfs.storage \"$TRASH_DIRECTORY/warm\"" &&
	git -C source config lfs.storage "$TRASH_DIRECTORY/missing-cache" &&
	for option in --no-reflink --reflink-source=.
	do
		test_must_fail git -C source -c "lfs.url=file://$TRASH_DIRECTORY/empty-remote" \
			worktree add -q --detach "$option" ../failed 2>err &&
		test_grep "smudge filter lfs failed" err &&
		test_path_is_missing "failed/$asset" || return 1
	done &&
	git -C source config --unset filter.lfs.process &&
	test_when_finished "git -C source lfs install --local --skip-repo" &&
	lfs_pair -c filter.lfs.required=false -c "lfs.url=file://$TRASH_DIRECTORY/empty-remote" &&
	test_cmp pointer "shared/$asset" &&
	test_grep "external filter.*failed" ordinary.err &&
	test_grep "external filter.*failed" shared.err &&
	remove_pair
'

test_expect_success GIT_LFS,SHA256SUM 'corrupt cache behavior agrees with ordinary checkout even with a good donor' '
	test_when_finished remove_pair &&
	test_when_finished "git -C source config lfs.storage \"$TRASH_DIRECTORY/warm\"" &&
	cp -R warm corrupt &&
	find corrupt/objects -type f >objects &&
	test_line_count = 1 objects &&
	object=$(cat objects) &&
	# LFS versions can differ on validation during checkout. Give both
	# arms the very same corrupt object, without sharing their caches.
	test-tool genrandom corrupt "$bytes" >"$object" &&
	test "$(sha256 "$object")" != "$digest" &&
	cp -R corrupt corrupt-other &&
	for wt in ordinary shared
	do
		case $wt in
		ordinary) option=--no-reflink storage=corrupt ;;
		shared) option=--reflink-source=. storage=corrupt-other ;;
		esac &&
		git -C source config lfs.storage "$TRASH_DIRECTORY/$storage" &&
		if git -C source -c "lfs.url=file://$TRASH_DIRECTORY/empty-remote" \
			worktree add -q --detach "$option" "../$wt" 2>"$wt.err"
		then
			echo ok >"$wt.result"
		else
			test_grep "smudge filter lfs failed" "$wt.err" &&
			echo failed >"$wt.result"
		fi || return 1
	done &&
	test_cmp ordinary.result shared.result &&
	if test "$(cat ordinary.result)" = ok
	then
		test_cmp "ordinary/$asset" "shared/$asset" &&
		test_not_shared "source/$asset" "shared/$asset" &&
		remove_pair
	fi
'

test_expect_success GIT_LFS,SHA256SUM 'target revision removes the LFS rule without changing pointer identity' '
	test_when_finished remove_pair &&
	git -C source branch with-lfs &&
	git -C source worktree add -q --no-reflink --detach ../change &&
	>change/.gitattributes &&
	git -C change add .gitattributes &&
	git -C change commit -qm no-filter &&
	git -C change branch no-filter &&
	git -C source worktree remove -f ../change &&
	test "$(git -C source rev-parse "with-lfs:$asset")" = \
		"$(git -C source rev-parse "no-filter:$asset")" &&
	for wt in ordinary shared
	do
		case $wt in
		ordinary) option=--no-reflink ;;
		shared) option=--reflink-source=. ;;
		esac &&
		git -C source worktree add -q --detach "$option" "../$wt" no-filter &&
		test_cmp pointer "$wt/$asset" || return 1
	done &&
	test_not_shared "source/$asset" "shared/$asset" &&
	remove_pair
'

test_expect_success GIT_LFS,SHA256SUM,RESHARE 'maintenance shares existing hydrated bytes without invoking LFS' '
	git -C source worktree add -q --detach --no-reflink ../private &&
	test_when_finished "git -C source worktree remove -f ../private" &&
	test-tool chmtime =-60 "private/$asset" &&
	git -C private update-index --refresh &&
	>calls &&
	LFS_LOG="$TRASH_DIRECTORY/calls" git -C private \
		-c "filter.lfs.process=\"$TRASH_DIRECTORY/record-lfs\" filter-process" \
		worktree reflink --reflink-source=../source --porcelain >report &&
	test_must_be_empty calls &&
	verify_hydrated "private/$asset" &&
	test_shared "source/$asset" "private/$asset"
'

test_expect_success GIT_LFS,SHA256SUM 'LFS extension output, not the stored transformed data, is shared' '
	git init -q extension &&
	git -C extension lfs install --local --skip-repo &&
	rot13="tr A-Za-z N-ZA-Mn-za-m" &&
	git -C extension config lfs.extension.rot.clean "$rot13" &&
	git -C extension config lfs.extension.rot.smudge "$rot13" &&
	git -C extension config lfs.extension.rot.priority 0 &&
	echo "file filter=lfs -text" >extension/.gitattributes &&
	make_blob_file expected 64 &&
	cp expected extension/file &&
	git -C extension add . &&
	git -C extension commit -qm extension &&
	git -C extension show HEAD:file >extension.pointer &&
	test_grep "^ext-0-rot sha256:$(sha256 expected)$" extension.pointer &&
	$rot13 <expected >transformed &&
	test_grep "^oid sha256:$(sha256 transformed)$" extension.pointer &&
	reflink_stable_source extension &&
	git -C extension worktree add -q --detach --no-reflink ../extension-off &&
	git -C extension worktree add -q --detach --reflink-source=. ../extension-on &&
	test_cmp expected extension-off/file &&
	test_cmp expected extension-on/file &&
	if test_have_prereq REFLINK
	then
		test_shared extension/file extension-on/file
	fi
'

test_expect_success GIT_LFS,SHA256SUM 'setup a later LFS revision and local Git remote' '
	git -C source branch lifecycle-old &&
	test-tool genrandom lifecycle 196608 >lifecycle-payload &&
	cp lifecycle-payload "source/$asset" &&
	git -C source add -- "$asset" &&
	git -C source commit -qm next-lfs &&
	git -C source branch lifecycle-new &&
	git clone -q --bare --no-local source lifecycle.git &&
	test-tool chmtime =-60 "source/$asset" source/control source/.gitattributes &&
	git -C source update-index --refresh
'

for operation in switch reset merge rebase pull
do
	test_expect_success GIT_LFS,SHA256SUM "marked worktree shares changed LFS output after git $operation" '
		test_when_finished remove_pair &&
		for wt in ordinary shared
		do
			case $wt in
			ordinary) option=--no-reflink ;;
			shared) option=--reflink-source=. ;;
			esac &&
			git -C source worktree add -q --detach "$option" "../$wt" lifecycle-old &&
			case $operation in
			switch)
				git -C "$wt" switch -q --detach lifecycle-new
				;;
			reset)
				git -C "$wt" reset -q --hard lifecycle-new
				;;
			merge)
				git -C "$wt" merge -q --no-ff --no-edit lifecycle-new
				;;
			rebase)
				echo side >"$wt/side" &&
				git -C "$wt" add side &&
				git -C "$wt" commit -qm side &&
				git -C "$wt" rebase -q lifecycle-new &&
				test_path_is_file "$wt/side"
				;;
			pull)
				git -C "$wt" pull -q --ff-only "$TRASH_DIRECTORY/lifecycle.git" lifecycle-new
				;;
			esac &&
			test_cmp lifecycle-payload "$wt/$asset" &&
			git -C "$wt" status --porcelain >status &&
			test_must_be_empty status || return 1
		done &&
		if test_have_prereq REFLINK
		then
			test_not_shared "source/$asset" "ordinary/$asset" &&
			test_shared "source/$asset" "shared/$asset"
		fi
	'
done

test_expect_success GIT_LFS,SHA256SUM,RESHARE 'enabled same-HEAD hard reset repairs LFS files written directly by git-lfs' '
	test_when_finished "git -C source worktree remove -f ../direct" &&
	GIT_LFS_SKIP_SMUDGE=1 git -C source worktree add -q --detach \
		--reflink-source=. ../direct lifecycle-new &&
	git -C direct lfs checkout &&
	test_cmp lifecycle-payload "direct/$asset" &&
	test_not_shared "source/$asset" "direct/$asset" &&
	test-tool chmtime =-60 "direct/$asset" &&
	git -C direct update-index --refresh &&
	git -C direct reset -q --hard HEAD &&
	test_cmp lifecycle-payload "direct/$asset" &&
	test_shared "source/$asset" "direct/$asset" &&
	git -C direct status --porcelain >status &&
	test_must_be_empty status
'

test_done
