/* Test-only Darwin interposer. Never linked into Git. */
#include <sys/attr.h>
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned cheap, private_reads, modes, attributes, timestamps;

static int inspect_mode(int fd, mode_t mode)
{
	modes++;
	return fchmod(fd, mode);
}

static int inspect_attributes(int fd, struct attrlist *al, void *buffer,
			      size_t size, unsigned long options)
{
	attributes++;
	return fsetattrlist(fd, al, buffer, size, options);
}

static int inspect_times(int fd, const struct timespec times[2])
{
	timestamps++;
	return futimens(fd, times);
}

static int inspect(int fd, struct attrlist *al, void *buffer, size_t size,
		   unsigned long options)
{
	const char *fault = getenv("APFS_TEST_FAULT");
	int ret = fgetattrlist(fd, al, buffer, size, options);
	uint32_t *words = buffer;

	if (al->forkattr & ATTR_CMNEXT_PRIVATESIZE) {
		private_reads++;
		return ret;
	}
	if (!(al->forkattr & ATTR_CMNEXT_CLONE_REFCNT))
		return ret;
	cheap++;
	if (ret || !fault)
		return ret;
	if (!strcmp(fault, "unsupported")) {
		errno = ENOTSUP;
		return -1;
	}
	/* Fixed slots in the requested, PACK_INVAL_ATTRS reply. */
	if (!strncmp(fault, "missing:", 8)) {
		unsigned bit = atoi(fault + 8);
		if (bit < 160)
			words[1 + bit / 32] &= ~(1U << (bit % 32));
	} else if (!strncmp(fault, "length:", 7)) {
		words[0] = atoi(fault + 7);
	} else if (!strcmp(fault, "device")) {
		words[6] ^= 1;
	} else if (!strcmp(fault, "inode")) {
		words[7] ^= 1;
	} else if (!strcmp(fault, "allocation")) {
		memset((char *)buffer + 36, 0xff, 8);
	} else if (!strcmp(fault, "volume")) {
		words[11] = 0;
	} else if (!strcmp(fault, "clone")) {
		memset((char *)buffer + 48, 0, 8);
	} else if (!strcmp(fault, "flags")) {
		memset((char *)buffer + 56, 0, 8);
	} else if (!strcmp(fault, "references")) {
		words[16] = 1;
	}
	return ret;
}

__attribute__((destructor)) static void report(void)
{
	fprintf(stderr, "apfs-queries %u %u\n", cheap, private_reads);
	fprintf(stderr, "apfs-repairs %u %u %u\n", modes, attributes, timestamps);
}

__attribute__((used)) static struct {
	const void *replacement, *original;
} interpose[] __attribute__((section("__DATA,__interpose"))) = {
	{ (const void *)inspect, (const void *)fgetattrlist },
	{ (const void *)inspect_mode, (const void *)fchmod },
	{ (const void *)inspect_attributes, (const void *)fsetattrlist },
	{ (const void *)inspect_times, (const void *)futimens }
};
