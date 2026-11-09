/* Standalone API cost only: no integrated Git implementation is implied. */
#define main native_proof_main
#include "native-proof/combined-metadata.c"
#undef main
#include <time.h>

static uint64_t now_ns(void)
{
	struct timespec t;

	if (clock_gettime(CLOCK_MONOTONIC_RAW, &t))
		fail("clock_gettime");
	return (uint64_t)t.tv_sec * 1000000000 + t.tv_nsec;
}

static void batch(const char *path, int operation, int count)
{
	struct attrlist attrs = { 0 };
	int i;

	attrs.bitmapcount = ATTR_BIT_MAP_COUNT;
	attrs.commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_DEVID |
		ATTR_CMN_GEN_COUNT | ATTR_CMN_FILEID;
	if (operation == 2) {
		attrs.commonattr |= ATTR_CMN_OBJTYPE | ATTR_CMN_MODTIME |
			ATTR_CMN_CHGTIME | ATTR_CMN_OWNERID | ATTR_CMN_GRPID |
			ATTR_CMN_ACCESSMASK;
		attrs.fileattr = ATTR_FILE_DATALENGTH;
	}
	for (i = 0; i < count; i++) {
		struct stat st;
		struct metadata combined;
		struct {
			uint32_t length;
			attribute_set_t returned;
			uint32_t device, generation;
			uint64_t inode;
		} split;

		if (operation != 2 && lstat(path, &st))
			fail("lstat");
		if (operation == 1 && getattrlist(path, &attrs, &split,
				sizeof(split), FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW))
			fail("split getattrlist");
		if (operation == 2 && getattrlist(path, &attrs, &combined,
				sizeof(combined), FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW))
			fail("combined getattrlist");
	}
}

int main(int argc, char **argv)
{
	const char *operations[] = { "lstat", "lstat+generation", "combined" };
	const char *states[] = { "unmapped", "shared-fd-closed", "shared-modified" };
	char data[16384], *mapping = NULL;
	struct stat before, after;
	int fd, state, round, position, iterations = 10000;

	if (argc != 2)
		return 2;
	memset(data, 'A', sizeof(data));
	fd = open(argv[1], O_CREAT | O_EXCL | O_RDWR, 0600);
	if (fd < 0 || write(fd, data, sizeof(data)) != sizeof(data) ||
	    fsync(fd) || fstat(fd, &before))
		fail("fixture");
	for (state = 0; state < 3; state++) {
		if (state == 1) {
			mapping = mmap(NULL, sizeof(data), PROT_READ | PROT_WRITE,
				       MAP_SHARED, fd, 0);
			if (mapping == MAP_FAILED || close(fd))
				fail("map/close");
		}
		if (state == 2)
			mapping[0] = 'B';
		snapshot(argv[1], states[state], "microbenchmark-validation");
		for (round = -1; round < 9; round++) {
			for (position = 0; position < 3; position++) {
				int op = (position + round + 3) % 3;
				uint64_t begin = now_ns(), elapsed;

				batch(argv[1], op, iterations);
				elapsed = now_ns() - begin;
				printf("{\"state\":\"%s\",\"operation\":\"%s\","
				       "\"round\":%d,\"iterations\":%d,\"ns_per_iteration\":%.3f}\n",
				       states[state], operations[op], round, iterations,
				       (double)elapsed / iterations);
			}
		}
		if (lstat(argv[1], &after))
			fail("lstat after");
		if (before.st_mtimespec.tv_sec != after.st_mtimespec.tv_sec ||
		    before.st_mtimespec.tv_nsec != after.st_mtimespec.tv_nsec ||
		    before.st_ctimespec.tv_sec != after.st_ctimespec.tv_sec ||
		    before.st_ctimespec.tv_nsec != after.st_ctimespec.tv_nsec) {
			fprintf(stderr, "timestamps changed\n");
			return 1;
		}
	}
	if (munmap(mapping, sizeof(data)) || unlink(argv[1]))
		fail("cleanup");
	return 0;
}
