#define USE_THE_REPOSITORY_VARIABLE

#include "test-tool.h"
#include "config.h"
#include "environment.h"
#include "read-cache-ll.h"
#include "repository.h"
#include "setup.h"

static int match_racy_ctime(const char *name)
{
	struct index_state *istate = the_repository->index;
	struct cache_entry *ce;
	struct stat st;
	int pos = index_name_pos(istate, name, strlen(name));

	if (pos < 0)
		die("%s not in index", name);
	if (lstat(name, &st))
		die_errno("lstat %s", name);
	ce = istate->cache[pos];
	/*
	 * Construct the stat match left by a same-second mapped write,
	 * independently of how long the test commands take to execute.
	 * Keep the indexed object ID, but make stat data match the file.
	 * Only ctime is as recent as the index timestamp.
	 */
	fill_stat_data(&ce->ce_stat_data, &st);
	istate->timestamp = ce->ce_stat_data.sd_ctime;
	if (ce->ce_stat_data.sd_mtime.sec >= istate->timestamp.sec)
		die("expected mtime older than ctime");
	printf("%d\n", ie_match_stat(istate, ce, &st, 0));
	return 0;
}

int cmd__read_cache(int argc, const char **argv)
{
	int i, cnt = 1;
	const char *name = NULL;
	const char *racy_name = NULL;

	if (argc == 2)
		skip_prefix(argv[1], "--racy-ctime=", &racy_name);

	if (argc > 1 && skip_prefix(argv[1], "--print-and-refresh=", &name)) {
		argc--;
		argv++;
	}

	if (argc == 2)
		cnt = strtol(argv[1], NULL, 0);
	setup_git_directory(the_repository);
	repo_config(the_repository, git_default_config, NULL);
	if (racy_name) {
		repo_read_index(the_repository);
		return match_racy_ctime(racy_name);
	}

	for (i = 0; i < cnt; i++) {
		repo_read_index(the_repository);
		if (name) {
			int pos;

			refresh_index(the_repository->index, REFRESH_QUIET,
				      NULL, NULL, NULL);
			pos = index_name_pos(the_repository->index, name, strlen(name));
			if (pos < 0)
				die("%s not in index", name);
			printf("%s is%s up to date\n", name,
			       ce_uptodate(the_repository->index->cache[pos]) ? "" : " not");
			write_file(name, "%d\n", i);
		}
		discard_index(the_repository->index);
	}
	return 0;
}
