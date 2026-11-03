/*
 * test-tool reflink: inspect copy-on-write sharing between files.
 *
 *   test-tool reflink probe <dir>
 *	exit 0 if clone_file() works for files in <dir>
 *
 *   test-tool reflink age <path>
 *	make a fixture's real mtime non-racy, without following symlinks
 *
 *   test-tool reflink shared <a> <b>
 *	exit 0 if <a> and <b> start on the same physical block, i.e. <b>
 *	is (still) a clone of <a> or the other way round, 1 if they do not,
 *	2 if that cannot be determined
 *
 *   test-tool reflink private-bytes <path>...
 *	print "<private> <allocated> <files> <fully-shared-files>" for the
 *	regular files under <path>... (directories are walked, ".git" is
 *	skipped). <private> counts bytes stored only for these files,
 *	<allocated> all bytes allocated to them.
 */
#include "test-tool.h"
#include "git-compat-util.h"
#include "copy.h"
#include "dir.h"
#include "strbuf.h"

#if defined(__APPLE__)
#include <sys/attr.h>
#elif defined(__linux__)
#include <sys/ioctl.h>
/*
 * <linux/fiemap.h> is not installed everywhere (e.g. musl systems
 * without the kernel headers). FIEMAP is part of the stable uapi, so
 * spell it out. The extents follow the header in the same buffer.
 */
struct fiemap_hdr {
	uint64_t fm_start, fm_length;
	uint32_t fm_flags, fm_mapped_extents, fm_extent_count, fm_reserved;
};
struct fiemap_ext {
	uint64_t fe_logical, fe_physical, fe_length, fe_reserved64[2];
	uint32_t fe_flags, fe_reserved[3];
};
#define REFLINK_FS_IOC_FIEMAP _IOWR('f', 11, struct fiemap_hdr)
#define REFLINK_FIEMAP_MAX_OFFSET (~(uint64_t)0)
#define REFLINK_FIEMAP_FLAG_SYNC 0x00000001
#define REFLINK_FIEMAP_EXTENT_LAST 0x00000001
#define REFLINK_FIEMAP_EXTENT_UNKNOWN 0x00000002
#define REFLINK_FIEMAP_EXTENT_DATA_INLINE 0x00000200
#define REFLINK_FIEMAP_EXTENT_SHARED 0x00002000

static struct fiemap_ext *fiemap_extents(struct fiemap_hdr *fm)
{
	return (struct fiemap_ext *)(fm + 1);
}
#endif

static int probe(const char *dir)
{
	struct strbuf a = STRBUF_INIT, b = STRBUF_INIT;
	int fd, ret = 1;

	strbuf_addf(&a, "%s/.reflink-probe-a", dir);
	strbuf_addf(&b, "%s/.reflink-probe-b", dir);
	unlink(a.buf);
	unlink(b.buf);
	fd = open(a.buf, O_WRONLY | O_CREAT | O_EXCL, 0666);
	if (fd >= 0) {
		if (write_in_full(fd, "probe\n", 6) == 6 && !close(fd)) {
			fd = clone_file(b.buf, a.buf, 0644);
			if (fd >= 0) {
				close(fd);
				ret = 0;
			}
		} else {
			close(fd);
		}
	}
	unlink(a.buf);
	unlink(b.buf);
	strbuf_release(&a);
	strbuf_release(&b);
	return ret;
}

static int dedupe_probe(const char *dir)
{
	struct strbuf a = STRBUF_INIT, b = STRBUF_INIT;
	char data[65536];
	uintmax_t done;
	int src = -1, dst = -1, ret = 1;

	memset(data, 'x', sizeof(data));
	strbuf_addf(&a, "%s/.dedupe-probe-a", dir);
	strbuf_addf(&b, "%s/.dedupe-probe-b", dir);
	unlink(a.buf);
	unlink(b.buf);
	src = open(a.buf, O_RDWR | O_CREAT | O_EXCL, 0600);
	dst = open(b.buf, O_RDWR | O_CREAT | O_EXCL, 0600);
	if (src >= 0 && dst >= 0 &&
	    write_in_full(src, data, sizeof(data)) == sizeof(data) &&
	    write_in_full(dst, data, sizeof(data)) == sizeof(data) &&
	    !dedupe_file_data(src, dst, sizeof(data), &done) && done == sizeof(data))
		ret = 0;
	if (src >= 0)
		close(src);
	if (dst >= 0)
		close(dst);
	unlink(a.buf);
	unlink(b.buf);
	strbuf_release(&a);
	strbuf_release(&b);
	return ret;
}

/* Physical location of the first byte of "path", or -1. */
static long long first_block(const char *path)
{
	long long ret = -1;
	int fd = open(path, O_RDONLY);

	if (fd < 0)
		return -1;
#if defined(__APPLE__)
	{
		struct log2phys l = { 0 };
		l.l2p_contigbytes = 1;
		l.l2p_devoffset = 0;
		if (!fcntl(fd, F_LOG2PHYS_EXT, &l))
			ret = l.l2p_devoffset;
	}
#elif defined(__linux__)
	{
		struct fiemap_hdr *fm = xcalloc(1, sizeof(*fm) +
						sizeof(struct fiemap_ext));
		struct fiemap_ext *e = fiemap_extents(fm);

		fm->fm_length = 1;
		fm->fm_flags = REFLINK_FIEMAP_FLAG_SYNC;
		fm->fm_extent_count = 1;
		if (!ioctl(fd, REFLINK_FS_IOC_FIEMAP, fm) && fm->fm_mapped_extents &&
		    !(e->fe_flags & (REFLINK_FIEMAP_EXTENT_UNKNOWN |
				     REFLINK_FIEMAP_EXTENT_DATA_INLINE)))
			ret = e->fe_physical;
		free(fm);
	}
#endif
	close(fd);
	return ret;
}

struct usage_totals {
	uintmax_t private_bytes, allocated, files, fully_shared;
};

static int file_usage(const char *path, struct usage_totals *t)
{
	struct stat st;
	struct file_data_usage usage;
	int fd, ret;

	if (lstat(path, &st) || !S_ISREG(st.st_mode))
		return 0;
	fd = open(path, O_RDONLY
#if defined(__APPLE__) || defined(__linux__)
		  | O_NOFOLLOW | O_NONBLOCK
#endif
		 );
	if (fd < 0)
		return error_errno("open(%s)", path);
	ret = get_file_data_usage(fd, &usage);
	close(fd);
#if !defined(__APPLE__) && !defined(__linux__)
	usage.allocated = usage.private_bytes = on_disk_bytes(st);
	ret = 0;
#endif
	if (ret)
		return error_errno("physical allocation unavailable for %s", path);
	t->files++;
	t->allocated += usage.allocated;
	t->private_bytes += usage.private_bytes;
	if (!usage.private_bytes)
		t->fully_shared++;
	return 0;
}

static int tree_usage(struct strbuf *path, struct usage_totals *t)
{
	struct stat st;
	DIR *dir;
	struct dirent *e;
	size_t len;
	int ret = 0;

	if (lstat(path->buf, &st))
		return error_errno("lstat(%s)", path->buf);
	if (!S_ISDIR(st.st_mode))
		return file_usage(path->buf, t);
	dir = opendir(path->buf);
	if (!dir)
		return error_errno("opendir(%s)", path->buf);
	len = path->len;
	while (!ret && (e = readdir(dir))) {
		if (is_dot_or_dotdot(e->d_name) || !strcmp(e->d_name, ".git"))
			continue;
		strbuf_setlen(path, len);
		strbuf_addf(path, "/%s", e->d_name);
		ret = tree_usage(path, t);
	}
	strbuf_setlen(path, len);
	closedir(dir);
	return ret;
}

static int age_file(const char *path)
{
#if defined(__APPLE__) || defined(__linux__)
	struct stat st;
	struct timespec times[2];

	if (lstat(path, &st))
		return error_errno("lstat(%s)", path);
	times[0].tv_sec = st.st_atime;
	times[0].tv_nsec = 0;
	times[1].tv_sec = time(NULL) - 60;
	times[1].tv_nsec = 0;
	if (utimensat(AT_FDCWD, path, times, AT_SYMLINK_NOFOLLOW))
		return error_errno("utimensat(%s)", path);
	return 0;
#else
	return error("aging symlinks is not supported on this platform: %s", path);
#endif
}

int cmd__reflink(int argc, const char **argv)
{
	if (argc == 3 && !strcmp(argv[1], "metadata")) {
		struct stat st;
		long atime_nsec = 0;

		if (lstat(argv[2], &st))
			return error_errno("lstat(%s)", argv[2]);
#if defined(__APPLE__)
		atime_nsec = st.st_atimespec.tv_nsec;
		printf("birth %"PRIdMAX" %ld\n",
		       (intmax_t)st.st_birthtimespec.tv_sec, st.st_birthtimespec.tv_nsec);
#elif defined(__linux__)
		atime_nsec = st.st_atim.tv_nsec;
#endif
		printf("%"PRIuMAX" %"PRIuMAX" %"PRIuMAX" %o %"PRIuMAX" %"PRIuMAX
		       " %"PRIdMAX" %"PRIdMAX" %ld %"PRIdMAX" %u %"PRIdMAX" %u\n",
		       (uintmax_t)st.st_dev, (uintmax_t)st.st_ino, (uintmax_t)st.st_nlink,
		       (unsigned)st.st_mode, (uintmax_t)st.st_uid, (uintmax_t)st.st_gid,
		       (intmax_t)st.st_size, (intmax_t)st.st_atime, atime_nsec,
		       (intmax_t)st.st_mtime, ST_MTIME_NSEC(st),
		       (intmax_t)st.st_ctime, ST_CTIME_NSEC(st));
		return 0;
	}
	if (argc == 3 && !strcmp(argv[1], "dedupe-probe"))
		return dedupe_probe(argv[2]);
	if (argc == 3 && !strcmp(argv[1], "probe"))
		return probe(argv[2]);
	if (argc == 3 && !strcmp(argv[1], "age"))
		return age_file(argv[2]);
	if (argc == 4 && !strcmp(argv[1], "shared")) {
		long long a = first_block(argv[2]), b = first_block(argv[3]);
		if (a < 0 || b < 0)
			return 2; /* cannot tell */
		return a != b;
	}
	if (argc >= 3 && !strcmp(argv[1], "private-bytes")) {
		struct usage_totals t = { 0 };
		struct strbuf path = STRBUF_INIT;
		int i, ret = 0;

		for (i = 2; !ret && i < argc; i++) {
			strbuf_reset(&path);
			strbuf_addstr(&path, argv[i]);
			ret = tree_usage(&path, &t);
		}
		strbuf_release(&path);
		if (ret)
			return 1;
		printf("%"PRIuMAX" %"PRIuMAX" %"PRIuMAX" %"PRIuMAX"\n",
		       t.private_bytes, t.allocated, t.files, t.fully_shared);
		return 0;
	}
	usage("test-tool reflink (probe <dir> | age <path> | shared <a> <b> | private-bytes <path>...)");
}
