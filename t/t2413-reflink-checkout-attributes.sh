#!/bin/sh

test_description='reflink checkout: attributes, filters and other features

EOL output must match the recipient conversion. Ident expansion,
working-tree-encoding and filter drivers use the ordinary writer.
Sparse checkout, split index, fsmonitor, submodules, symlinks, modes
and case-insensitive filesystems must all give exactly the result of
an ordinary checkout.'

. ./test-lib.sh
. "$TEST_DIRECTORY"/lib-reflink.sh

# The split index tests below enable it themselves; a forced split index
# would get in the way of the sparse index ones.
GIT_TEST_SPLIT_INDEX=0
export GIT_TEST_SPLIT_INDEX

# remove_wt <dir>...: get rid of worktrees made by a test, even half-made.
remove_wt () {
	for wt in "$@"
	do
		rm -rf "$wt" "$wt.expect" || return 1
	done &&
	git worktree prune
}

# test_all_shared <src> <dst> <path>...: each <path> shares its data
# blocks between the worktrees <src> and <dst>.
test_all_shared () {
	src=$1 dst=$2 &&
	shift 2 &&
	for p in "$@"
	do
		test_shared "$src/$p" "$dst/$p" || return 1
	done
}

# test_none_shared <src> <dst> <path>...
test_none_shared () {
	src=$1 dst=$2 &&
	shift 2 &&
	for p in "$@"
	do
		test_not_shared "$src/$p" "$dst/$p" || return 1
	done
}

# test_counts <trace> <cloned> <no-donor> <source-dirty> <verify-failed>
# Also checks that no clone failed and no scratch donor was used.
test_counts () {
	test_reflink_count cloned "$2" "$1" &&
	test_reflink_count no-donor "$3" "$1" &&
	test_reflink_count source-dirty "$4" "$1" &&
	test_reflink_count verify-failed "$5" "$1" &&
	test_reflink_count clone-failed 0 "$1" &&
	test_reflink_count scratch-donor 0 "$1"
}

# test_same_worktree <expect> <actual>: two worktrees made by the same
# commands, one without reflink, have the same files, index and status.
test_same_worktree () {
	describe_tree "$1" >expect.tree &&
	describe_tree "$2" >actual.tree &&
	test_cmp expect.tree actual.tree &&
	git -C "$1" ls-files -s -t >expect.index &&
	git -C "$2" ls-files -s -t >actual.index &&
	test_cmp expect.index actual.index &&
	git -C "$1" status --porcelain=v1 --untracked-files=all >expect.status &&
	git -C "$2" status --porcelain=v1 --untracked-files=all >actual.status &&
	test_cmp expect.status actual.status
}

# Tests that assert cloning (prerequisite REFLINK) are followed by one
# that checks, on any filesystem, that the same commands give exactly
# what an ordinary checkout gives.

# Files of "main"; all of them hold their blob unconverted there.
FILES="plain.txt id.txt noid.txt rot.txt proc.txt nodriver.txt utf.txt
bin.dat exe.sh in/a.txt in/b.txt out/c.txt out/d/e.txt
deep/er/est/nested.txt"
# Files outside the cone "in" (top-level files are always in it).
OUTSIDE="out/c.txt out/d/e.txt deep/er/est/nested.txt"
INSIDE="plain.txt id.txt noid.txt rot.txt proc.txt nodriver.txt utf.txt
bin.dat exe.sh in/a.txt in/b.txt"
# Paths that "convert" gives a conversion that "main" does not have.
CONVERTED="plain.txt id.txt noid.txt rot.txt proc.txt"
UNCONVERTED="nodriver.txt utf.txt bin.dat exe.sh in/a.txt in/b.txt
out/c.txt out/d/e.txt deep/er/est/nested.txt"

test_expect_success 'setup' '
	git symbolic-ref HEAD refs/heads/main &&
	git config checkout.workers 1 &&
	git config filter.rot13.smudge "tr A-Za-z N-ZA-Mn-za-m" &&
	git config filter.rot13.clean "tr A-Za-z N-ZA-Mn-za-m" &&
	git config filter.protocol.process \
		"test-tool rot13-filter --log=\"$(pwd)/.git/rot13.log\" clean smudge" &&
	git config filter.protocol.required true &&

	# the aws-cdk case: text=auto eol=lf on everything
	cat >.gitattributes <<-\EOF &&
	* text=auto eol=lf
	bin.dat binary
	nodriver.txt filter=nodriver
	EOF
	for f in $FILES
	do
		mkdir -p "$(dirname "$f")" &&
		make_blob_file "$f" 64 || return 1
	done &&
	{
		echo "\$Id\$" &&
		make_blob_file id.body 64 &&
		cat id.body
	} >id.txt &&
	rm id.body &&
	test-tool genrandom bin.dat 65536 >bin.dat &&
	chmod +x exe.sh &&
	git add . &&
	git update-index --chmod=+x exe.sh &&
	if test_have_prereq SYMLINKS
	then
		ln -s plain.txt link &&
		ln -s deep/er dirlink &&
		git add link dirlink
	fi &&
	git commit -q -m main &&

	git worktree add -q --no-reflink --detach scratch main &&

	# "convert": the same blobs, but most of them converted
	cat >scratch/.gitattributes <<-\EOF &&
	* text=auto eol=lf
	bin.dat binary
	nodriver.txt filter=nodriver
	plain.txt eol=crlf
	id.txt ident
	noid.txt ident
	rot.txt filter=rot13
	proc.txt filter=protocol
	EOF
	git -C scratch add .gitattributes &&
	git -C scratch commit -q -m convert &&
	git -C scratch branch convert &&

	# "noeol": no eol attribute, so core.autocrlf decides
	git -C scratch reset -q --hard main &&
	echo "bin.dat binary" >scratch/.gitattributes &&
	git -C scratch commit -q -a -m noeol &&
	git -C scratch branch noeol &&

	# "modes": the same blobs, plain.txt executable, exe.sh not
	git -C scratch reset -q --hard main &&
	git -C scratch update-index --chmod=+x plain.txt &&
	git -C scratch update-index --chmod=-x exe.sh &&
	git -C scratch commit -q -m modes &&
	git -C scratch branch modes &&

	# "case-rename": in/a.txt renamed to in/A.txt
	git -C scratch reset -q --hard main &&
	a=$(git rev-parse main:in/a.txt) &&
	git -C scratch rm -q --cached in/a.txt &&
	git -C scratch update-index --add --cacheinfo 100644,$a,in/A.txt &&
	git -C scratch commit -q -m case-rename &&
	git -C scratch branch case-rename &&

	# "case-collide": in/A.txt added next to in/a.txt
	git -C scratch reset -q --hard main &&
	b=$(git rev-parse main:in/b.txt) &&
	git -C scratch update-index --add --cacheinfo 100644,$b,in/A.txt &&
	git -C scratch commit -q -m case-collide &&
	git -C scratch branch case-collide &&

	git worktree remove --force scratch &&
	reflink_stable_source &&
	git status --porcelain=v1 --untracked-files=no >actual &&
	test_must_be_empty actual
'

test_expect_success REFLINK 'text=auto eol=lf: every file is cloned' '
	test_when_finished "remove_wt wt" &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" \
		git worktree add -q --detach --reflink wt main &&
	test_counts trace.json 15 0 0 0 &&
	# including files in directories that had to be created
	test_path_is_dir wt/deep/er/est &&
	test_all_shared . wt $FILES
'

test_expect_success 'text=auto eol=lf: same as a normal checkout' '
	test_when_finished "remove_wt wt" &&
	git worktree add -q --detach --reflink wt main &&
	for f in $FILES
	do
		test_cmp "$f" "wt/$f" || return 1
	done &&
	test_same_as_checkout wt main
'

test_expect_success REFLINK 'converted paths are written normally' '
	test_when_finished "remove_wt wt" &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" \
		git worktree add -q --detach --reflink wt convert &&
	# .gitattributes differs, so it has no donor
	test_counts trace.json 9 1 0 1 &&
	test_all_shared . wt $UNCONVERTED &&
	test_none_shared . wt $CONVERTED
'

test_expect_success 'converted paths: same as a normal checkout' '
	test_when_finished "remove_wt wt" &&
	git worktree add -q --detach --reflink wt convert &&
	test_has_crlf wt/plain.txt &&
	head -n 1 wt/id.txt >actual &&
	echo "\$Id: $(git rev-parse convert:id.txt) \$" >expect &&
	test_cmp expect actual &&
	test_cmp noid.txt wt/noid.txt &&
	tr A-Za-z N-ZA-Mn-za-m <rot.txt >expect &&
	test_cmp expect wt/rot.txt &&
	tr A-Za-z N-ZA-Mn-za-m <proc.txt >expect &&
	test_cmp expect wt/proc.txt &&
	test_cmp nodriver.txt wt/nodriver.txt &&
	test_same_as_checkout wt convert
'

test_expect_success REFLINK 'parallel checkout workers honour eligibility' '
	test_when_finished "remove_wt wt" &&
	test_config checkout.workers 2 &&
	test_config checkout.thresholdForParallelism 0 &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" \
		git worktree add -q --detach --reflink wt convert &&
	test_counts trace.json 9 1 0 1 &&
	grep "\"category\":\"reflink\",\"name\":\"cloned\"" trace.json >workers &&
	test_line_count -gt 1 workers &&
	test_all_shared . wt $UNCONVERTED &&
	test_none_shared . wt $CONVERTED &&
	test_same_as_checkout wt convert
'

test_expect_success REFLINK 'converted donors are ineligible' '
	test_when_finished "remove_wt src wt" &&
	git worktree add -q --detach --no-reflink src convert &&
	reflink_stable_source src &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" \
		git worktree add -q --detach --reflink-source=src wt main &&
	# plain.txt (CRLF), id.txt (expanded), rot.txt and proc.txt
	# (smudged) do not hold their blob in "src"; noid.txt does.
	# .gitattributes differs, so it has no donor.
	test_counts trace.json 10 1 4 0 &&
	test_all_shared src wt noid.txt $UNCONVERTED &&
	test_none_shared src wt plain.txt id.txt rot.txt proc.txt
'

test_expect_success 'converted donors: same as a normal checkout' '
	test_when_finished "remove_wt src wt" &&
	git worktree add -q --detach --no-reflink src convert &&
	reflink_stable_source src &&
	git worktree add -q --detach --reflink-source=src wt main &&
	for f in $FILES
	do
		test_cmp "$f" "wt/$f" || return 1
	done &&
	test_same_as_checkout wt main
'

test_expect_success REFLINK 'core.autocrlf=true: only binary files are cloned' '
	test_when_finished "remove_wt wt" &&
	test_config core.autocrlf true &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" \
		git worktree add -q --detach --reflink wt noeol &&
	test_counts trace.json 1 1 0 13 &&
	test_all_shared . wt bin.dat &&
	test_none_shared . wt plain.txt in/a.txt nodriver.txt &&
	test_has_crlf wt/plain.txt
'

test_expect_success 'core.autocrlf=true: same as a normal checkout' '
	test_when_finished "remove_wt wt" &&
	test_config core.autocrlf true &&
	git worktree add -q --detach --reflink wt noeol &&
	test_cmp bin.dat wt/bin.dat &&
	test_same_as_checkout wt noeol
'

test_expect_success REFLINK 'core.autocrlf=input: everything is cloned' '
	test_when_finished "remove_wt wt" &&
	test_config core.autocrlf input &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" \
		git worktree add -q --detach --reflink wt noeol &&
	test_counts trace.json 14 1 0 0 &&
	test_all_shared . wt $FILES
'

test_expect_success ICONV 'setup working-tree-encoding' '
	git worktree add -q --no-reflink --detach scratch main &&
	cp .gitattributes scratch/.gitattributes &&
	echo "utf.txt working-tree-encoding=UTF-16" >>scratch/.gitattributes &&
	git -C scratch add .gitattributes &&
	git -C scratch commit -q -m utf16 &&
	git -C scratch branch utf16 &&
	git worktree remove --force scratch
'

test_expect_success ICONV,REFLINK 'working-tree-encoding: written normally' '
	test_when_finished "remove_wt wt" &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" \
		git worktree add -q --detach --reflink wt utf16 &&
	test_counts trace.json 13 1 0 0 &&
	test_none_shared . wt utf.txt &&
	test_all_shared . wt plain.txt in/a.txt
'

test_expect_success ICONV 'working-tree-encoding: same as a normal checkout' '
	test_when_finished "remove_wt wt" &&
	git worktree add -q --detach --reflink wt utf16 &&
	# re-encoded on the way out (with or without a BOM, depending on
	# the iconv Git uses), exactly as an ordinary checkout writes it
	! cmp -s utf.txt wt/utf.txt &&
	test_same_as_checkout wt utf16
'

test_expect_success POSIXPERM,REFLINK 'mode comes from the index entry, not the donor' '
	test_when_finished "remove_wt wt" &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" \
		git worktree add -q --detach --reflink wt modes &&
	test_counts trace.json 15 0 0 0 &&
	test_all_shared . wt exe.sh plain.txt &&
	test -x wt/plain.txt &&
	! test -x wt/exe.sh &&
	test_same_as_checkout wt modes
'

test_expect_success POSIXPERM 'executable files keep their mode' '
	test_when_finished "remove_wt wt wt.normal" &&
	git worktree add -q --detach --reflink wt main &&
	test -x wt/exe.sh &&
	! test -x wt/plain.txt &&
	git worktree add -q --detach --no-reflink wt.normal main &&
	test_same_worktree wt.normal wt &&
	# switching to the same blobs with other modes
	git -C wt checkout -q --detach modes &&
	git -C wt.normal checkout -q --detach modes &&
	test -x wt/plain.txt &&
	! test -x wt/exe.sh &&
	test_same_worktree wt.normal wt
'

test_expect_success SYMLINKS 'symlinks are created as symlinks' '
	test_when_finished "remove_wt wt" &&
	git worktree add -q --detach --reflink wt main &&
	test -h wt/link &&
	test_readlink wt/link >actual &&
	echo plain.txt >expect &&
	test_cmp expect actual &&
	test -h wt/dirlink &&
	test_readlink wt/dirlink >actual &&
	echo deep/er >expect &&
	test_cmp expect actual &&
	test_path_is_file wt/dirlink/est/nested.txt
'

# sparse_recipient <dir> --[no-]reflink: a worktree of main with only the
# cone "in" checked out.
sparse_recipient () {
	git worktree add -q --detach $2 --no-checkout "$1" main &&
	git -C "$1" sparse-checkout set --cone in &&
	git -C "$1" reset -q --hard
}

test_expect_success REFLINK 'sparse recipient: files outside the cone are not written' '
	test_when_finished "remove_wt wt wt.normal" &&
	sparse_recipient wt.normal --no-reflink &&
	git worktree add -q --detach --reflink --no-checkout wt main &&
	git -C wt sparse-checkout set --cone in &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" git -C wt reset -q --hard &&
	test_counts trace.json 12 0 0 0 &&
	for f in $OUTSIDE
	do
		test_path_is_missing "wt/$f" || return 1
	done &&
	test_all_shared . wt $INSIDE &&

	# widening the cone clones the newly materialised files
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" \
		git -C wt sparse-checkout disable &&
	test_counts trace.json 3 0 0 0 &&
	test_all_shared . wt $OUTSIDE &&
	git -C wt.normal sparse-checkout disable &&
	test_same_worktree wt.normal wt
'

test_expect_success 'sparse recipient: same as a normal checkout' '
	test_when_finished "remove_wt wt wt.normal" &&
	sparse_recipient wt.normal --no-reflink &&
	sparse_recipient wt --reflink &&
	test_path_is_missing wt/out &&
	test_same_worktree wt.normal wt
'

# sparse_source <dir> [--sparse-index | --no-sparse-index]
sparse_source () {
	git worktree add -q --detach --no-reflink "$1" main &&
	reflink_stable_source "$1" &&
	git -C "$1" sparse-checkout set --cone $2 in
}

test_expect_success REFLINK 'sparse source: paths outside its cone are written normally' '
	test_when_finished "remove_wt src wt" &&
	sparse_source src --no-sparse-index &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" \
		git worktree add -q --detach --reflink-source=src wt main 2>err &&
	test_must_be_empty err &&
	# skip-worktree entries are no donors
	test_counts trace.json 12 3 0 0 &&
	test_all_shared src wt $INSIDE &&
	test_must_fail git -C wt config core.sparseCheckout &&
	test_same_as_checkout wt main
'

test_expect_success REFLINK 'sparse index source is used without expanding it' '
	test_when_finished "remove_wt src wt" &&
	sparse_source src --sparse-index &&
	git -C src config index.sparse >actual &&
	echo true >expect &&
	test_cmp expect actual &&
	git -C src ls-files --sparse >actual &&
	test_grep "^out/\$" actual &&
	cp .git/worktrees/src/index src-index.before &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" \
		git worktree add -q --detach --reflink-source=src wt main 2>err &&
	test_must_be_empty err &&
	# out/ and deep/ are sparse directories, not donors
	test_counts trace.json 12 3 0 0 &&
	test_grep ! ensure_full_index trace.json &&
	test_cmp_bin src-index.before .git/worktrees/src/index &&
	test_all_shared src wt $INSIDE
'

test_expect_success 'sparse source: same as a normal checkout' '
	test_when_finished "remove_wt src wt" &&
	sparse_source src --sparse-index &&
	git worktree add --detach --reflink-source=src wt main 2>err &&
	test_grep ! "^hint:" err &&
	test_grep ! -i "sparse" err &&
	test_same_as_checkout wt main
'

test_expect_success REFLINK 'split index in the source' '
	test_when_finished "remove_wt src wt" &&
	git -c core.splitIndex=true \
		worktree add -q --detach --no-reflink src main &&
	reflink_stable_source src &&
	# Establish the shared base after making all donors non-racy.
	git -C src update-index --split-index &&
	test-tool dump-split-index .git/worktrees/src/index >base-split &&
	# Refresh plain.txt so that its new stat data is only in the split
	# part; the shared index has stale stat data for it
	test-tool chmtime -10 src/plain.txt &&
	git -C src -c core.splitIndex=true -c splitIndex.maxPercentChange=100 \
		update-index --refresh &&
	test-tool dump-split-index .git/worktrees/src/index >split &&
	grep "^base " base-split >expect.base &&
	grep "^base " split >actual.base &&
	test_cmp expect.base actual.base &&
	test_grep "^replacements: [0-9]" split &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" \
		git -c core.splitIndex=false worktree add -q --detach \
			--reflink-source=src wt main &&
	test_counts trace.json 15 0 0 0 &&
	test_all_shared src wt $FILES &&
	test_same_as_checkout wt main
'

test_expect_success REFLINK 'core.splitIndex=true everywhere' '
	test_when_finished "remove_wt src wt" &&
	test_config core.splitIndex true &&
	git worktree add -q --detach --no-reflink src main &&
	reflink_stable_source src &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" \
		git worktree add -q --detach --reflink-source=src wt main &&
	test_counts trace.json 15 0 0 0 &&
	test_all_shared src wt $FILES &&
	test_same_as_checkout wt main
'

test_expect_success REFLINK 'fsmonitor hook in the source: its files are still checked' '
	test_when_finished "remove_wt src wt" &&
	write_script .git/fsmonitor-none <<-\EOF &&
	# claim that nothing ever changes
	printf "last_update_token\0"
	EOF
	git worktree add -q --detach --no-reflink src main &&
	reflink_stable_source src &&
	git -C src -c core.fsmonitor="$(pwd)/.git/fsmonitor-none" \
		-c core.fsmonitorHookVersion=2 status >/dev/null &&
	git -C src -c core.fsmonitor="$(pwd)/.git/fsmonitor-none" \
		-c core.fsmonitorHookVersion=2 status >/dev/null &&
	# change a donor behind the back of fsmonitor
	make_blob_file src/in/a.txt 64 other &&
	test-tool chmtime +20 src/in/a.txt &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" \
		git worktree add -q --detach --reflink-source=src wt main &&
	test_counts trace.json 14 0 1 0 &&
	test_none_shared src wt in/a.txt &&
	test_cmp in/a.txt wt/in/a.txt &&
	test_same_as_checkout wt main
'

test_expect_success FSMONITOR_DAEMON,REFLINK 'fsmonitor daemon in the source' '
	test_when_finished "
		git -C src fsmonitor--daemon stop
		remove_wt src wt
	" &&
	git worktree add -q --detach --no-reflink src main &&
	reflink_stable_source src &&
	git -C src -c core.fsmonitor=true fsmonitor--daemon start &&
	git -C src -c core.fsmonitor=true status >/dev/null &&
	test-tool chmtime +10 src/plain.txt &&
	git -C src -c core.fsmonitor=true status >/dev/null &&
	git -C src -c core.fsmonitor=true status >/dev/null &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" \
		git worktree add -q --detach --reflink-source=src wt main &&
	test_counts trace.json 15 0 0 0 &&
	test_all_shared src wt $FILES &&
	test_same_as_checkout wt main
'

test_expect_success 'setup submodule' '
	test_config_global protocol.file.allow always &&
	git init -q subrepo &&
	make_blob_file subrepo/sub.txt 64 &&
	mkdir subrepo/dir &&
	make_blob_file subrepo/dir/deep.txt 64 &&
	git -C subrepo add . &&
	git -C subrepo commit -q -m sub &&
	git init -q super &&
	make_blob_file super/super.txt 64 &&
	git -C super add super.txt &&
	git -C super submodule add -q ../subrepo sub &&
	git -C super commit -q -m super &&
	reflink_stable_source super
'

test_expect_success 'submodules: update --init in a reflinked worktree' '
	test_when_finished "rm -rf superwt superwt.normal && git -C super worktree prune" &&
	test_config_global protocol.file.allow always &&
	rm -f trace.json &&
	GIT_TRACE2_EVENT="$TRACE_JSON" \
		git -C super worktree add -q --detach --reflink ../superwt &&
	git -C superwt submodule update -q --init &&
	git -C super worktree add -q --detach --no-reflink ../superwt.normal &&
	git -C superwt.normal submodule update -q --init &&
	if test_have_prereq REFLINK
	then
		test_reflink_count cloned 2 trace.json &&
		test_shared super/super.txt superwt/super.txt
	fi &&
	test_path_is_file superwt/sub/dir/deep.txt &&
	test_cmp subrepo/sub.txt superwt/sub/sub.txt &&
	describe_tree superwt.normal >expect.raw &&
	describe_tree superwt >actual.raw &&
	# the gitfile of the submodule names a per-worktree directory
	grep -v "^file ./sub/.git " expect.raw >expect &&
	grep -v "^file ./sub/.git " actual.raw >actual &&
	test_cmp expect actual &&
	describe_tree superwt.normal/sub >expect &&
	describe_tree superwt/sub >actual &&
	test_cmp expect actual &&
	git -C superwt status --porcelain=v1 --untracked-files=all >actual &&
	test_must_be_empty actual &&
	git -C superwt/sub status --porcelain=v1 --untracked-files=all >actual &&
	test_must_be_empty actual &&
	git -C superwt ls-files -s >actual &&
	git -C superwt.normal ls-files -s >expect &&
	test_cmp expect actual
'

test_expect_success 'submodules: reflink test mode in the submodule checkout' '
	test_when_finished "rm -rf superwt && git -C super worktree prune" &&
	test_config_global protocol.file.allow always &&
	git -C super worktree add -q --detach --reflink ../superwt &&
	GIT_TEST_REFLINK_CHECKOUT=1 git -C superwt submodule update -q --init &&
	test_cmp subrepo/sub.txt superwt/sub/sub.txt &&
	test_cmp subrepo/dir/deep.txt superwt/sub/dir/deep.txt &&
	git -C superwt status --porcelain=v1 --untracked-files=all >actual &&
	test_must_be_empty actual &&
	git -C superwt/sub status --porcelain=v1 --untracked-files=all >actual &&
	test_must_be_empty actual
'

test_expect_success CASE_INSENSITIVE_FS 'case-only rename behaves as a normal checkout' '
	test_when_finished "remove_wt wt wt.normal" &&
	git worktree add -q --detach --reflink wt main &&
	git worktree add -q --detach --no-reflink wt.normal main &&
	git -C wt checkout -q --detach case-rename &&
	git -C wt.normal checkout -q --detach case-rename &&
	test_same_worktree wt.normal wt &&
	git -C wt checkout -q --detach main &&
	git -C wt.normal checkout -q --detach main &&
	test_same_worktree wt.normal wt
'

test_expect_success CASE_INSENSITIVE_FS 'case-only rename in a new worktree' '
	test_when_finished "remove_wt wt" &&
	git worktree add -q --detach --reflink wt case-rename &&
	test_same_as_checkout wt case-rename
'

test_expect_success CASE_INSENSITIVE_FS 'colliding paths behave as a normal checkout' '
	test_when_finished "remove_wt wt wt.normal" &&
	git worktree add --detach --no-reflink wt.normal case-collide 2>expect.err &&
	git worktree add --detach --reflink wt case-collide 2>actual.err &&
	sed -e "s/wt.normal/wt/g" expect.err >expect &&
	test_cmp expect actual.err &&
	# Both names alias one file. Force content checks so timestamp precision
	# cannot hide the losing index entry in just one of these checkouts.
	test-tool chmtime -60 wt.normal/in/a.txt wt/in/a.txt &&
	test_same_worktree wt.normal wt
'

test_done
