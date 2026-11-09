#define USE_THE_REPOSITORY_VARIABLE

#include "unit-test.h"
#include "environment.h"
#include "object.h"
#include "read-cache-ll.h"
#include "repository.h"

static struct repo_config_values saved_config;
static struct index_state index_state;
static struct cache_entry entry;

void test_read_cache__initialize(void)
{
	struct repo_config_values *cfg = repo_config_values(the_repository);

	saved_config = *cfg;
	cfg->trust_ctime = 1;
	cfg->check_stat = 1;
	cfg->use_nanosec = 0;
	memset(&index_state, 0, sizeof(index_state));
	index_state.repo = the_repository;
	index_state.timestamp.sec = 100;
	index_state.timestamp.nsec = 200;
	memset(&entry, 0, sizeof(entry));
	entry.ce_mode = S_IFREG | 0644;
	entry.ce_stat_data.sd_mtime.sec = 90;
	entry.ce_stat_data.sd_ctime.sec = 100;
	entry.ce_stat_data.sd_ctime.nsec = 100;
}

void test_read_cache__cleanup(void)
{
	*repo_config_values(the_repository) = saved_config;
}

void test_read_cache__racy_ctime(void)
{
	cl_assert(is_racy_timestamp(&index_state, &entry));
	entry.ce_stat_data.sd_ctime.sec++;
	cl_assert(is_racy_timestamp(&index_state, &entry));
	entry.ce_stat_data.sd_ctime.sec = 99;
	cl_assert(!is_racy_timestamp(&index_state, &entry));
}

void test_read_cache__racy_ctime_nanoseconds(void)
{
	repo_config_values(the_repository)->use_nanosec = 1;
	cl_assert(!is_racy_timestamp(&index_state, &entry));
	entry.ce_stat_data.sd_ctime.nsec = 200;
	cl_assert(is_racy_timestamp(&index_state, &entry));
	entry.ce_stat_data.sd_ctime.nsec++;
	cl_assert(is_racy_timestamp(&index_state, &entry));
}

void test_read_cache__ignored_ctime(void)
{
	repo_config_values(the_repository)->trust_ctime = 0;
	cl_assert(!is_racy_timestamp(&index_state, &entry));
	repo_config_values(the_repository)->trust_ctime = 1;
	repo_config_values(the_repository)->check_stat = 0;
	cl_assert(!is_racy_timestamp(&index_state, &entry));
}

void test_read_cache__racy_mtime_without_ctime(void)
{
	repo_config_values(the_repository)->trust_ctime = 0;
	entry.ce_stat_data.sd_mtime.sec = 100;
	cl_assert(is_racy_timestamp(&index_state, &entry));
	repo_config_values(the_repository)->check_stat = 0;
	cl_assert(is_racy_timestamp(&index_state, &entry));
}

void test_read_cache__no_index_timestamp(void)
{
	index_state.timestamp.sec = 0;
	cl_assert(!is_racy_timestamp(&index_state, &entry));
}

void test_read_cache__gitlink(void)
{
	entry.ce_mode = S_IFGITLINK;
	cl_assert(!is_racy_timestamp(&index_state, &entry));
}
