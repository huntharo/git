#!/bin/sh

test_description='merge-base on deterministic random DAGs'

. ./test-lib.sh

# Each mode must use exactly the graph requested below, even when the
# suite is run with automatic commit-graph writes enabled.
GIT_TEST_COMMIT_GRAPH=0
export GIT_TEST_COMMIT_GRAPH

test_expect_success PERL 'generate small DAGs with tied and skewed dates' '
	"$PERL_PATH" "$TEST_DIRECTORY/t6602/merge-base.pl" generate >input &&
	git fast-import --export-marks=marks <input &&
	git config core.commitGraph true
'

test_expect_success PERL 'merge-base agrees with oracle without commit-graph' '
	test_path_is_missing .git/objects/info/commit-graph &&
	"$PERL_PATH" "$TEST_DIRECTORY/t6602/merge-base.pl" check marks none
'

for version in 2 1
do
	test_expect_success PERL "merge-base agrees with oracle with generation v$version" '
		rm -f .git/objects/info/commit-graph &&
		git -c commitGraph.generationVersion=$version \
			commit-graph write --reachable &&
		test_path_is_file .git/objects/info/commit-graph &&
		git commit-graph verify &&
		"$PERL_PATH" "$TEST_DIRECTORY/t6602/merge-base.pl" \
			check marks v$version
	'
done

test_done
