#include "git-compat-util.h"
#include "statinfo.h"

int has_unreliable_stat_data(const char *path UNUSED,
			     const struct stat *st UNUSED)
{
	/* Benchmark-only comparator: always take the content comparison path. */
	return 1;
}
