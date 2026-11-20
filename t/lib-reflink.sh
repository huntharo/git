# Helpers for testing reflink checkout (see
# Documentation/technical/reflink-checkout.adoc).

# These tests control reflink checkout themselves.
sane_unset GIT_TEST_REFLINK_CHECKOUT GIT_TEST_REFLINK_TAMPER
# ... and the number of checkout workers.
sane_unset GIT_TEST_CHECKOUT_WORKERS

# Where tests have trace2 write events. Set once: under "-x" with shells
# that trace to stderr, a "$(pwd)" on a command whose stderr a test
# captures would add its trace line to what the test compares.
TRACE_JSON="$(pwd)/trace.json"

# The native clone backend is compiled in, independently of whether the
# filesystem of the trash directory can clone.
test_lazy_prereq REFLINK_BUILD '
	test-tool reflink supported
'

# The filesystem of the trash directory can clone files.
test_lazy_prereq REFLINK '
	test-tool reflink probe .
'

# Sharing tests need non-racy donors. Give real files an old mtime, then
# let Git validate their contents and record their actual stat data. Tests
# for dirty and racy donors deliberately run after this preparation.
# Symlinks must also be non-racy: update-index can otherwise rewrite a
# split index as a full index even though every regular donor is old.
reflink_stable_source () {
	(
		cd "${1:-.}" &&
		git ls-files -s >.git-reflink-paths &&
		while read mode oid stage path
		do
			case "$mode" in
			100*)
				if test -f "$path" && ! test -h "$path"
				then
					test-tool chmtime =-60 "$path" || exit 1
				fi
				;;
			120000)
				if test_have_prereq REFLINK_BUILD
				then
					test-tool reflink age "$path" || exit 1
				fi
				;;
			esac
		done <.git-reflink-paths &&
		rm .git-reflink-paths &&
		git update-index --refresh
	)
}

# test_shared <a> <b>: <a> and <b> share data blocks.
test_shared () {
	test-tool reflink shared "$1" "$2" ||
	{
		echo >&2 "'$1' and '$2' do not share data blocks"
		return 1
	}
}

# test_not_shared <a> <b>: <a> and <b> do not share data blocks. Where
# files cannot be cloned, no two files share blocks.
test_not_shared () {
	if ! test_have_prereq REFLINK
	then
		return 0
	fi &&
	test_expect_code 1 test-tool reflink shared "$1" "$2" ||
	{
		echo >&2 "'$1' and '$2' share data blocks (or cannot tell)"
		return 1
	}
}

# reflink_count <name> <trace2-event-file>: sum of the "reflink" trace2
# counter <name> over all processes (checkout workers included) in the
# trace. Counters that never fired count as 0.
reflink_count () {
	sed -n -e 's/.*"category":"reflink","name":"'"$1"'","count":\([0-9]*\).*/\1/p' "$2" |
	awk '{ s += $1 } END { print s + 0 }'
}

# test_reflink_count <key> <expect> <trace2-event-file>
test_reflink_count () {
	echo "$2" >expect.count &&
	reflink_count "$1" "$3" >actual.count &&
	test_cmp expect.count actual.count
}

# describe_tree <dir>: one line per entry below <dir> (except .git) with
# its type, executable bit, size and content hash, for comparing a
# reflinked checkout with an ordinary one.
describe_tree () {
	(
		cd "$1" &&
		find . -path ./.git -prune -o -print >"$TRASH_DIRECTORY/.git/describe-tree.tmp" &&
		test_env LC_ALL=C sort "$TRASH_DIRECTORY/.git/describe-tree.tmp" |
		while read path
		do
			if test -h "$path"
			then
				echo "link $path $(test_readlink "$path")"
			elif test -d "$path"
			then
				echo "dir $path"
			else
				x=- &&
				if test -x "$path"
				then
					x=x
				fi &&
				size=$(wc -c <"$path") &&
				oid=$(git hash-object --no-filters "$path") &&
				echo "file $path $x $((size)) $oid"
			fi || return 1
		done
	)
}

# test_same_as_checkout <dir> <commit-ish>: the worktree <dir> has
# exactly the files, bytes, modes and index an ordinary
# "git worktree add" of <commit-ish> produces, and is clean.
test_same_as_checkout () {
	# clear one a failed earlier check left behind (no
	# test_when_finished: some callers run this in a subshell)
	if test -d "$1.expect"
	then
		git worktree remove --force "$1.expect"
	fi &&
	git worktree add -q --detach --no-reflink "$1.expect" "$2" &&
	describe_tree "$1.expect" >expect.tree &&
	describe_tree "$1" >actual.tree &&
	test_cmp expect.tree actual.tree &&
	git -C "$1.expect" ls-files -s >expect.index &&
	git -C "$1" ls-files -s >actual.index &&
	test_cmp expect.index actual.index &&
	git -C "$1" status --porcelain=v1 --untracked-files=all >actual.status &&
	test_must_be_empty actual.status &&
	git -C "$1" diff-files --exit-code &&
	git worktree remove --force "$1.expect"
}

# make_blob_file <path> <kib> [<seed>]: write <kib> KiB of text (hex
# digits, 16 bytes to a line) to <path>. Big enough that every
# filesystem stores it in its own blocks.
make_blob_file () {
	test-tool genrandom "${3:-$1}" $(($2 * 1024)) |
	perl -e 'binmode STDIN; $/ = \16; print join(" ", unpack("(H2)*", $_)), "\n" while <STDIN>' |
	test_copy_bytes $(($2 * 1024)) >"$1"
}

# test_has_crlf <file>: <file> has a CRLF line ending.
test_has_crlf () {
	perl -ne '$crlf = 1 if /\r\n/; END { exit !$crlf }' "$1" ||
	{
		echo >&2 "'$1' has no CRLF line ending"
		return 1
	}
}
