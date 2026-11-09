/* Diagnostic-only dyld interposer. Never loaded in timed samples. */
#include <sys/attr.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <errno.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static uint64_t queries, reads, mmaps, preads;

static int fixture_path(const char *path)
{
	const char *prefix = getenv("BENCH_COUNT_PREFIX");

	return prefix && path &&
		(!strncmp(path, prefix, strlen(prefix)) ||
		 !strncmp(path, "files/", 6));
}

static int fixture_fd(int fd)
{
	char path[PATH_MAX];

	return fcntl(fd, F_GETPATH, path) == 0 && fixture_path(path);
}

static int count_getattrlist(const char *path, struct attrlist *attrs,
			    void *buf, size_t size, unsigned long options)
{
	int result = getattrlist(path, attrs, buf, size, options);
	int saved_errno = errno;

	if (fixture_path(path))
		__sync_fetch_and_add(&queries, 1);
	errno = saved_errno;
	return result;
}

static ssize_t count_read(int fd, void *buf, size_t size)
{
	ssize_t result = read(fd, buf, size);
	int saved_errno = errno;

	if (result > 0 && fixture_fd(fd))
		__sync_fetch_and_add(&reads, result);
	errno = saved_errno;
	return result;
}

static ssize_t count_pread(int fd, void *buf, size_t size, off_t offset)
{
	ssize_t result = pread(fd, buf, size, offset);
	int saved_errno = errno;

	if (result > 0 && fixture_fd(fd))
		__sync_fetch_and_add(&preads, result);
	errno = saved_errno;
	return result;
}

static void *count_mmap(void *addr, size_t size, int prot, int flags,
			int fd, off_t offset)
{
	void *result = mmap(addr, size, prot, flags, fd, offset);
	int saved_errno = errno;

	if (result != MAP_FAILED && fixture_fd(fd))
		__sync_fetch_and_add(&mmaps, size);
	errno = saved_errno;
	return result;
}

#define INTERPOSE(replacement, original) \
	__attribute__((used)) static struct { \
		const void *replacement_ptr, *original_ptr; \
	} interpose_##original __attribute__((section("__DATA,__interpose"))) = \
		{ (const void *)(uintptr_t)&replacement, \
		  (const void *)(uintptr_t)&original }

INTERPOSE(count_getattrlist, getattrlist);
INTERPOSE(count_read, read);
INTERPOSE(count_pread, pread);
INTERPOSE(count_mmap, mmap);

__attribute__((destructor)) static void report(void)
{
	const char *output = getenv("BENCH_COUNT_OUTPUT");
	FILE *file;

	if (!output || !(file = fopen(output, "a")))
		return;
	fprintf(file, "{\"pid\":%d,\"getattrlist_calls\":%llu,"
		"\"read_bytes\":%llu,\"pread_bytes\":%llu,"
		"\"mmap_requested_bytes\":%llu}\n", getpid(),
		(unsigned long long)queries, (unsigned long long)reads,
		(unsigned long long)preads, (unsigned long long)mmaps);
	fclose(file);
}
