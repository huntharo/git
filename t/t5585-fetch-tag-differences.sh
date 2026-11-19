#!/bin/sh

test_description='opt-in reports of advertised tags differing from local tags'

. ./test-lib.sh

expect_differences () {
	report_remote=$1 report_source=$2 &&
	shift 2 &&
	for report_tag
	do
		report_old=$(git -C client rev-parse "refs/tags/$report_tag") &&
		report_new=$(git -C "$report_source" rev-parse "refs/tags/$report_tag") &&
		printf "# tag-difference\t%s\t%s\t%s\trefs/tags/%s\n" \
			"$report_remote" "$report_old" "$report_new" "$report_tag" || return 1
	done
}

check_report () {
	sed -n "/^# tag-difference/p" "$1" | sort >actual &&
	sort "$2" >expect-sorted &&
	test_cmp expect-sorted actual
}

test_expect_success 'setup matching, re-cut, metadata-only, and remote-only tags' '
	git init source &&
	test_commit -C source initial &&
	git -C source tag unchanged &&
	git -C source tag -a -m original annotated &&
	git -C source tag -a -m original metadata &&
	git clone "file://$TRASH_DIRECTORY/source" client &&
	git clone client missing-objects &&
	git -C client for-each-ref --format="%(refname) %(objectname)" refs/tags >local-before &&
	test_commit -C source next &&
	git -C source tag -f initial HEAD &&
	git -C source tag -f -a -m recut annotated HEAD &&
	git -C source tag -f -a -m new-message metadata HEAD^ &&
	git -C source tag remote-only HEAD^ &&
	expect_differences origin source annotated initial metadata >expect-existing &&
	cp expect-existing expect-all &&
	for tag in next remote-only
	do
		oid=$(git -C source rev-parse "refs/tags/$tag") &&
		printf "# tag-difference\torigin\t%s\t%s\trefs/tags/%s\n" \
			"$(test_oid zero)" "$oid" "$tag" >>expect-all || return 1
	done &&
	>expect-empty
'

test_expect_success 'ordinary fetch and existing porcelain produce no additional records' '
	git -C client fetch --dry-run origin >out 2>err &&
	check_report out expect-empty &&
	check_report err expect-empty &&
	git -C client fetch --dry-run --porcelain origin >out 2>err &&
	check_report out expect-empty &&
	check_report err expect-empty
'

for protocol in 0 2
do
	test_expect_success "protocol $protocol reports mismatches before remote objects are present" '
		git clone missing-objects missing-objects-$protocol &&
		git -C missing-objects-$protocol remote set-url origin "file://$TRASH_DIRECTORY/source" &&
		remote_oid=$(git -C source rev-parse annotated) &&
		test_must_fail git -C missing-objects-$protocol cat-file -e "$remote_oid" &&
		git -C missing-objects-$protocol -c protocol.version=$protocol fetch --dry-run \
			--tag-differences origin >out 2>err &&
		check_report out expect-existing &&
		check_report err expect-empty &&
		git -C missing-objects-$protocol for-each-ref --format="%(refname) %(objectname)" refs/tags >local-after &&
		test_cmp local-before local-after
	'
done

test_expect_success 'annotated tag metadata changes are reported even with the same peeled target' '
	git -C client rev-parse "metadata^{}" >local-peeled &&
	git -C source rev-parse "metadata^{}" >remote-peeled &&
	test_cmp local-peeled remote-peeled &&
	git -C client fetch --dry-run --tag-differences=existing origin >out &&
	check_report out expect-existing
'

test_expect_success 'all mode includes remote-only names, without age heuristics' '
	git -C client fetch --dry-run --tag-differences=all origin >out &&
	check_report out expect-all
'

test_expect_success 'matching tags produce no records' '
	git -C client remote add matching "$TRASH_DIRECTORY/client" &&
	test_when_finished "git -C client remote remove matching" &&
	git -C client fetch --dry-run --tag-differences matching >out &&
	check_report out expect-empty
'

test_expect_success 'protocol v2 tagOpt=--no-tags omits tags from the report' '
	test_config -C client remote.origin.tagOpt --no-tags &&
	git -C client -c protocol.version=2 fetch --dry-run --tag-differences=all origin >out &&
	check_report out expect-empty
'

test_expect_success 'protocol v0 reports received tags even with --no-tags' '
	git -C client -c protocol.version=0 fetch --dry-run --no-tags --tag-differences origin >out &&
	check_report out expect-existing
'

test_expect_success 'parallel fetch --all identifies each remote without interleaving records' '
	git clone source second &&
	git -C second tag -f initial HEAD^ &&
	git -C second tag -f -a -m second annotated HEAD &&
	git -C client remote add "other/a%" "file://$TRASH_DIRECTORY/second" &&
	cp expect-existing expect-multiple &&
	expect_differences "other/a%" second annotated metadata >>expect-multiple &&
	git -C client -c fetch.parallel=2 fetch --dry-run --all --tag-differences >out 2>&1 &&
	check_report out expect-multiple
'

test_expect_success 'fetch --multiple forwards the mode to its children' '
	git -C client -c fetch.parallel=2 fetch --dry-run --multiple \
		--tag-differences origin "other/a%" >out 2>&1 &&
	check_report out expect-multiple
'

test_expect_success 'local path transport reports the same differences' '
	git -C client remote add local "$TRASH_DIRECTORY/source" &&
	test_when_finished "git -C client remote remove local" &&
	expect_differences local source annotated initial metadata >expect-local &&
	git -C client fetch --dry-run --tag-differences local >out &&
	check_report out expect-local
'

test_expect_success 'pull forwards the option and leaves existing tags unchanged' '
	git -C client pull --ff-only --tag-differences >out &&
	check_report out expect-existing &&
	git -C client for-each-ref --format="%(refname) %(objectname)" \
		refs/tags/annotated refs/tags/initial refs/tags/metadata refs/tags/unchanged >local-after &&
	test_cmp local-before local-after
'

test_expect_success 'pull forwards all mode before auto-follow creates local tags' '
	git clone client all-pull-client &&
	git -C all-pull-client remote set-url origin "$TRASH_DIRECTORY/source" &&
	git -C all-pull-client tag -d next remote-only &&
	git -C all-pull-client pull --ff-only --tag-differences=all >out &&
	check_report out expect-all
'

test_expect_success 'forced tag updates are compared against their pre-fetch IDs' '
	git clone client force-client &&
	git -C force-client remote set-url origin "$TRASH_DIRECTORY/source" &&
	git -C force-client fetch --tags --force --tag-differences origin >out &&
	check_report out expect-existing &&
	git -C source rev-parse annotated >expect-tag &&
	git -C force-client rev-parse annotated >actual-tag &&
	test_cmp expect-tag actual-tag
'

test_expect_success 'report survives a subsequent pack-transfer failure' '
	git clone client broken &&
	test_commit -C broken newest &&
	git -C broken tag -f initial HEAD &&
	git clone client failed-client &&
	git -C failed-client remote set-url origin "file://$TRASH_DIRECTORY/broken" &&
	expect_differences origin broken initial >expect-broken &&
	test_must_fail git -C failed-client fetch --tag-differences \
		--upload-pack="git -c uploadpack.packObjectsHook=false upload-pack" origin >out 2>err &&
	check_report out expect-broken &&
	test_grep "pack-objects died" err
'

test_expect_success 'direct URL and path fetches do not produce records' '
	git -C client fetch --dry-run --tag-differences=all \
		"file://$TRASH_DIRECTORY/source" >out &&
	check_report out expect-empty &&
	git -C client fetch --dry-run --tag-differences=all ../source >out &&
	check_report out expect-empty
'

test_expect_success 'invalid modes are rejected and explicit negation disables the report' '
	test_must_fail git -C client fetch --tag-differences=recent origin >out 2>err &&
	test_grep "invalid value for --tag-differences" err &&
	git -C client fetch --dry-run --tag-differences --no-tag-differences origin >out 2>err &&
	check_report out expect-empty &&
	check_report err expect-empty
'

test_expect_success 'the implied porcelain mode rejects explicit submodule recursion' '
	test_must_fail git -C client fetch --tag-differences \
		--recurse-submodules origin >out 2>err &&
	test_grep "cannot be used together" err
'

test_expect_success 'the old environment variable does not write files' '
	mkdir unused &&
	GIT_ADVERTISED_REFS_DIR="$TRASH_DIRECTORY/unused" \
		git -C client fetch --dry-run origin &&
	test_dir_is_empty unused
'

test_expect_success 'parallel reports do not truncate more than 100 mismatches' '
	git clone client bulk-client &&
	git -C bulk-client remote set-url origin "file://$TRASH_DIRECTORY/source" &&
	git -C bulk-client remote add mirror "file://$TRASH_DIRECTORY/source" &&
	old_oid=$(git -C client rev-parse HEAD^) &&
	new_oid=$(git -C source rev-parse HEAD) &&
	cp expect-existing expect-bulk &&
	sed "s/origin/mirror/" expect-existing >>expect-bulk &&
	>local-refs &&
	>remote-refs &&
	for n in $(test_seq 1 101)
	do
		echo "create refs/tags/bulk-$n $old_oid" >>local-refs &&
		echo "create refs/tags/bulk-$n $new_oid" >>remote-refs &&
		for remote in origin mirror
		do
			printf "# tag-difference\t%s\t%s\t%s\trefs/tags/bulk-%s\n" \
				"$remote" "$old_oid" "$new_oid" "$n" >>expect-bulk || return 1
		done || return 1
	done &&
	git -C bulk-client update-ref --stdin <local-refs &&
	git -C source update-ref --stdin <remote-refs &&
	git -C bulk-client -c fetch.parallel=2 fetch --dry-run --all --tag-differences >out 2>&1 &&
	check_report out expect-bulk
'

test_done
