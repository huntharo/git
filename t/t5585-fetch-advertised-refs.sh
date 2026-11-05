#!/bin/sh

test_description='opt-in capture of fetch ref advertisements'

. ./test-lib.sh

origin_file=remote-6f726967696e.refs
capture="$TRASH_DIRECTORY/advertised refs"

list_default_refs () {
	git ls-remote "$1" >all-refs &&
	awk '$2 == "HEAD" || $2 ~ /^refs\/(heads|tags)\//' all-refs
}

check_files () {
	printf "%s\n" "$@" | sort >expect-files &&
	ls -A "$capture" | sort >actual-files &&
	test_cmp expect-files actual-files
}

test_expect_success 'setup heads, lightweight and annotated tags, and another ref' '
	git init source &&
	test_commit -C source initial &&
	git -C source tag -a -m annotated annotated &&
	git -C source update-ref refs/custom/extra HEAD &&
	git clone "file://$TRASH_DIRECTORY/source" client &&
	git ls-remote source >expect-full &&
	list_default_refs source >expect-default &&
	mkdir "$capture"
'

test_expect_success 'unset or empty variable writes no files' '
	(
		sane_unset GIT_ADVERTISED_REFS_DIR &&
		git -C client fetch origin
	) &&
	GIT_ADVERTISED_REFS_DIR= git -C client fetch origin &&
	test_dir_is_empty "$capture"
'

for protocol in 0 2
do
	if test "$protocol" = 0
	then
		expected=expect-full
	else
		expected=expect-default
	fi

	test_expect_success "protocol $protocol captures all received refs and peels" '
		GIT_ADVERTISED_REFS_DIR="$capture" \
			git -C client -c protocol.version=$protocol fetch origin &&
		test_cmp "$expected" "$capture/$origin_file" &&
		check_files "$origin_file"
	'
done

test_expect_success 'local path transport captures refs' '
	git -C client remote set-url origin "$TRASH_DIRECTORY/source" &&
	GIT_ADVERTISED_REFS_DIR="$capture" \
		git -C client -c protocol.version=2 fetch origin &&
	test_cmp expect-default "$capture/$origin_file" &&
	check_files "$origin_file"
'

test_expect_success 'parallel fetch --all uses distinct, safely encoded remote names' '
	git clone source second &&
	git -C second tag second-only &&
	git -C client remote add "other/a%" "file://$TRASH_DIRECTORY/second" &&
	list_default_refs second >expect-second &&
	GIT_ADVERTISED_REFS_DIR="$capture" \
		git -C client -c protocol.version=2 -c fetch.parallel=2 fetch --all &&
	test_cmp expect-default "$capture/$origin_file" &&
	test_cmp expect-second "$capture/remote-6f746865722f6125.refs" &&
	check_files "$origin_file" remote-6f746865722f6125.refs
'

test_expect_success 'fetch --multiple inherits the variable' '
	rm "$capture/"*.refs &&
	GIT_ADVERTISED_REFS_DIR="$capture" \
		git -C client -c protocol.version=2 fetch --multiple origin "other/a%" &&
	test_cmp expect-default "$capture/$origin_file" &&
	test_cmp expect-second "$capture/remote-6f746865722f6125.refs" &&
	check_files "$origin_file" remote-6f746865722f6125.refs
'

test_expect_success 'pull inherits the variable' '
	rm "$capture/"*.refs &&
	GIT_ADVERTISED_REFS_DIR="$capture" \
		git -C client -c protocol.version=2 pull --ff-only &&
	test_cmp expect-default "$capture/$origin_file" &&
	check_files "$origin_file"
'

test_expect_success 'protocol v2 respects remote tagOpt=--no-tags' '
	test_config -C client remote.origin.tagOpt --no-tags &&
	git ls-remote source HEAD "refs/heads/*" >expect-no-tags &&
	GIT_ADVERTISED_REFS_DIR="$capture" \
		git -C client -c protocol.version=2 fetch origin &&
	test_cmp expect-no-tags "$capture/$origin_file" &&
	check_files "$origin_file"
'

test_expect_success 'URL and path fetches are skipped' '
	rm "$capture/$origin_file" &&
	GIT_ADVERTISED_REFS_DIR="$capture" \
		git -C client fetch "file://$TRASH_DIRECTORY/source" &&
	GIT_ADVERTISED_REFS_DIR="$capture" git -C client fetch ../source &&
	test_dir_is_empty "$capture"
'

test_expect_success SYMLINKS 'atomic replacement does not write through the old destination' '
	echo old >old-advertisement &&
	ln -s "$TRASH_DIRECTORY/old-advertisement" "$capture/$origin_file" &&
	GIT_ADVERTISED_REFS_DIR="$capture" \
		git -C client -c protocol.version=2 fetch origin &&
	test ! -L "$capture/$origin_file" &&
	test_cmp expect-default "$capture/$origin_file" &&
	echo old >expect-old &&
	test_cmp expect-old old-advertisement &&
	check_files "$origin_file"
'

test_expect_success 'rename failure warns, leaves destination intact, and cleans temporary files' '
	rm -f "$capture/$origin_file" &&
	mkdir "$capture/$origin_file" &&
	GIT_ADVERTISED_REFS_DIR="$capture" \
		git -C client fetch origin 2>err &&
	test_grep "could not write advertised refs" err &&
	test_dir_is_empty "$capture/$origin_file" &&
	check_files "$origin_file" &&
	rmdir "$capture/$origin_file"
'

test_expect_success 'missing output directory warns without failing fetch' '
	GIT_ADVERTISED_REFS_DIR="$capture/missing" \
		git -C client fetch origin 2>err &&
	test_grep "could not write advertised refs" err &&
	test_dir_is_empty "$capture"
'

test_expect_success 'capture is available even when pack transfer fails' '
	git clone source broken &&
	git init failed-client &&
	git -C failed-client remote add origin "file://$TRASH_DIRECTORY/broken" &&
	list_default_refs broken >expect-broken &&
	test_must_fail env GIT_ADVERTISED_REFS_DIR="$capture" \
		git -C failed-client -c protocol.version=2 fetch \
		--upload-pack="git -c uploadpack.packObjectsHook=false upload-pack" origin &&
	test_cmp expect-broken "$capture/$origin_file" &&
	check_files "$origin_file"
'

test_expect_success 'capture exposes a re-cut tag without updating the local tag' '
	git clone source recut &&
	git clone recut recut-client &&
	git -C recut-client rev-parse annotated >old-tag &&
	git -C recut tag -f -a -m recut annotated HEAD &&
	list_default_refs recut >expect-recut &&
	GIT_ADVERTISED_REFS_DIR="$capture" \
		git -C recut-client -c protocol.version=2 fetch origin &&
	test_cmp expect-recut "$capture/$origin_file" &&
	git -C recut-client rev-parse annotated >actual-tag &&
	test_cmp old-tag actual-tag
'

test_expect_success 'empty advertisement replaces an earlier snapshot with an empty file' '
	git init --bare empty &&
	git -C client remote add empty "file://$TRASH_DIRECTORY/empty" &&
	echo stale >"$capture/remote-656d707479.refs" &&
	GIT_ADVERTISED_REFS_DIR="$capture" \
		git -C client -c protocol.version=2 fetch empty &&
	test_must_be_empty "$capture/remote-656d707479.refs" &&
	check_files "$origin_file" remote-656d707479.refs
'

test_done
