#!/bin/sh

test_description='reflink checkout: choosing the reflink source, and its lifecycle

Which worktree a reflink checkout clones from (the reflink-source file
written by "git worktree add --reflink[-source]", checkout.reflinkSource,
the main worktree), and what happens when that worktree is moved,
removed, pruned, reused, switched to another branch, has an index we
cannot read, is bare, or lives on another filesystem. None of it may
change the result of a checkout; it only changes what is shared.
'

. ./test-lib.sh
. "$TEST_DIRECTORY"/lib-reflink.sh

# These tests break the reflink source's index on purpose, which a
# forced split index gets in the way of.
GIT_TEST_SPLIT_INDEX=0
export GIT_TEST_SPLIT_INDEX

# reflink_source <trace2-event-file>: the reflink source(s) named in the
# trace, one per line.
reflink_source () {
	sed -n -e 's/.*"category":"reflink","key":"source","value":"\([^"]*\)".*/\1/p' "$1" |
	sort -u
}

# test_reflink_source <worktree>|"(none)" <trace2-event-file>: every
# process of the trace that resolved a reflink source chose <worktree>.
test_reflink_source () {
	if test "$1" = "(none)"
	then
		echo "(none)" >expect.source
	else
		(cd "$1" && pwd -P) >expect.source
	fi &&
	reflink_source "$2" >actual.source &&
	test_cmp expect.source actual.source
}

# source_file <worktree>: the reflink-source file of linked <worktree>.
source_file () {
	echo "$(git -C "$1" rev-parse --absolute-git-dir)/reflink-source"
}

# test_source_file <worktree> <content>: the reflink-source file of
# <worktree> exists and holds <content> (which may be empty).
test_source_file () {
	test_path_is_file "$(source_file "$1")" &&
	echo "$2" >expect.spec &&
	echo "$(cat "$(source_file "$1")")" >actual.spec &&
	test_cmp expect.spec actual.spec
}

# Files and their blobs:
#
#              a   b   c   dir/d  small
#   v1.0       a1  b1  c1  d1     s
#   v2 (main)  a1  b2  c2  d1     s     the main worktree
#   maint      a1  b1  c1  d2     s     the "one-oh" worktree
#
# So a checkout of maint shares 2 files with the main worktree and all
# 5 with one-oh; a checkout of v2 shares all 5 with the main worktree.

test_expect_success 'setup' '
	git config checkout.workers 1 &&
	mkdir dir &&
	make_blob_file a 64 a1 &&
	make_blob_file b 64 b1 &&
	make_blob_file c 64 c1 &&
	make_blob_file dir/d 64 d1 &&
	echo small >small &&
	git add a b c dir/d small &&
	git commit -q -m v1.0 &&
	git tag v1.0 &&
	git branch maint &&
	make_blob_file b 64 b2 &&
	make_blob_file c 64 c2 &&
	git commit -q -a -m "main: new b and c" &&
	git tag v2 &&

	git worktree add -q --no-reflink one-oh maint &&
	make_blob_file one-oh/dir/d 64 d2 &&
	git -C one-oh commit -q -a -m "maint: fix d" &&
	reflink_stable_source &&
	reflink_stable_source one-oh &&
	test_path_is_missing "$(source_file one-oh)"
'

test_expect_success REFLINK 'worktree add --reflink clones from the main worktree by default' '
	test_when_finished "git worktree remove --force w-default" &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" \
		git worktree add -q --reflink --detach w-default v2 &&
	test_source_file w-default "" &&
	test_reflink_source . trace.json &&
	test_reflink_count cloned 5 trace.json &&
	test_reflink_count no-donor 0 trace.json &&
	for f in a b c dir/d
	do
		test_shared $f w-default/$f || return 1
	done &&
	test_same_as_checkout w-default v2
'

test_expect_success REFLINK '--reflink-source=<path> is relative to the current directory' '
	test_when_finished "git worktree remove --force w-path" &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" \
		git -C dir worktree add -q --reflink-source=../one-oh \
			--detach ../w-path maint &&
	test_source_file w-path worktrees/one-oh &&
	test_reflink_source one-oh trace.json &&
	test_reflink_count cloned 5 trace.json &&
	test_shared one-oh/dir/d w-path/dir/d &&
	test_shared one-oh/b w-path/b &&
	test_same_as_checkout w-path maint
'

test_expect_success REFLINK '--reflink-source=<name> names a worktree as "git worktree move" does' '
	test_when_finished "git worktree remove --force w-name" &&
	rm -f trace.json &&
	# from dir/, "one-oh" is not a path to any worktree
	GIT_TRACE2_EVENT="$TRACE_JSON" \
		git -C dir worktree add -q --reflink-source=one-oh \
			--detach ../w-name maint &&
	test_source_file w-name worktrees/one-oh &&
	test_reflink_source one-oh trace.json &&
	test_reflink_count cloned 5 trace.json &&
	test_shared one-oh/dir/d w-name/dir/d &&
	test_same_as_checkout w-name maint
'

test_expect_success REFLINK '--reflink-source=<main worktree> writes "."' '
	test_when_finished "git worktree remove --force w-main" &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" \
		git -C one-oh worktree add -q --reflink-source="$(pwd)" \
			--detach ../w-main v2 &&
	test_source_file w-main . &&
	test_reflink_source . trace.json &&
	test_reflink_count cloned 5 trace.json &&
	test_shared b w-main/b &&
	test_same_as_checkout w-main v2
'

test_expect_success REFLINK 'worktree add --reflink prefers main and falls back to another linked worktree' '
	test_when_finished "git worktree remove --force w-from-linked" &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" \
		git -C one-oh worktree add -q --reflink \
			--detach ../w-from-linked maint &&
	test_source_file w-from-linked "" &&
	test_reflink_source . trace.json &&
	test_reflink_count cloned 5 trace.json &&
	test_reflink_count no-donor 3 trace.json &&
	test_reflink_count alternate-index-read 1 trace.json &&
	test_shared a w-from-linked/a &&
	test_shared one-oh/b w-from-linked/b &&
	test_not_shared one-oh/a w-from-linked/a &&
	test_same_as_checkout w-from-linked maint
'

test_expect_success REFLINK 'reflink-source file "worktrees/<id>" and "." name the source' '
	test_when_finished "git worktree remove --force w-file" &&
	git worktree add -q --no-reflink --detach w-file maint &&
	test_path_is_missing "$(source_file w-file)" &&

	echo worktrees/one-oh >"$(source_file w-file)" &&
	rm w-file/a w-file/b &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" git -C w-file checkout -- a b &&
	test_reflink_source one-oh trace.json &&
	test_reflink_count cloned 2 trace.json &&
	test_shared one-oh/b w-file/b &&

	echo . >"$(source_file w-file)" &&
	rm w-file/a w-file/b &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" git -C w-file checkout -- a b &&
	test_reflink_source . trace.json &&
	test_reflink_count cloned 1 trace.json &&
	test_reflink_count no-donor 1 trace.json &&
	test_shared a w-file/a &&
	test_not_shared one-oh/b w-file/b &&
	test_same_as_checkout w-file maint
'

test_expect_success REFLINK 'checkout.reflinkSource is used when there is no reflink-source file' '
	test_when_finished "git worktree remove --force w-cfg" &&
	git worktree add -q --no-reflink --detach w-cfg maint &&

	# a name
	rm w-cfg/b &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" git -C w-cfg \
		-c checkout.reflink=true -c checkout.reflinkSource=one-oh \
		checkout -- b &&
	test_reflink_source one-oh trace.json &&
	test_reflink_count cloned 1 trace.json &&
	test_shared one-oh/b w-cfg/b &&

	# a relative path, relative to the top of the worktree
	rm w-cfg/c &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" git -C w-cfg/dir \
		-c checkout.reflink=true -c checkout.reflinkSource=../one-oh \
		checkout -- ../c &&
	test_reflink_source one-oh trace.json &&
	test_reflink_count cloned 1 trace.json &&
	test_shared one-oh/c w-cfg/c &&

	# an absolute path
	rm w-cfg/dir/d &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" git -C w-cfg \
		-c checkout.reflink=true \
		-c checkout.reflinkSource="$(pwd)/one-oh" \
		checkout -- dir/d &&
	test_reflink_source one-oh trace.json &&
	test_reflink_count cloned 1 trace.json &&
	test_shared one-oh/dir/d w-cfg/dir/d &&

	# and with an empty reflink-source file
	>"$(source_file w-cfg)" &&
	rm w-cfg/dir/d &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" git -C w-cfg \
		-c checkout.reflinkSource=one-oh checkout -- dir/d &&
	test_reflink_source one-oh trace.json &&
	test_reflink_count cloned 1 trace.json &&
	test_same_as_checkout w-cfg maint
'

test_expect_success REFLINK 'checkout.reflinkSource in parallel checkout workers' '
	test_when_finished "git worktree remove --force w-cfg-par" &&
	git worktree add -q --no-reflink --detach w-cfg-par maint &&
	rm w-cfg-par/a w-cfg-par/b w-cfg-par/c w-cfg-par/dir/d &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" git -C w-cfg-par/dir \
		-c checkout.workers=2 -c checkout.thresholdForParallelism=1 \
		-c checkout.reflink=true -c checkout.reflinkSource=../one-oh \
		checkout -- .. &&
	test_reflink_source one-oh trace.json &&
	test_reflink_count cloned 4 trace.json &&
	test_shared one-oh/dir/d w-cfg-par/dir/d &&
	test_shared one-oh/b w-cfg-par/b &&
	test_same_as_checkout w-cfg-par maint
'

test_expect_success REFLINK 'reflink-source file beats checkout.reflinkSource beats the main worktree' '
	test_when_finished "git worktree remove --force w-prec" &&
	test_when_finished "git worktree remove --force prec-cfg" &&
	git worktree add -q --no-reflink --detach prec-cfg maint &&
	reflink_stable_source prec-cfg &&
	git worktree add -q --no-reflink --detach w-prec maint &&

	echo worktrees/one-oh >"$(source_file w-prec)" &&
	rm w-prec/b &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" git -C w-prec \
		-c checkout.reflinkSource=prec-cfg checkout -- b &&
	test_reflink_source one-oh trace.json &&
	test_shared one-oh/b w-prec/b &&

	# a reflink-source file naming no worktree is ignored
	echo worktrees/no-such-worktree >"$(source_file w-prec)" &&
	rm w-prec/b &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" git -C w-prec \
		-c checkout.reflinkSource=prec-cfg checkout -- b &&
	test_reflink_source prec-cfg trace.json &&
	test_shared prec-cfg/b w-prec/b &&

	>"$(source_file w-prec)" &&
	rm w-prec/b &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" git -C w-prec \
		-c checkout.reflinkSource=prec-cfg checkout -- b &&
	test_reflink_source prec-cfg trace.json &&
	test_shared prec-cfg/b w-prec/b &&

	# a checkout.reflinkSource naming no worktree is ignored
	rm w-prec/a &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" git -C w-prec \
		-c checkout.reflinkSource=no-such-worktree checkout -- a &&
	test_reflink_source . trace.json &&
	test_shared a w-prec/a &&

	rm w-prec/a w-prec/b &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" git -C w-prec checkout -- a b &&
	test_reflink_source . trace.json &&
	test_reflink_count cloned 2 trace.json &&
	test_reflink_count no-donor 1 trace.json &&
	test_same_as_checkout w-prec maint
'

test_expect_success 'source precedence does not change the result' '
	test_when_finished "git worktree remove --force w-prec-any" &&
	git worktree add -q --reflink-source=one-oh --detach w-prec-any v1.0 &&
	test_same_as_checkout w-prec-any v1.0 &&
	git -C w-prec-any -c checkout.reflinkSource=. checkout -q --detach v2 &&
	test_same_as_checkout w-prec-any v2 &&
	>"$(source_file w-prec-any)" &&
	git -C w-prec-any -c checkout.reflinkSource=one-oh \
		checkout -q --detach maint &&
	test_same_as_checkout w-prec-any maint
'

test_expect_success REFLINK 'automatic fallback and explicit maintenance source both share retained blobs' '
	test_when_finished "git branch -D fix-1 fix-2" &&
	test_when_finished "git worktree remove --force fix-main" &&
	test_when_finished "git worktree remove --force fix-oh" &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" \
		git worktree add -q --reflink -b fix-1 fix-main maint &&
	test_reflink_count cloned 5 trace.json &&
	test_reflink_count no-donor 3 trace.json &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" \
		git worktree add -q --reflink-source=one-oh -b fix-2 fix-oh maint &&
	test_reflink_count cloned 5 trace.json &&
	test_reflink_count no-donor 0 trace.json &&
	for f in a b c dir/d
	do
		test_shared one-oh/$f fix-oh/$f || return 1
	done &&
	test_not_shared b fix-main/b &&
	test_not_shared dir/d fix-main/dir/d &&
	test_shared one-oh/b fix-main/b &&
	test_shared one-oh/dir/d fix-main/dir/d &&

	# and keeps doing so on later checkouts
	git -C fix-oh switch -q -c fix-2b v1.0 &&
	git -C fix-oh switch -q fix-2 &&
	git branch -D fix-2b &&
	test_shared one-oh/dir/d fix-oh/dir/d &&
	test_same_as_checkout fix-main maint &&
	test_same_as_checkout fix-oh maint
'

test_expect_success '--reflink-source must name a worktree with a working tree' '
	mkdir not-a-worktree &&
	test_must_fail git worktree add --reflink-source=not-a-worktree \
		--detach w-bad maint 2>err &&
	test_grep "is not a worktree with a working tree" err &&
	test_must_fail git worktree add --reflink-source=no-such-dir \
		--detach w-bad maint 2>err &&
	test_grep "is not a worktree with a working tree" err &&
	test_must_fail git worktree add --reflink-source=small \
		--detach w-bad maint 2>err &&
	test_grep "is not a worktree with a working tree" err &&
	# the directory of the new worktree is not one yet
	mkdir w-bad &&
	test_must_fail git worktree add --reflink-source=w-bad \
		--detach w-bad maint 2>err &&
	test_grep "is not a worktree with a working tree" err &&
	test_dir_is_empty w-bad &&
	test_path_is_missing .git/worktrees/w-bad &&
	test_must_fail git worktree add --no-reflink --reflink-source=one-oh \
		--detach w-bad maint 2>err &&
	test_grep "cannot be used together" err &&
	test_path_is_missing .git/worktrees/w-bad
'

test_expect_success REFLINK 'a reflink source that is the current worktree is skipped' '
	test_when_finished "git worktree remove --force w-self" &&
	git worktree add -q --no-reflink --detach w-self maint &&
	echo worktrees/w-self >"$(source_file w-self)" &&
	rm w-self/a w-self/b &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" git -C w-self checkout -- a b &&
	test_reflink_source . trace.json &&
	test_reflink_count cloned 1 trace.json &&
	test_reflink_count no-donor 1 trace.json &&

	rm "$(source_file w-self)" &&
	rm w-self/a w-self/b &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" git -C w-self \
		-c checkout.reflink=true -c checkout.reflinkSource=. \
		checkout -- a b &&
	test_reflink_source . trace.json &&
	test_reflink_count cloned 1 trace.json &&
	test_same_as_checkout w-self maint
'

test_expect_success REFLINK 'a moved reflink source is still used' '
	test_when_finished "git worktree remove --force mv-r" &&
	test_when_finished "git worktree remove --force mv-moved" &&
	git worktree add -q --no-reflink --detach mv-src maint &&
	reflink_stable_source mv-src &&
	git worktree add -q --reflink-source=mv-src --detach mv-r maint &&
	test_source_file mv-r worktrees/mv-src &&
	git worktree move mv-src mv-moved &&
	rm mv-r/a mv-r/dir/d &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" git -C mv-r checkout -- a dir/d &&
	test_source_file mv-r worktrees/mv-src &&
	test_reflink_source mv-moved trace.json &&
	test_reflink_count cloned 2 trace.json &&
	test_shared mv-moved/dir/d mv-r/dir/d &&
	test_same_as_checkout mv-r maint
'

test_expect_success REFLINK 'a removed reflink source falls back to the default source' '
	test_when_finished "git worktree remove --force rm-r" &&
	git worktree add -q --no-reflink --detach rm-src maint &&
	reflink_stable_source rm-src &&
	git worktree add -q --reflink-source=rm-src --detach rm-r maint &&
	test_shared rm-src/b rm-r/b &&
	git worktree remove rm-src &&
	# the recipient keeps its data
	git show maint:b >expect &&
	test_cmp expect rm-r/b &&
	git -C rm-r diff-files --exit-code &&
	rm rm-r/a rm-r/b rm-r/dir/d &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" git -C rm-r checkout -- a b dir/d &&
	test_reflink_source . trace.json &&
	test_reflink_count cloned 1 trace.json &&
	test_reflink_count no-donor 2 trace.json &&
	test_shared a rm-r/a &&
	test_same_as_checkout rm-r maint
'

test_expect_success REFLINK 'a deleted or pruned reflink source falls back to the main worktree' '
	test_when_finished "git worktree remove --force pr-r" &&
	git worktree add -q --no-reflink --detach pr-src maint &&
	reflink_stable_source pr-src &&
	git worktree add -q --reflink-source=pr-src --detach pr-r maint &&
	rm -rf pr-src &&
	rm pr-r/a pr-r/b &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" git -C pr-r checkout -- a b &&
	test_reflink_source . trace.json &&
	test_reflink_count cloned 1 trace.json &&
	test_reflink_count no-donor 1 trace.json &&
	test_same_as_checkout pr-r maint &&

	git worktree prune &&
	test_path_is_missing .git/worktrees/pr-src &&
	rm pr-r/a pr-r/b &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" git -C pr-r checkout -- a b &&
	test_reflink_source . trace.json &&
	test_reflink_count cloned 1 trace.json &&
	test_reflink_count no-donor 1 trace.json &&
	test_shared a pr-r/a &&
	test_same_as_checkout pr-r maint
'

test_expect_success 'checkouts succeed after the reflink source is removed or pruned' '
	test_when_finished "git worktree remove --force gone-r" &&
	git worktree add -q --no-reflink --detach gone-src maint &&
	git worktree add -q --reflink-source=gone-src --detach gone-r maint &&
	test_same_as_checkout gone-r maint &&
	rm -rf gone-src &&
	git -C gone-r checkout -q --detach v2 2>err &&
	test_must_be_empty err &&
	test_same_as_checkout gone-r v2 &&
	git worktree prune &&
	git -C gone-r checkout -q --detach v1.0 2>err &&
	test_must_be_empty err &&
	test_same_as_checkout gone-r v1.0
'

test_expect_success REFLINK 'a worktree id reused after prune is harmless' '
	test_when_finished "git worktree remove --force reuse-r" &&
	test_when_finished "git worktree remove --force elsewhere/reuse" &&
	git worktree add -q --no-reflink --detach reuse maint &&
	reflink_stable_source reuse &&
	git worktree add -q --reflink-source=reuse --detach reuse-r maint &&
	rm -rf reuse &&
	git worktree prune &&
	mkdir elsewhere &&
	git worktree add -q --no-reflink --detach elsewhere/reuse v2 &&
	reflink_stable_source elsewhere/reuse &&
	echo "$(pwd)/elsewhere/reuse/.git" >expect &&
	test_cmp expect .git/worktrees/reuse/gitdir &&
	test_source_file reuse-r worktrees/reuse &&

	# now the source is an unrelated worktree on v2
	rm reuse-r/a reuse-r/b reuse-r/c reuse-r/dir/d reuse-r/small &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" git -C reuse-r checkout -- . &&
	test_reflink_source elsewhere/reuse trace.json &&
	test_reflink_count cloned 2 trace.json &&
	test_reflink_count no-donor 3 trace.json &&
	test_reflink_count verify-failed 0 trace.json &&
	test_shared elsewhere/reuse/a reuse-r/a &&
	test_same_as_checkout reuse-r maint
'

test_expect_success REFLINK 'a reflink source changing branch only changes what later checkouts share' '
	test_when_finished "git worktree remove --force br-src" &&
	test_when_finished "git worktree remove --force br-r1" &&
	test_when_finished "git worktree remove --force br-r2" &&
	test_when_finished "git worktree remove --force br-r3" &&
	git worktree add -q --no-reflink --detach br-src maint &&
	reflink_stable_source br-src &&
	git worktree add -q --reflink-source=br-src --detach br-r1 maint &&
	git worktree add -q --reflink-source=br-src --detach br-r2 maint &&
	test_shared br-src/b br-r1/b &&
	git -C br-src checkout -q --detach v2 &&
	reflink_stable_source br-src &&

	# the recipients keep their data, and still share it
	for wt in br-r1 br-r2
	do
		for f in a b c dir/d
		do
			git show maint:$f >expect &&
			test_cmp expect $wt/$f || return 1
		done &&
		git -C $wt diff-files --exit-code &&
		git -C $wt status --porcelain >actual &&
		test_must_be_empty actual || return 1
	done &&
	test_shared br-r1/b br-r2/b &&
	test_shared br-r1/dir/d br-r2/dir/d &&
	test_not_shared br-src/b br-r1/b &&
	test_shared br-src/a br-r1/a &&

	# new checkouts only clone what the source still has
	rm br-r1/a br-r1/b &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" git -C br-r1 checkout -- a b &&
	test_reflink_count cloned 1 trace.json &&
	test_reflink_count no-donor 1 trace.json &&
	test_shared br-src/a br-r1/a &&
	test_not_shared br-src/b br-r1/b &&
	test_same_as_checkout br-r1 maint &&

	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" \
		git worktree add -q --reflink-source=br-src --detach br-r3 maint &&
	test_reflink_count cloned 2 trace.json &&
	test_reflink_count no-donor 3 trace.json &&
	test_same_as_checkout br-r3 maint
'

# An unreadable index in the reflink source only means nothing is
# cloned: the checkout must succeed, write the same files, and print
# exactly what it prints without reflink checkout.

test_expect_success 'setup reflink source with a broken index' '
	git worktree add -q --no-reflink --detach bad-src maint &&
	git worktree add -q --reflink-source=bad-src --detach bad-r maint &&
	test_source_file bad-r worktrees/bad-src &&
	bad_index=$(git -C bad-src rev-parse --absolute-git-dir)/index &&
	cp "$bad_index" bad-index.orig
'

# break_index <how>: break the index of bad-src.
break_index () {
	bad_gitdir=$(git -C bad-src rev-parse --absolute-git-dir) &&
	bad_index=$bad_gitdir/index &&
	case "$1" in
	version)
		printf "\000\000\000\011" |
		dd of="$bad_index" bs=1 seek=4 conv=notrunc 2>/dev/null
		;;
	extension)
		# "abcd" is a required extension (lower case) that no Git
		# knows. Write the index without a checksum (index.skipHash)
		# first, so that it is the extension that makes it unreadable.
		rawsz=$(test_oid rawsz) &&
		git -C bad-src -c index.skipHash=true update-index --force-write-index &&
		cp "$bad_index" skiphash.idx &&
		size=$(wc -c <skiphash.idx) &&
		test_copy_bytes $((size - rawsz)) <skiphash.idx >"$bad_index" &&
		printf "abcd\000\000\000\000" >>"$bad_index" &&
		test-tool genzeros $rawsz >>"$bad_index"
		;;
	split-index)
		git -C bad-src update-index --split-index &&
		ls "$bad_gitdir"/sharedindex.* >shared &&
		test_line_count = 1 shared &&
		rm "$bad_gitdir"/sharedindex.*
		;;
	*)
		BUG "unknown index breakage '$1'"
		;;
	esac &&
	test_must_fail git -C bad-src status 2>/dev/null
}

# flip_bit <file> <offset>: flip the lowest bit of the byte at <offset>.
flip_bit () {
	perl -e '
		open(my $f, "+<", $ARGV[0]) or die "open: $!";
		binmode $f;
		seek($f, $ARGV[1], 0) && read($f, my $b, 1) == 1 or die "read: $!";
		seek($f, $ARGV[1], 0) && print $f chr(ord($b) ^ 1) or die "write: $!";
		close($f) or die "close: $!";
	' "$1" "$2"
}

# restore_index: undo break_index.
restore_index () {
	cp bad-index.orig "$(git -C bad-src rev-parse --absolute-git-dir)/index"
}

for how in version extension split-index
do
	for workers in 1 2
	do
		test_expect_success "reflink source index unusable ($how, $workers worker(s))" '
			test_when_finished restore_index &&
			test_when_finished "git worktree remove --force bad-new" &&
			test_when_finished "git worktree remove --force bad-new-ref" &&
			break_index $how &&

			par="-c checkout.workers=$workers -c checkout.thresholdForParallelism=1" &&
			rm bad-r/a bad-r/b bad-r/c &&
			git -C bad-r $par -c checkout.reflink=false checkout -- a b c 2>expect.err &&
			rm bad-r/a bad-r/b bad-r/c &&
			rm -f trace.json &&
			GIT_TRACE2_EVENT="$TRACE_JSON" \
				git -C bad-r $par checkout -- a b c 2>actual.err &&
			test_cmp expect.err actual.err &&
			test_reflink_count cloned 0 trace.json &&
			if test_have_prereq REFLINK
			then
				test_grep "\"category\":\"reflink\",\"key\":\"source-index\",\"value\":\"unreadable\"" trace.json
			fi &&
			test_same_as_checkout bad-r maint &&

			git $par worktree add -q --no-reflink --detach \
				bad-new-ref maint 2>expect.err &&
			rm -f trace.json &&
			GIT_TRACE2_EVENT="$TRACE_JSON" \
				git $par worktree add -q --reflink-source=bad-src \
				--detach bad-new maint 2>actual.err &&
			test_cmp expect.err actual.err &&
			test_reflink_count cloned 0 trace.json &&
			test_same_as_checkout bad-new maint
		'
	done
done

test_expect_success 'reflink source index with a corrupt checksum' '
	test_when_finished restore_index &&
	bad_index=$(git -C bad-src rev-parse --absolute-git-dir)/index &&
	# Flip a bit of the object name of the first entry ("a"). Git does
	# not normally verify the index checksum on reading, but the reflink
	# source index is read gently, which does: nothing is cloned.
	flip_bit "$bad_index" 52 &&
	test_must_fail git -C bad-src fsck --no-dangling 2>err &&
	test_grep "bad index file" err &&

	rm bad-r/a bad-r/b &&
	git -C bad-r -c checkout.reflink=false checkout -- a b 2>expect.err &&
	rm bad-r/a bad-r/b &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" git -C bad-r checkout -- a b 2>actual.err &&
	test_cmp expect.err actual.err &&
	if test_have_prereq REFLINK
	then
		test_reflink_count verify-failed 0 trace.json &&
		test_reflink_count cloned 0 trace.json &&
		test_grep "\"key\":\"source-index\",\"value\":\"unreadable\"" trace.json &&
		test_not_shared bad-src/a bad-r/a &&
		test_not_shared bad-src/b bad-r/b
	fi &&
	test_same_as_checkout bad-r maint
'

# A corrupt entry count must only mean that nothing gets cloned, both
# when the checksum catches it and when index.skipHash disables it.
for skiphash in false true
do
	test_expect_success REFLINK "reflink source index with a bad entry count (skipHash=$skiphash)" '
		test_when_finished restore_index &&
		test_when_finished "rm -f \"$(git -C bad-r rev-parse --absolute-git-dir)/index.lock\"" &&
		git -C bad-src -c index.skipHash=$skiphash update-index --force-write-index &&
		bad_index=$(git -C bad-src rev-parse --absolute-git-dir)/index &&
		printf "\177\377\377\377" |
		dd of="$bad_index" bs=1 seek=8 conv=notrunc 2>/dev/null &&
		rm bad-r/a &&
		rm -f trace.json &&
		GIT_TRACE2_EVENT="$TRACE_JSON" \
			git -C bad-r checkout -- a 2>actual.err &&
		test_grep ! -e fatal -e error actual.err &&
		test_reflink_count cloned 0 trace.json &&
		test_same_as_checkout bad-r maint
	'
done

# In a version 4 index without extensions the last entry ends just
# before the checksum; its short, prefix-compressed name must not make
# the index look truncated.
test_expect_success REFLINK 'reflink source with a version 4 index and no extensions' '
	test_when_finished "git worktree remove --force v4-src" &&
	test_when_finished "git worktree remove --force v4-r" &&
	git worktree add -q --no-reflink --detach v4-src v2 &&
	reflink_stable_source v4-src &&
	git -C v4-src update-index --index-version 4 &&
	(
		cd v4-src &&
		test-tool scrap-cache-tree
	) &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" \
		git worktree add -q --reflink-source=v4-src --detach v4-r v2 &&
	test_grep ! unreadable trace.json &&
	test_reflink_source v4-src trace.json &&
	test_reflink_count cloned 5 trace.json &&
	test_shared v4-src/b v4-r/b &&
	test_same_as_checkout v4-r v2
'

test_expect_success 'bare repository: setup' '
	git clone -q --bare . bare.git &&
	git -C bare.git worktree add -q --no-reflink --detach ../bw1 maint &&
	reflink_stable_source bw1
'

test_expect_success 'bare repository: --reflink run from a linked worktree uses it' '
	test_when_finished "git -C bare.git worktree remove --force ../bw2" &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" \
		git -C bw1 worktree add -q --reflink --detach ../bw2 maint 2>err &&
	test_must_be_empty err &&
	test_source_file bw2 worktrees/bw1 &&
	if test_have_prereq REFLINK
	then
		test_reflink_source bw1 trace.json &&
		test_reflink_count cloned 5 trace.json &&
		test_shared bw1/b bw2/b
	fi &&
	(
		cd bare.git &&
		test_same_as_checkout ../bw2 maint
	)
'

test_expect_success 'bare repository: checkout.reflinkSource is honoured' '
	test_when_finished "git -C bare.git worktree remove --force ../bw4" &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" \
		git -C bare.git -c checkout.reflinkSource=bw1 \
		worktree add -q --reflink --detach ../bw4 maint 2>err &&
	test_must_be_empty err &&
	test_source_file bw4 "" &&
	if test_have_prereq REFLINK
	then
		test_reflink_source bw1 trace.json &&
		test_reflink_count cloned 5 trace.json
	fi &&
	(
		cd bare.git &&
		test_same_as_checkout ../bw4 maint
	)
'

test_expect_success 'bare repository: --reflink run from the bare directory warns' '
	test_when_finished "git -C bare.git worktree remove --force ../bw3" &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" \
		git -C bare.git worktree add -q --reflink --detach ../bw3 maint 2>err &&
	test_grep "no main reflink source" err &&
	test_line_count = 1 err &&
	test_source_file bw3 "" &&
	if test_have_prereq REFLINK
	then
		test_reflink_source "(none)" trace.json &&
		test_shared bw1/b bw3/b
	fi &&
	(
		cd bare.git &&
		test_same_as_checkout ../bw3 maint
	) &&

	# later checkouts there can still use checkout.reflinkSource
	rm bw3/b &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" \
		git -C bw3 -c checkout.reflinkSource=bw1 checkout -- b &&
	if test_have_prereq REFLINK
	then
		test_reflink_source bw1 trace.json &&
		test_reflink_count cloned 1 trace.json &&
		test_shared bw1/b bw3/b
	fi &&
	(
		cd bare.git &&
		test_same_as_checkout ../bw3 maint
	)
'

test_expect_success 'bare repository: the bare directory is no reflink source' '
	test_must_fail git -C bare.git worktree add --reflink-source=. \
		--detach ../bw4 maint 2>err &&
	test_grep "is not a worktree with a working tree" err &&
	test_must_fail git -C bw1 worktree add --reflink-source=../bare.git \
		--detach ../bw4 maint 2>err &&
	test_grep "is not a worktree with a working tree" err &&
	test_path_is_missing bw4 &&

	git -C bare.git worktree add -q --no-reflink --detach ../bw5 maint &&
	test_when_finished "git -C bare.git worktree remove --force ../bw5" &&
	rm bw5/a &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" git -C bw5 \
		-c checkout.reflink=true -c checkout.reflinkSource=../bare.git \
		checkout -- a 2>err &&
	test_grep ! warning err &&
	test_reflink_count cloned 0 trace.json &&
	(
		cd bare.git &&
		test_same_as_checkout ../bw5 maint
	)
'

test_expect_success SANITY 'an unreadable reflink source is not used' '
	git worktree add -q --no-reflink --detach locked maint &&
	test_when_finished "chmod 755 locked &&
		git worktree remove --force locked &&
		git worktree remove --force wt-locked" &&
	chmod 000 locked &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" \
		git worktree add -q --reflink-source=locked --detach wt-locked maint 2>err &&
	test_must_be_empty err &&
	test_reflink_source "(none)" trace.json &&
	test_reflink_count cloned 0 trace.json &&
	test_reflink_count clone-failed 0 trace.json &&
	test_reflink_count source-dirty 0 trace.json &&
	chmod 755 locked &&
	test_same_as_checkout wt-locked maint
'

# btrfs cannot clone between a "nodatacow" directory (chattr +C) and
# ordinary files: the filesystem can clone, yet every clone fails.
test_lazy_prereq NODATACOW '
	test-tool reflink probe . &&
	mkdir ndc &&
	chattr +C ndc 2>/dev/null &&
	lsattr -d ndc 2>/dev/null | cut -d" " -f1 | grep C >/dev/null
'

test_expect_success NODATACOW 'cloning is given up after 16 failures in a row' '
	test_when_finished "rm -rf many ndc && git worktree prune" &&
	git init -q many &&
	(
		cd many &&
		for i in $(test_seq 40)
		do
			make_blob_file f$i 16 || return 1
		done &&
		git add . &&
		git commit -q -m many
	) &&
	reflink_stable_source many &&
	mkdir ndc &&
	chattr +C ndc &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" \
		git -C many worktree add -q --reflink --detach ../ndc/wt 2>err &&
	test_must_be_empty err &&
	test_reflink_count cloned 0 trace.json &&
	test_reflink_count clone-failed 16 trace.json &&
	(
		cd many &&
		test_same_as_checkout ../ndc/wt HEAD
	)
'

# A reflink source on another filesystem is silently not used.

# other_fs_test <dir>: <dir> is on another filesystem than the trash
# directory.
other_fs_test () {
	other=$1 &&

	# the recipient is on the other filesystem
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" \
		git worktree add -q --reflink --detach "$other/wt" v2 2>err &&
	test_must_be_empty err &&
	test_reflink_count cloned 0 trace.json &&
	test_reflink_count verify-failed 0 trace.json &&
	# found out once, before reading any index: not a single clone tried
	test_reflink_source "(none)" trace.json &&
	test_reflink_count clone-failed 0 trace.json &&
	test_reflink_count source-dirty 0 trace.json &&
	test_same_as_checkout "$other/wt" v2 &&

	# the source is on the other filesystem
	git worktree add -q --no-reflink --detach "$other/src" maint &&
	reflink_stable_source "$other/src" &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" \
		git worktree add -q --reflink-source="$other/src" \
		--detach xfs-r maint 2>err &&
	test_must_be_empty err &&
	test_reflink_count cloned 0 trace.json &&
	test_reflink_count verify-failed 0 trace.json &&
	# found out once, before reading any index: not a single clone tried
	test_reflink_source "(none)" trace.json &&
	test_reflink_count clone-failed 0 trace.json &&
	test_reflink_count source-dirty 0 trace.json &&
	test_same_as_checkout xfs-r maint &&
	git worktree remove --force xfs-r &&

	# both are: that works if the other filesystem can clone
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" \
		git worktree add -q --reflink-source="$other/src" \
		--detach "$other/wt2" maint 2>err &&
	test_must_be_empty err &&
	if test-tool reflink probe "$other"
	then
		test_reflink_source "$other/src" trace.json &&
		test_reflink_count cloned 5 trace.json &&
		test_shared "$other/src/b" "$other/wt2/b"
	else
		test_reflink_count cloned 0 trace.json
	fi &&
	test_same_as_checkout "$other/wt2" maint &&

	git worktree remove --force "$other/wt" &&
	git worktree remove --force "$other/wt2" &&
	git worktree remove --force "$other/src"
}

# detach_image <mountpoint>: detach a disk image. Something (Spotlight,
# say) may still have the new volume open for a moment; retry before
# forcing it.
detach_image () {
	for delay in 1 2 3 4
	do
		hdiutil detach -quiet "$1" 2>/dev/null && return 0
		sleep $delay
	done
	hdiutil detach -quiet -force "$1"
}

# On macOS, a disk image is another filesystem. Creating and attaching
# one can fail on some machines, so that only decides a prerequisite.
for fs in APFS HFS+
do
	img=$(echo "$fs" | tr -d +)
	if test_have_prereq MACOS &&
		mkdir "mnt-$img" &&
		hdiutil create -quiet -size 16m -fs "$fs" -volname "t2411-$img" \
			-o "$img.dmg" >/dev/null 2>&1 &&
		hdiutil attach -quiet -nobrowse -noautoopen \
			-mountpoint "mnt-$img" "$img.dmg" >/dev/null 2>&1
	then
		# keep Spotlight from indexing (and holding open) the volume
		>"mnt-$img/.metadata_never_index"
		test_set_prereq "IMAGE_$img"
	fi

	test_expect_success "IMAGE_$img" "reflink source on another filesystem ($fs disk image)" '
		test_when_finished "git worktree prune" &&
		other_fs_test "$(pwd)/mnt-$img"
	'

	test_expect_success "IMAGE_$img" "cleanup: detach $fs disk image" '
		detach_image "mnt-$img" &&
		rm -rf "mnt-$img" "$img.dmg"
	'
done

# /dev/shm (tmpfs) is another filesystem than the trash directory.
test_lazy_prereq SHM_OTHER_FS '
	test_have_prereq REFLINK_BUILD,!MACOS &&
	test -d /dev/shm &&
	test -w /dev/shm &&
	test "$(stat -c %d /dev/shm)" != "$(stat -c %d "$TRASH_DIRECTORY")"
'

test_expect_success SHM_OTHER_FS 'reflink source on another filesystem (/dev/shm)' '
	other=$(mktemp -d /dev/shm/t2411.XXXXXX) &&
	test_when_finished "git worktree prune" &&
	test_when_finished "rm -rf \"$other\"" &&
	other_fs_test "$other"
'

test_done
