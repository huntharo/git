#!/bin/sh

test_description='reflink checkout: core contract

"git worktree add --reflink" clones files from the main worktree
instead of writing them. The result must be exactly what an ordinary
checkout writes; only the sharing of data blocks may differ.'

. ./test-lib.sh
. "$TEST_DIRECTORY"/lib-reflink.sh

# remove_wt <dir>...: get rid of worktrees made by a test, even half-made.
remove_wt () {
	for wt in "$@"
	do
		rm -rf "$wt" "$wt.expect" || return 1
	done &&
	git worktree prune
}

# restore_main: undo whatever a test did to the main worktree. Every
# tracked file is written anew: "reset --hard" alone would keep e.g. a
# CRLF copy that cleans to the same blob.
restore_main () {
	git read-tree --empty &&
	git reset -q --hard &&
	reflink_stable_source &&
	git clean -q -f -d -x -e "wt-*" -e "*.json" -e "*.tree" \
		-e "*.index" -e "*.status" -e "*.count" -e "expect*" -e "actual*"
}

# file_mtime <path>
file_mtime () {
	test-tool chmtime --get "$1"
}

# file_birthtime <path> (macOS)
file_birthtime () {
	stat -f %B "$1"
}

test_expect_success 'setup' '
	git config checkout.workers 1 &&
	echo "* text=auto" >.gitattributes &&
	printf "ignored/\n*.ign\n" >.gitignore &&
	make_blob_file big1 256 &&
	make_blob_file big2 256 &&
	mkdir dir &&
	make_blob_file dir/big3 128 &&
	make_blob_file big4 128 &&
	make_blob_file exe 128 &&
	chmod +x exe &&
	echo hello >small &&
	>empty &&
	printf "line one\nline two\nline three\n" >crlf.txt &&
	git add . &&
	git update-index --chmod=+x exe &&
	NONEMPTY=9 &&
	if test_have_prereq SYMLINKS
	then
		# a symlink and a regular file with the same blob
		printf same-oid-text >sf &&
		ln -s same-oid-text sl &&
		git add sf sl &&
		NONEMPTY=10
	fi &&
	git commit -q -m initial &&
	git branch -M main &&

	# same blobs, other modes: big1 executable, exe not
	git checkout -q -b modes &&
	chmod +x big1 &&
	chmod -x exe &&
	git update-index --chmod=+x big1 &&
	git update-index --chmod=-x exe &&
	git commit -q -m modes &&
	git checkout -q main &&

	# a branch tracking "p", which main does not track
	git checkout -q -b with-p &&
	make_blob_file p 128 &&
	git add p &&
	git commit -q -m p &&
	git checkout -q main &&
	rm -f p &&

	if test_have_prereq SYMLINKS
	then
		git checkout -q -b swap &&
		git rm -q sf sl &&
		ln -s same-oid-text sf &&
		printf same-oid-text >sl &&
		git add sf sl &&
		git commit -q -m swap &&
		git checkout -q main
	fi &&
	reflink_stable_source &&
	git diff-index --quiet HEAD &&
	git diff-files --quiet
'

test_expect_success 'worktree add --reflink is identical to a normal add' '
	test_when_finished "remove_wt wt-same" &&
	git worktree add -q --detach --reflink wt-same main &&
	test_same_as_checkout wt-same main
'

test_expect_success REFLINK 'worktree add --reflink shares data blocks' '
	test_when_finished "remove_wt wt-share" &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" \
		git worktree add -q --detach --reflink wt-share main &&
	test_reflink_count cloned $NONEMPTY trace.json &&
	test_reflink_count no-donor 0 trace.json &&
	test_reflink_count source-dirty 0 trace.json &&
	test_reflink_count clone-failed 0 trace.json &&
	test_reflink_count verify-failed 0 trace.json &&
	test_reflink_count scratch-donor 0 trace.json &&
	test_shared big1 wt-share/big1 &&
	test_shared big2 wt-share/big2 &&
	test_shared dir/big3 wt-share/dir/big3 &&
	test_shared exe wt-share/exe &&
	test_not_shared big1 wt-share/big2 &&
	test_same_as_checkout wt-share main
'

test_expect_success 'worktree add --reflink writes an empty reflink-source file' '
	test_when_finished "remove_wt wt-marker" &&
	git worktree add -q --detach --reflink wt-marker main &&
	test_path_is_file .git/worktrees/wt-marker/reflink-source &&
	test_must_be_empty .git/worktrees/wt-marker/reflink-source
'

test_expect_success 'no cloning without --reflink or checkout.reflink' '
	test_when_finished "remove_wt wt-plain" &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" \
		git worktree add -q --detach wt-plain main &&
	test_path_is_missing .git/worktrees/wt-plain/reflink-source &&
	test_grep ! "\"category\":\"reflink\"" trace.json &&
	test_not_shared big1 wt-plain/big1 &&
	rm wt-plain/big1 &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" \
		git -C wt-plain checkout -- big1 &&
	test_reflink_count cloned 0 trace.json &&
	test_not_shared big1 wt-plain/big1
'

test_expect_success REFLINK 'checkout.reflink=true enables cloning' '
	test_when_finished "remove_wt wt-config" &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" \
		git -c checkout.reflink=true worktree add -q --detach wt-config main &&
	test_reflink_count cloned $NONEMPTY trace.json &&
	test_path_is_missing .git/worktrees/wt-config/reflink-source &&
	test_shared big1 wt-config/big1 &&

	rm wt-config/big2 &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" \
		git -C wt-config -c checkout.reflink=true checkout -- big2 &&
	test_reflink_count cloned 1 trace.json &&
	test_shared big2 wt-config/big2 &&
	test_same_as_checkout wt-config main
'

test_expect_success REFLINK 'reflink-source file keeps later checkouts cloning' '
	test_when_finished "remove_wt wt-later" &&
	git worktree add -q --detach --reflink wt-later main &&
	rm wt-later/big1 &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" \
		git -C wt-later checkout -- big1 &&
	test_reflink_count cloned 1 trace.json &&
	test_shared big1 wt-later/big1
'

test_expect_success REFLINK 'checkout.reflink=false is a kill switch for later checkouts' '
	test_when_finished "remove_wt wt-kill" &&
	test_config checkout.reflink false &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" \
		git worktree add -q --detach --reflink wt-kill main 2>err &&
	test_grep "checkout.reflink is false" err &&
	# the command line wins for the initial checkout
	test_reflink_count cloned $NONEMPTY trace.json &&
	test_path_is_file .git/worktrees/wt-kill/reflink-source &&
	test_shared big1 wt-kill/big1 &&

	rm wt-kill/big1 &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" \
		git -C wt-kill checkout -- big1 &&
	test_reflink_count cloned 0 trace.json &&
	test_not_shared big1 wt-kill/big1 &&
	test_same_as_checkout wt-kill main
'

test_expect_success 'a non-boolean checkout.reflink disables cloning, does not die' '
	test_when_finished "remove_wt wt-bogus" &&
	git worktree add -q --detach --no-reflink wt-bogus main &&
	rm wt-bogus/big1 &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" \
		git -C wt-bogus -c checkout.reflink=bogus checkout -- big1 2>err &&
	if test_have_prereq REFLINK_BUILD
	then
		test_grep "bad boolean config value" err
	else
		# without reflink checkout, the setting is never read
		test_must_be_empty err
	fi &&
	test_reflink_count cloned 0 trace.json &&
	test_same_as_checkout wt-bogus main
'

test_expect_success '--no-reflink beats checkout.reflink=true' '
	test_when_finished "remove_wt wt-noreflink" &&
	test_config checkout.reflink true &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" \
		git worktree add -q --detach --no-reflink wt-noreflink main &&
	test_reflink_count cloned 0 trace.json &&
	test_path_is_missing .git/worktrees/wt-noreflink/reflink-source &&
	test_same_as_checkout wt-noreflink main
'

test_expect_success REFLINK '--no-reflink beats checkout.reflink=true (no sharing)' '
	test_when_finished "remove_wt wt-noreflink2" &&
	test_config checkout.reflink true &&
	git worktree add -q --detach --no-reflink wt-noreflink2 main &&
	test_not_shared big1 wt-noreflink2/big1 &&
	test_not_shared exe wt-noreflink2/exe
'

test_expect_success '--reflink-source and --no-reflink are incompatible' '
	test_must_fail git worktree add --no-reflink --reflink-source=. \
		wt-bad main 2>err &&
	test_grep "cannot be used together" err &&
	test_path_is_missing wt-bad
'

test_expect_success REFLINK 'clones get a fresh mtime even from an old donor' '
	test_when_finished "remove_wt wt-mtime && restore_main" &&
	test-tool chmtime =-100000 big1 big2 &&
	git update-index --refresh &&
	>start-stamp &&
	start=$(file_mtime start-stamp) &&
	test $(file_mtime big1) -lt $((start - 50000)) &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" \
		git worktree add -q --detach --reflink wt-mtime main &&
	test_reflink_count cloned $NONEMPTY trace.json &&
	test_shared big1 wt-mtime/big1 &&
	test_shared big2 wt-mtime/big2 &&
	test $(file_mtime wt-mtime/big1) -ge $start &&
	test $(file_mtime wt-mtime/big2) -ge $start &&
	# the index records the new stat data: clean without a refresh
	git -C wt-mtime diff-files --quiet &&
	test_same_as_checkout wt-mtime main
'

test_expect_success REFLINK,MACOS 'clones get a fresh birthtime even from an old donor' '
	test_when_finished "remove_wt wt-birth && restore_main" &&
	test-tool chmtime =-100000 big1 &&
	git update-index --refresh &&
	>start-stamp &&
	start=$(file_birthtime start-stamp) &&
	# setting an older mtime moved the birthtime back too
	test $(file_birthtime big1) -lt $((start - 50000)) &&
	git worktree add -q --detach --reflink wt-birth main &&
	test_shared big1 wt-birth/big1 &&
	test $(file_birthtime wt-birth/big1) -ge $start
'

test_expect_success REFLINK,POSIXPERM 'clones get their permissions from the umask (077)' '
	test_when_finished "remove_wt wt-u077 wt-u077ref" &&
	(
		umask 077 &&
		git worktree add -q --detach --reflink wt-u077 main &&
		git worktree add -q --detach --no-reflink wt-u077ref main
	) &&
	test_shared big1 wt-u077/big1 &&
	test_shared exe wt-u077/exe &&
	test_modebits wt-u077/big1 >actual &&
	echo "-rw-------" >expect &&
	test_cmp expect actual &&
	test_modebits wt-u077ref/big1 >actual &&
	test_cmp expect actual &&
	test_modebits wt-u077/exe >actual &&
	echo "-rwx------" >expect &&
	test_cmp expect actual &&
	test_modebits wt-u077ref/exe >actual &&
	test_cmp expect actual
'

test_expect_success REFLINK,POSIXPERM 'clones get their permissions from the umask (022)' '
	test_when_finished "remove_wt wt-u022 && chmod 644 big1 && chmod 755 exe && restore_main" &&
	# a donor with unusual permissions that its index cannot see
	chmod 600 big1 &&
	chmod 700 exe &&
	git update-index --refresh &&
	(
		umask 022 &&
		git worktree add -q --detach --reflink wt-u022 main
	) &&
	test_shared big1 wt-u022/big1 &&
	test_shared exe wt-u022/exe &&
	test_modebits wt-u022/big1 >actual &&
	echo "-rw-r--r--" >expect &&
	test_cmp expect actual &&
	test_modebits wt-u022/exe >actual &&
	echo "-rwxr-xr-x" >expect &&
	test_cmp expect actual
'

test_expect_success REFLINK,POSIXPERM 'executable bit comes from the index entry, not the donor' '
	test_when_finished "remove_wt wt-modes" &&
	# main has big1 as 100644 and exe as 100755; "modes" the reverse
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" \
		git worktree add -q --detach --reflink wt-modes modes &&
	test_reflink_count cloned $NONEMPTY trace.json &&
	test_shared big1 wt-modes/big1 &&
	test_shared exe wt-modes/exe &&
	test -x wt-modes/big1 &&
	! test -x wt-modes/exe &&
	test_same_as_checkout wt-modes modes
'

test_expect_success REFLINK,POSIXPERM 'executable donor whose index says 100644 (core.fileMode=false)' '
	test_when_finished "remove_wt wt-filemode && chmod -x big1 && chmod +x exe && restore_main" &&
	chmod +x big1 &&
	chmod -x exe &&
	git -c core.fileMode=false update-index --refresh &&
	git ls-files -s big1 >actual &&
	test_grep "^100644 " actual &&
	git ls-files -s exe >actual &&
	test_grep "^100755 " actual &&
	git worktree add -q --detach --reflink wt-filemode main &&
	test_shared big1 wt-filemode/big1 &&
	test_shared exe wt-filemode/exe &&
	! test -x wt-filemode/big1 &&
	test -x wt-filemode/exe &&
	test_same_as_checkout wt-filemode main
'

test_expect_success REFLINK,MACOS 'extended attributes of the donor are not cloned' '
	test_when_finished "remove_wt wt-xattr && xattr -c big1 big2 && restore_main" &&
	xattr -w com.apple.quarantine "0081;00000000;Test;" big1 &&
	xattr -w org.git-scm.test "secret" big2 &&
	git update-index --refresh &&
	xattr big1 >actual &&
	test_grep com.apple.quarantine actual &&
	git worktree add -q --detach --reflink wt-xattr main &&
	test_shared big1 wt-xattr/big1 &&
	test_shared big2 wt-xattr/big2 &&
	xattr wt-xattr/big1 wt-xattr/big2 >actual &&
	test_grep ! -e com.apple.quarantine -e org.git-scm.test actual &&
	sed -e "/com.apple.provenance/d" actual >others &&
	test_must_be_empty others
'

# file_owner <path>: numeric owner and group of <path>
file_owner () {
	ls -nd "$1" | awk "{ print \$3, \$4 }"
}

# other_group: a group of ours that a new file in the trash directory
# does not get
other_group () {
	>"$TRASH_DIRECTORY/.git/group-probe" &&
	new=$(file_owner "$TRASH_DIRECTORY/.git/group-probe" | cut -d" " -f2) &&
	rm -f "$TRASH_DIRECTORY/.git/group-probe" &&
	for g in $(id -G)
	do
		if test "$g" != "$new"
		then
			echo "$g" &&
			return 0
		fi
	done &&
	return 1
}

test_lazy_prereq OTHER_GROUP '
	other_group >/dev/null
'

test_expect_success REFLINK,POSIXPERM,OTHER_GROUP 'clones get the owner and group of a new file, not the donor'"'"'s' '
	# A directory can give a new file a group we cannot chgrp back to
	# (e.g. wheel under /tmp on macOS). Recreate it during cleanup.
	test_when_finished "remove_wt wt-grp wt-grpref && restore_main" &&
	chgrp $(other_group) big1 &&
	git update-index --refresh &&
	git worktree add -q --detach --reflink wt-grp main &&
	git worktree add -q --detach --no-reflink wt-grpref main &&
	test_shared big1 wt-grp/big1 &&
	file_owner wt-grpref/big1 >expect &&
	file_owner wt-grp/big1 >actual &&
	test_cmp expect actual &&
	file_owner big1 >donor &&
	! test_cmp donor actual
'

test_expect_success REFLINK,MACOS 'ACLs: inherited as by a new file, never cloned' '
	test_when_finished "chmod -N big1 && git update-index -q --refresh &&
		remove_wt wt-acl wt-aclref" &&
	chmod +a "group:everyone deny write" big1 &&
	git update-index --refresh &&
	mkdir wt-acl wt-aclref &&
	chmod +a "group:everyone allow read,file_inherit" wt-acl wt-aclref &&
	git worktree add -q --detach --reflink wt-acl main &&
	git worktree add -q --detach --no-reflink wt-aclref main &&
	test_shared big1 wt-acl/big1 &&
	ls -le wt-aclref/big1 | sed -e 1d >expect &&
	ls -le wt-acl/big1 | sed -e 1d >actual &&
	test_cmp expect actual &&
	test_grep "inherited allow read" actual &&
	test_grep ! "deny write" actual
'

test_lazy_prereq SETFACL '
	>acl-probe &&
	setfacl -m "u:$(id -u):r" acl-probe &&
	getfacl -n acl-probe 2>/dev/null | grep "^user:$(id -u):r"
'

test_expect_success REFLINK,SETFACL 'POSIX ACLs: inherited as by a new file, never cloned' '
	test_when_finished "setfacl -b big1 && git update-index -q --refresh &&
		remove_wt wt-acl wt-aclref" &&
	uid=$(id -u) &&
	setfacl -m "u:$uid:r" big1 &&
	git update-index --refresh &&
	mkdir wt-acl wt-aclref &&
	setfacl -d -m "u:$uid:rw" wt-acl wt-aclref &&
	git worktree add -q --detach --reflink wt-acl main &&
	git worktree add -q --detach --no-reflink wt-aclref main &&
	test_shared big1 wt-acl/big1 &&
	getfacl -n --omit-header wt-aclref/big1 >expect &&
	getfacl -n --omit-header wt-acl/big1 >actual &&
	test_cmp expect actual &&
	test_grep "^user:$uid:rw-" actual &&
	test_grep ! "^user:$uid:r--" actual
'

test_expect_success REFLINK,SANITY 'an unreadable donor file is written normally, without trying to clone it' '
	test_when_finished "chmod 644 big2 && remove_wt wt-unreadable && restore_main" &&
	chmod 000 big2 &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" \
		git worktree add -q --detach --reflink wt-unreadable main &&
	test_reflink_count cloned $(($NONEMPTY - 1)) trace.json &&
	test_reflink_count source-dirty 1 trace.json &&
	test_reflink_count clone-failed 0 trace.json &&
	test_shared big1 wt-unreadable/big1 &&
	chmod 644 big2 &&
	test_not_shared big2 wt-unreadable/big2 &&
	test_same_as_checkout wt-unreadable main
'

prepare_dirty_donors () {
	# modified, not refreshed
	echo changed >>big1 &&
	# modified, refresh attempted: the index still says "dirty"
	echo changed >>big2 &&
	# modified and staged: the index has a different blob
	echo changed >>small &&
	git add small &&
	# chmod, refresh attempted with core.fileMode=true. Only the
	# ctime tells; without USE_NSEC that is invisible within the same
	# second. Harmless: the bytes are right and the mode comes from
	# the index.
	chmod -x exe &&
	test_must_fail git update-index --refresh &&
	# deleted
	rm dir/big3 &&
	# replaced by a symlink to a file with the same bytes
	if test_have_prereq SYMLINKS
	then
		git show HEAD:crlf.txt >crlf.copy &&
		rm crlf.txt &&
		ln -s crlf.copy crlf.txt
	fi
}

test_expect_success 'dirty donors: result is identical to a normal add' '
	test_when_finished "remove_wt wt-dirty && restore_main" &&
	prepare_dirty_donors &&
	git worktree add -q --detach --reflink wt-dirty main &&
	test_same_as_checkout wt-dirty main
'

test_expect_success REFLINK 'dirty donors are never cloned' '
	test_when_finished "remove_wt wt-dirty && restore_main" &&
	prepare_dirty_donors &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" \
		git worktree add -q --detach --reflink wt-dirty main &&
	if test_have_prereq SYMLINKS
	then
		dirty=4
	else
		dirty=3
	fi &&
	# "exe" may or may not count as dirty, see above
	if test-tool reflink shared exe wt-dirty/exe
	then
		test_reflink_count source-dirty $dirty trace.json
	else
		dirty=$((dirty + 1)) &&
		test_reflink_count source-dirty $dirty trace.json
	fi &&
	test_reflink_count no-donor 1 trace.json &&
	test_reflink_count verify-failed 0 trace.json &&
	test_reflink_count cloned $((NONEMPTY - dirty - 1)) trace.json &&
	test_not_shared big1 wt-dirty/big1 &&
	test_not_shared big2 wt-dirty/big2 &&
	# (too small to ask about sharing: btrfs keeps it inline; the
	# no-donor count and the content check below cover it)
	# executable as in HEAD, although the donor is not
	test -x wt-dirty/exe &&
	test_shared big4 wt-dirty/big4 &&
	for f in big1 big2 small exe dir/big3 crlf.txt
	do
		git show HEAD:$f >expect &&
		test_cmp expect wt-dirty/$f || return 1
	done &&
	test_same_as_checkout wt-dirty main
'

test_expect_success REFLINK 'CRLF donor under text=auto is ineligible' '
	test_when_finished "remove_wt wt-crlf && restore_main" &&
	rm crlf.txt &&
	git -c core.autocrlf=true checkout -- crlf.txt &&
	printf "line one\r\nline two\r\nline three\r\n" >expect &&
	test_cmp expect crlf.txt &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" \
		git worktree add -q --detach --reflink wt-crlf main &&
	test_reflink_count verify-failed 0 trace.json &&
	test_reflink_count source-dirty 1 trace.json &&
	test_reflink_count cloned $((NONEMPTY - 1)) trace.json &&
	git show HEAD:crlf.txt >expect &&
	test_cmp expect wt-crlf/crlf.txt &&
	test_same_as_checkout wt-crlf main
'

test_expect_success REFLINK 'same-size edit with the mtime restored is never cloned' '
	test_when_finished "remove_wt wt-samesize && restore_main" &&
	mtime=$(file_mtime big2) &&
	sleep 1 &&
	make_blob_file big2 256 other-seed &&
	test-tool chmtime =$mtime big2 &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" \
		git worktree add -q --detach --reflink wt-samesize main &&
	test_reflink_count cloned $((NONEMPTY - 1)) trace.json &&
	test_not_shared big2 wt-samesize/big2 &&
	git show HEAD:big2 >expect &&
	test_cmp expect wt-samesize/big2 &&
	test_same_as_checkout wt-samesize main
'

test_expect_success REFLINK 'minimal stat checking declines cloning without extra verification' '
	test_when_finished "remove_wt wt-minimal && restore_main" &&
	# without ctime, inode and nanoseconds the edit looks clean
	test_config core.checkStat minimal &&
	mtime=$(file_mtime big2) &&
	make_blob_file big2 256 other-seed &&
	test-tool chmtime =$mtime big2 &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" \
		git worktree add -q --detach --reflink wt-minimal main &&
	test_reflink_count verify-failed 0 trace.json &&
	test_reflink_count source-dirty $NONEMPTY trace.json &&
	test_reflink_count cloned 0 trace.json &&
	test_not_shared big2 wt-minimal/big2 &&
	git show HEAD:big2 >expect &&
	test_cmp expect wt-minimal/big2 &&
	test_same_as_checkout wt-minimal main
'

test_expect_success REFLINK 'donor modified after phase one fails verification' '
	test_when_finished "remove_wt wt-tamper && restore_main" &&
	rm -f trace.json &&
	GIT_TEST_REFLINK_TAMPER=big1 GIT_TRACE2_EVENT="$TRACE_JSON" \
		git worktree add -q --detach --reflink wt-tamper main &&
	test_reflink_count verify-failed 1 trace.json &&
	test_reflink_count cloned $((NONEMPTY - 1)) trace.json &&
	# the donor really was changed
	git show HEAD:big1 >expect &&
	echo tampered >>expect &&
	test_cmp expect big1 &&
	test_not_shared big1 wt-tamper/big1 &&
	git show HEAD:big1 >expect &&
	test_cmp expect wt-tamper/big1 &&
	test_same_as_checkout wt-tamper main
'

test_expect_success REFLINK 'donor replaced by a directory after phase one' '
	test_when_finished "remove_wt wt-replace && rm -rf big1 big1.tampered && restore_main" &&
	test_config core.useNanoSec true &&
	rm -f trace.json &&
	GIT_TEST_REFLINK_TAMPER=big1:replace \
	GIT_TRACE2_EVENT="$TRACE_JSON" \
		git worktree add -q --detach --reflink wt-replace main &&
	test_path_is_file big1/untracked &&
	test_path_is_file big1.tampered &&
	# The open descriptor remains safe, but rename changed its ctime.
	# The normal stat recheck conservatively falls back.
	test_reflink_count cloned $((NONEMPTY - 1)) trace.json &&
	test_path_is_file wt-replace/big1 &&
	! test -h wt-replace/big1 &&
	test_path_is_missing wt-replace/big1.tampered &&
	test_not_shared big1.tampered wt-replace/big1 &&
	git show HEAD:big1 >expect &&
	test_cmp expect wt-replace/big1 &&
	find wt-replace -name untracked >actual &&
	test_must_be_empty actual &&
	test_same_as_checkout wt-replace main
'

test_expect_success 'untracked and ignored files of the donor never appear' '
	test_when_finished "remove_wt wt-untracked && restore_main" &&
	echo untracked >untracked-file &&
	mkdir -p untracked-dir ignored &&
	echo untracked >untracked-dir/file &&
	echo ignored >ignored/file &&
	echo ignored >file.ign &&
	echo ignored >dir/file.ign &&
	# untracked in main, tracked with the same bytes in with-p
	git show with-p:p >p &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" \
		git worktree add -q --detach --reflink wt-untracked with-p &&
	test_path_is_missing wt-untracked/untracked-file &&
	test_path_is_missing wt-untracked/untracked-dir &&
	test_path_is_missing wt-untracked/ignored &&
	test_path_is_missing wt-untracked/file.ign &&
	test_path_is_missing wt-untracked/dir/file.ign &&
	git -C wt-untracked status --porcelain --ignored >actual &&
	test_must_be_empty actual &&
	test_same_as_checkout wt-untracked with-p
'

test_expect_success REFLINK 'untracked donor file with the right bytes is not cloned' '
	test_when_finished "remove_wt wt-untracked2 && restore_main" &&
	git show with-p:p >p &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" \
		git worktree add -q --detach --reflink wt-untracked2 with-p &&
	test_reflink_count no-donor 1 trace.json &&
	test_reflink_count cloned $NONEMPTY trace.json &&
	test_not_shared p wt-untracked2/p &&
	test_same_as_checkout wt-untracked2 with-p
'

test_expect_success REFLINK 'copy-on-write: editing either copy leaves the other alone' '
	test_when_finished "remove_wt wt-cow && restore_main" &&
	git worktree add -q --detach --reflink wt-cow main &&
	test_shared big1 wt-cow/big1 &&
	test_shared big2 wt-cow/big2 &&
	git show HEAD:big1 >expect1 &&
	git show HEAD:big2 >expect2 &&

	# in place, keeping the inode and the size
	printf XXXX | dd of=wt-cow/big1 conv=notrunc 2>/dev/null &&
	test_cmp expect1 big1 &&
	! cmp -s expect1 wt-cow/big1 &&

	printf YYYY | dd of=big2 conv=notrunc 2>/dev/null &&
	test_cmp expect2 wt-cow/big2 &&
	! cmp -s expect2 big2 &&

	git -C wt-cow diff --name-only >actual &&
	echo big1 >expect &&
	test_cmp expect actual &&
	git diff --name-only >actual &&
	echo big2 >expect &&
	test_cmp expect actual
'

test_expect_success 'empty files are created, not cloned' '
	test_when_finished "remove_wt wt-empty" &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" \
		git worktree add -q --detach --reflink wt-empty main &&
	test_path_is_file wt-empty/empty &&
	test_must_be_empty wt-empty/empty &&
	if test_have_prereq REFLINK
	then
		test_reflink_count no-donor 0 trace.json &&
		test_reflink_count source-dirty 0 trace.json &&
		test_reflink_count verify-failed 0 trace.json &&
		test_reflink_count clone-failed 0 trace.json
	fi &&
	test_same_as_checkout wt-empty main
'

test_expect_success SYMLINKS 'symlink and regular file with the same blob' '
	test_when_finished "remove_wt wt-swap" &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" \
		git worktree add -q --detach --reflink wt-swap swap &&
	test -h wt-swap/sf &&
	test_readlink wt-swap/sf >actual &&
	echo same-oid-text >expect &&
	test_cmp expect actual &&
	test_path_is_file wt-swap/sl &&
	! test -h wt-swap/sl &&
	printf same-oid-text >expect &&
	test_cmp expect wt-swap/sl &&
	test_same_as_checkout wt-swap swap
'

test_expect_success REFLINK,SYMLINKS 'a symlink is never a donor for a regular file' '
	test_when_finished "remove_wt wt-swap2" &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" \
		git worktree add -q --detach --reflink wt-swap2 swap &&
	# "sl" has a symlink donor; "sf" is a symlink, so not cloned
	test_reflink_count no-donor 1 trace.json &&
	test_reflink_count source-dirty 0 trace.json &&
	test_reflink_count cloned $((NONEMPTY - 1)) trace.json
'

test_expect_success 'GIT_TEST_REFLINK_CHECKOUT=corrupt gives identical results' '
	test_when_finished "remove_wt wt-corrupt" &&
	rm -f trace.json &&
	GIT_TEST_REFLINK_CHECKOUT=corrupt GIT_TRACE2_EVENT="$TRACE_JSON" \
		git worktree add -q --detach --reflink wt-corrupt modes &&
	test_reflink_count cloned 0 trace.json &&
	test_same_as_checkout wt-corrupt modes
'

test_expect_success REFLINK 'GIT_TEST_REFLINK_CHECKOUT=corrupt: every clone is rejected' '
	test_when_finished "remove_wt wt-corrupt2" &&
	rm -f trace.json &&
	GIT_TEST_REFLINK_CHECKOUT=corrupt GIT_TRACE2_EVENT="$TRACE_JSON" \
		git worktree add -q --detach wt-corrupt2 main &&
	test_reflink_count cloned 0 trace.json &&
	# test mode tries every regular file, the empty one too
	test_reflink_count scratch-donor $((NONEMPTY + 1)) trace.json &&
	test_reflink_count verify-failed $((NONEMPTY + 1)) trace.json &&
	test_not_shared big1 wt-corrupt2/big1 &&
	test_path_is_missing .git/worktrees/wt-corrupt2/reflink-source &&
	test_same_as_checkout wt-corrupt2 main
'

test_expect_success REFLINK 'parallel checkout workers clone too' '
	test_when_finished "remove_wt wt-parallel" &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" \
		git -c checkout.workers=4 -c checkout.thresholdForParallelism=1 \
		worktree add -q --detach --reflink wt-parallel main &&
	test_reflink_count cloned $NONEMPTY trace.json &&
	test_shared big1 wt-parallel/big1 &&
	test_shared dir/big3 wt-parallel/dir/big3 &&
	test_same_as_checkout wt-parallel main
'

test_done
