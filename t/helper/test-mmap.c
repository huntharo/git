#include "test-tool.h"
#include "statinfo.h"

#ifdef HAVE_STAT_GEN_COUNT
#include <sys/mman.h>

int cmd__mmap(int argc, const char **argv)
{
	struct stat before, after;
	char command[32];
	char *mapping;
	int fd, prot = PROT_READ, flags = MAP_SHARED;
	int writable;

	if (argc != 3)
		usage("test-tool mmap <shared|private|readonly|upgrade|unreliable|identity> <file>");
	if (!strcmp(argv[1], "unreliable")) {
		int unreliable;
		errno = ERANGE;
		unreliable = has_unreliable_stat_data(argv[2], NULL);
		if (errno != ERANGE)
			die("generation query changed errno");
		printf("%d\n", unreliable);
		return 0;
	}
	if (lstat(argv[2], &before))
		die_errno("lstat");
	if (!strcmp(argv[1], "identity")) {
		before.st_ino ^= 1;
		printf("%d\n", has_unreliable_stat_data(argv[2], &before));
		return 0;
	}
	writable = strcmp(argv[1], "readonly") != 0;
	if (!strcmp(argv[1], "private"))
		flags = MAP_PRIVATE;
	else if (strcmp(argv[1], "shared") && strcmp(argv[1], "readonly") &&
		 strcmp(argv[1], "upgrade"))
		die("unknown mapping mode: %s", argv[1]);
	if (writable && strcmp(argv[1], "upgrade"))
		prot |= PROT_WRITE;
	fd = xopen(argv[2], writable ? O_RDWR : O_RDONLY);
	mapping = mmap(NULL, before.st_size, prot, flags, fd, 0);
	if (mapping == MAP_FAILED)
		die_errno("mmap");
	if (close(fd))
		die_errno("close");
	setvbuf(stdout, NULL, _IOLBF, 0);
	puts("ready");
	while (fgets(command, sizeof(command), stdin)) {
		if (!strncmp(command, "write ", 6)) {
			if (!(prot & PROT_WRITE))
				die("mapping is read-only");
			mapping[0] = command[6];
			puts("written");
		} else if (!strcmp(command, "protect\n")) {
			prot |= PROT_WRITE;
			if (mprotect(mapping, before.st_size, prot))
				die_errno("mprotect");
			puts("writable");
		} else if (!strcmp(command, "stat\n")) {
			if (lstat(argv[2], &after))
				die_errno("lstat");
			puts(before.st_mtime == after.st_mtime &&
			     before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec &&
			     before.st_ctime == after.st_ctime &&
			     before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec &&
			     before.st_size == after.st_size ? "unchanged" : "changed");
		} else if (!strcmp(command, "sync\n")) {
			if (msync(mapping, before.st_size, MS_SYNC))
				die_errno("msync");
			puts("synced");
		} else if (!strcmp(command, "quit\n")) {
			break;
		} else {
			die("unknown mapping command");
		}
	}
	if (munmap(mapping, before.st_size))
		die_errno("munmap");
	return 0;
}
#else
int cmd__mmap(int argc UNUSED, const char **argv UNUSED)
{
	die("mmap stat generation tests are not supported on this platform");
}
#endif
