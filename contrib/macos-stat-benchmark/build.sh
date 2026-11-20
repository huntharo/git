#!/bin/sh
# Run only in an isolated checkout; switches commits in THIS worktree.
set -eu
bench_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(git rev-parse --show-toplevel)
test "$bench_dir" = "$repo_dir/contrib/macos-stat-benchmark"
cd "$repo_dir"
test -z "$(git status --porcelain --untracked-files=no)"
test ! -e config.mak
test ! -e config.mak.autogen
original_branch=$(git symbolic-ref --quiet --short HEAD || :)
original_sha=$(git rev-parse HEAD)
always_sha=4be2dcea27b9af28b4a8d9ceb14b412ad0e7fad5
# The harness is absent on baseline and PR14: retain the recorder locally.
mkdir -p "$bench_dir/local"
cp "$bench_dir/record-build.py" "$bench_dir/local/record-build.py"
restore_checkout () {
	git switch --detach "$original_sha"
	if test -n "$original_branch"
	then
		git switch "$original_branch"
	fi
}
trap restore_checkout EXIT HUP INT TERM
for variant in baseline selective always
do
	case "$variant" in
	baseline) revision=fb255012acbcbe81189cb8014da0280b09c66ecc ;;
	selective) revision=8e6340c0b705182db2840f99343f327373034411 ;;
	always) revision=$always_sha ;;
	esac
	git switch --detach "$revision"
	make NO_GETTEXT=YesPlease clean >"$bench_dir/local/clean-$variant.log" 2>&1
	make -j8 NO_GETTEXT=YesPlease CFLAGS='-O2 -g' git >"$bench_dir/local/build-$variant.log" 2>&1
	BENCH_HARNESS_ROOT="$bench_dir" python3 "$bench_dir/local/record-build.py" "$variant"
done
