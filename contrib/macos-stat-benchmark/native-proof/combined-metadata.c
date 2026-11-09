/* Disposable macOS API probe, not a replacement for Git's stat abstraction. */
#include <sys/attr.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/vnode.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* getattrlist fields are packed at four-byte alignment. */
#pragma pack(push, 4)
struct metadata {
	uint32_t length;
	attribute_set_t returned;
	uint32_t device;
	fsobj_type_t type;
	struct timespec mtime;
	struct timespec ctime;
	uid_t uid;
	gid_t gid;
	uint32_t mode;
	uint32_t write_generation;
	uint64_t inode;
	off_t size;
};
#pragma pack(pop)

static void fail(const char *what)
{
	perror(what);
	exit(1);
}

static void snapshot(const char *path, const char *mode, const char *phase)
{
	struct stat st, at;
	struct metadata meta = { 0 };
	struct attrlist attrs = { 0 };
	int same;

	attrs.bitmapcount = ATTR_BIT_MAP_COUNT;
	attrs.commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_DEVID |
		ATTR_CMN_OBJTYPE | ATTR_CMN_MODTIME | ATTR_CMN_CHGTIME |
		ATTR_CMN_OWNERID | ATTR_CMN_GRPID | ATTR_CMN_ACCESSMASK |
		ATTR_CMN_GEN_COUNT | ATTR_CMN_FILEID;
	attrs.fileattr = ATTR_FILE_DATALENGTH;
	if (lstat(path, &st) ||
	    fstatat(AT_FDCWD, path, &at, AT_SYMLINK_NOFOLLOW))
		fail("stat");
	if (getattrlist(path, &attrs, &meta, sizeof(meta),
			FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW))
		fail("combined getattrlist");
	if (meta.length != sizeof(meta) ||
	    (meta.returned.commonattr & attrs.commonattr) != attrs.commonattr ||
	    (meta.returned.fileattr & attrs.fileattr) != attrs.fileattr) {
		fprintf(stderr, "incomplete combined metadata: len=%u expected=%zu\n",
			meta.length, sizeof(meta));
		exit(1);
	}
	same = meta.device == (uint32_t)st.st_dev &&
		meta.inode == (uint64_t)st.st_ino &&
		meta.type == VREG && S_ISREG(st.st_mode) &&
		(meta.mode & 07777) == (st.st_mode & 07777) &&
		meta.uid == st.st_uid && meta.gid == st.st_gid &&
		meta.size == st.st_size &&
		meta.mtime.tv_sec == st.st_mtimespec.tv_sec &&
		meta.mtime.tv_nsec == st.st_mtimespec.tv_nsec &&
		meta.ctime.tv_sec == st.st_ctimespec.tv_sec &&
		meta.ctime.tv_nsec == st.st_ctimespec.tv_nsec;
	printf("{\"mapping\":\"%s\",\"phase\":\"%s\","
	       "\"git_stat_fields_match\":%s,\"lstat_st_gen\":%u,"
	       "\"fstatat_st_gen\":%u,\"write_generation\":%u,"
	       "\"mtime_sec\":%lld,\"mtime_ns\":%ld,"
	       "\"ctime_sec\":%lld,\"ctime_ns\":%ld}\n",
	       mode, phase, same ? "true" : "false", st.st_gen, at.st_gen,
	       meta.write_generation, (long long)st.st_mtimespec.tv_sec,
	       st.st_mtimespec.tv_nsec, (long long)st.st_ctimespec.tv_sec,
	       st.st_ctimespec.tv_nsec);
	if (!same)
		exit(1);
}

int main(int argc, char **argv)
{
	char data[16384];
	int flags[] = { MAP_SHARED, MAP_PRIVATE };
	const char *modes[] = { "shared", "private" };
	size_t i;

	if (argc != 2)
		return 2;
	memset(data, 'A', sizeof(data));
	for (i = 0; i < sizeof(flags) / sizeof(flags[0]); i++) {
		char *path = strdup(argv[1]);
		int fd = mkstemp(path);
		char *mapping;

		if (fd < 0 || write(fd, data, sizeof(data)) != sizeof(data))
			fail("create ordinary file");
		snapshot(path, modes[i], "unmapped");
		mapping = mmap(NULL, sizeof(data), PROT_READ | PROT_WRITE,
			       flags[i], fd, 0);
		if (mapping == MAP_FAILED || close(fd))
			fail("mmap/close");
		snapshot(path, modes[i], "mapped_fd_closed");
		mapping[0] = 'B';
		snapshot(path, modes[i], "stored");
		if (munmap(mapping, sizeof(data)))
			fail("munmap");
		snapshot(path, modes[i], "unmapped_again");
		if (unlink(path))
			fail("unlink");
		free(path);
	}
	return 0;
}
