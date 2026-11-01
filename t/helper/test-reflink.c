/*
 * test-tool reflink: inspect copy-on-write sharing between files.
 *
 *   test-tool reflink probe <dir>
 *	exit 0 if clone_file() works for files in <dir>
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

	if (lstat(path, &st) || !S_ISREG(st.st_mode))
		return 0;
	t->files++;
	t->allocated += (uintmax_t)on_disk_bytes(st);
#if defined(__APPLE__)
	{
		struct attrlist al = { 0 };
		struct {
			uint32_t len;
			attribute_set_t returned;
			off_t private_size;
		} __attribute__((packed)) buf;

		memset(&buf, 0, sizeof(buf));
		al.bitmapcount = ATTR_BIT_MAP_COUNT;
		al.commonattr = ATTR_CMN_RETURNED_ATTRS;
		al.forkattr = ATTR_CMNEXT_PRIVATESIZE;
		if (getattrlist(path, &al, &buf, sizeof(buf),
				FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW))
			return error_errno("getattrlist(%s)", path);
		if (!(buf.returned.forkattr & ATTR_CMNEXT_PRIVATESIZE))
			return error("%s: filesystem does not report private size", path);
		t->private_bytes += buf.private_size;
		if (!buf.private_size)
			t->fully_shared++;
	}
#elif defined(__linux__)
	{
		int fd = open(path, O_RDONLY);
		uint64_t start = 0, private_bytes = 0;
		int last = 0;
		struct fiemap_hdr *fm;

		if (fd < 0)
			return error_errno("open(%s)", path);
		fm = xmalloc(sizeof(*fm) + 64 * sizeof(struct fiemap_ext));

		while (!last) {
			uint32_t i;

			memset(fm, 0, sizeof(*fm));
			fm->fm_start = start;
			fm->fm_length = REFLINK_FIEMAP_MAX_OFFSET - start;
			fm->fm_flags = REFLINK_FIEMAP_FLAG_SYNC;
			fm->fm_extent_count = 64;
			if (ioctl(fd, REFLINK_FS_IOC_FIEMAP, fm)) {
				free(fm);
				close(fd);
				return error_errno("FIEMAP(%s)", path);
			}
			if (!fm->fm_mapped_extents)
				break;
			for (i = 0; i < fm->fm_mapped_extents; i++) {
				struct fiemap_ext *e = &fiemap_extents(fm)[i];
				if (!(e->fe_flags & REFLINK_FIEMAP_EXTENT_SHARED))
					private_bytes += e->fe_length;
				start = e->fe_logical + e->fe_length;
				if (e->fe_flags & REFLINK_FIEMAP_EXTENT_LAST)
					last = 1;
			}
		}
		free(fm);
		close(fd);
		t->private_bytes += private_bytes;
		if (!private_bytes)
			t->fully_shared++;
	}
#else
	t->private_bytes += (uintmax_t)on_disk_bytes(st);
#endif
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

int cmd__reflink(int argc, const char **argv)
{
	if (argc == 3 && !strcmp(argv[1], "probe"))
		return probe(argv[2]);
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
	usage("test-tool reflink (probe <dir> | shared <a> <b> | private-bytes <path>...)");
}
