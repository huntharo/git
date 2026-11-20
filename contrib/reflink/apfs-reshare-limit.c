/*
 * Standalone APFS file-replacement limitation evidence. Run in a fresh scratch
 * directory only: cc apfs-reshare-limit.c -o probe; ./probe <scratch-dir>
 * This deliberately demonstrates the accepted writable-mapping/retained-fd
 * limitation, independently of the command's detected ordinary-write tests.
 */
#include <sys/clonefile.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <copyfile.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>
#include <stdbool.h>
#include <string.h>
#include <stdlib.h>

int main(int argc, char **argv)
{
	int a, b, temp, published, rc;
	bool cloned = false;
	char bytes[65536], expected[65536], actual[65536], old[2], now[2];
	char *map;
	struct stat before, after;
	copyfile_state_t state;

	if (argc != 2 || chdir(argv[1]))
		return 2;
	a = open("source", O_RDWR | O_CREAT | O_EXCL, 0600);
	b = open("target", O_RDWR | O_CREAT | O_EXCL, 0600);
	memset(bytes, 'A', sizeof(bytes));
	if (a < 0 || b < 0 || write(a, bytes, sizeof(bytes)) != sizeof(bytes) ||
	    write(b, bytes, sizeof(bytes)) != sizeof(bytes) || fsync(a) || fsync(b))
		return 3;
	errno = 0;
	rc = fclonefileat(a, AT_FDCWD, "target", 0);
	printf("fclonefileat_existing rc=%d errno=%d\n", rc, errno);
	state = copyfile_state_alloc();
	errno = 0;
	rc = fcopyfile(a, b, state, COPYFILE_CLONE_FORCE);
	printf("fcopyfile_clone_force rc=%d errno=%d", rc, errno);
	copyfile_state_get(state, COPYFILE_STATE_WAS_CLONED, &cloned);
	printf(" cloned=%d\n", cloned);
	copyfile_state_free(state);
	if (fclonefileat(a, AT_FDCWD, "temporary", 0))
		return 4;
	temp = open("temporary", O_RDONLY);
	map = mmap(NULL, sizeof(bytes), PROT_READ | PROT_WRITE, MAP_SHARED, b, 0);
	if (temp < 0 || map == MAP_FAILED)
		return 5;
	/* Dirty the page first: a later mapped write can leave stat unchanged. */
	map[0] = 'A';
	fstat(b, &before);
	if (pread(temp, expected, sizeof(expected), 0) != sizeof(expected) ||
	    pread(b, actual, sizeof(actual), 0) != sizeof(actual) ||
	    memcmp(expected, actual, sizeof(actual)))
		return 6;
	map[0] = 'B';
	fstat(b, &after);
	printf("write_before_rename_target_changed=%d\n",
	       before.st_mtimespec.tv_sec != after.st_mtimespec.tv_sec ||
	       before.st_mtimespec.tv_nsec != after.st_mtimespec.tv_nsec ||
	       before.st_ctimespec.tv_sec != after.st_ctimespec.tv_sec ||
	       before.st_ctimespec.tv_nsec != after.st_ctimespec.tv_nsec);
	if (rename("temporary", "target"))
		return 7;
	map[1] = 'C';
	msync(map, sizeof(bytes), MS_SYNC);
	published = open("target", O_RDONLY);
	pread(b, old, 2, 0);
	pread(published, now, 2, 0);
	fstat(published, &after);
	printf("open_inode_bytes=%c%c published_bytes=%c%c inode_changed=%d\n",
	       old[0], old[1], now[0], now[1], before.st_ino != after.st_ino);
	munmap(map, sizeof(bytes));
	close(temp);
	close(published);
	close(a);
	close(b);
	return 0;
}
