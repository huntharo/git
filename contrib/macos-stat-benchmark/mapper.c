/* Dev-only native closed-FD mapping helper; no Git internal API. */
#include <sys/attr.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void fail(const char *what)
{
	perror(what);
	exit(1);
}

static unsigned generation(const char *path)
{
	struct attrlist attrs = { 0 };
	struct {
		uint32_t length;
		attribute_set_t returned;
		uint32_t gen;
	} result = { 0 };

	attrs.bitmapcount = ATTR_BIT_MAP_COUNT;
	attrs.commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_GEN_COUNT;
	if (getattrlist(path, &attrs, &result, sizeof(result),
			FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW) ||
	    result.length != sizeof(result) ||
	    !(result.returned.commonattr & ATTR_CMN_GEN_COUNT)) {
		fprintf(stderr, "generation unavailable for %s\n", path);
		exit(1);
	}
	return result.gen;
}

int main(int argc, char **argv)
{
	char **maps, command[32];
	size_t *sizes;
	int i, n = argc - 2;

	if (argc < 3 || (strcmp(argv[1], "query") && strcmp(argv[1], "map")))
		return 2;
	setvbuf(stdout, NULL, _IOLBF, 0);
	if (!strcmp(argv[1], "query")) {
		for (i = 2; i < argc; i++)
			printf("%u\n", generation(argv[i]));
		return 0;
	}
	maps = calloc(n, sizeof(*maps));
	sizes = calloc(n, sizeof(*sizes));
	if (!maps || !sizes)
		fail("calloc");
	for (i = 0; i < n; i++) {
		struct stat st;
		int fd = open(argv[i + 2], O_RDWR);

		if (fd < 0 || fstat(fd, &st))
			fail("open/fstat");
		sizes[i] = st.st_size;
		maps[i] = mmap(NULL, sizes[i], PROT_READ | PROT_WRITE,
			       MAP_SHARED, fd, 0);
		if (maps[i] == MAP_FAILED)
			fail("mmap");
		if (close(fd))
			fail("close");
		if (generation(argv[i + 2])) {
			fprintf(stderr, "mapping generation is still valid\n");
			return 1;
		}
	}
	puts("ready: descriptors closed; generation zero");
	while (fgets(command, sizeof(command), stdin)) {
		if (!strncmp(command, "write ", 6)) {
			for (i = 0; i < n; i++)
				maps[i][0] = command[6];
			puts("written: quiescent");
		} else if (!strcmp(command, "quit\n")) {
			break;
		} else {
			return 2;
		}
	}
	for (i = 0; i < n; i++)
		if (munmap(maps[i], sizes[i]))
			fail("munmap");
	free(maps);
	free(sizes);
	return 0;
}
