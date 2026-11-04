#include "git-compat-util.h"
#include "copy.h"
#include "path.h"
#include "gettext.h"
#include "strbuf.h"
#include "abspath.h"

#if defined(__linux__)
#include <sys/ioctl.h>
/*
 * FICLONE lives in <linux/fs.h>, which tends to clash with the libc
 * headers we already include. The value is part of the stable uapi.
 */
#ifndef FICLONE
#define FICLONE _IOW(0x94, 9, int)
#endif
#include <sys/vfs.h>
#elif defined(__APPLE__)
#include <sys/attr.h>
#include <sys/clonefile.h>
#include <sys/mount.h>
#include <sys/xattr.h>
#endif

int copy_fd(int ifd, int ofd)
{
	while (1) {
		char buffer[8192];
		ssize_t len = xread(ifd, buffer, sizeof(buffer));
		if (!len)
			break;
		if (len < 0)
			return COPY_READ_ERROR;
		if (write_in_full(ofd, buffer, len) < 0)
			return COPY_WRITE_ERROR;
	}
	return 0;
}

static int copy_times(const char *dst, const char *src)
{
	struct stat st;
	struct utimbuf times;
	if (stat(src, &st) < 0)
		return -1;
	times.actime = st.st_atime;
	times.modtime = st.st_mtime;
	if (utime(dst, &times) < 0)
		return -1;
	return 0;
}

int copy_file(struct repository *repo,
	      const char *dst, const char *src, int mode)
{
	int fdi, fdo, status;

	mode = (mode & 0111) ? 0777 : 0666;
	if ((fdi = open(src, O_RDONLY)) < 0)
		return fdi;
	if ((fdo = open(dst, O_WRONLY | O_CREAT | O_EXCL, mode)) < 0) {
		close(fdi);
		return fdo;
	}
	status = copy_fd(fdi, fdo);
	switch (status) {
	case COPY_READ_ERROR:
		error_errno("copy-fd: read returned");
		break;
	case COPY_WRITE_ERROR:
		error_errno("copy-fd: write returned");
		break;
	}
	close(fdi);
	if (close(fdo) != 0)
		return error_errno("%s: close error", dst);

	if (!status && adjust_shared_perm(repo, dst))
		return -1;

	return status;
}

int copy_file_with_time(struct repository *repo,
			const char *dst, const char *src, int mode)
{
	int status = copy_file(repo, dst, src, mode);
	if (!status)
		return copy_times(dst, src);
	return status;
}

#if defined(__APPLE__) || defined(__linux__)
/*
 * Only filesystems whose cloning we know to be a faithful, atomic
 * snapshot of the source data. In particular CIFS/SMB3 (which maps
 * FICLONE to the FSCTL_DUPLICATE_EXTENTS_TO_FILE that misbehaves on
 * Windows), NFS and ZFS are not on the list.
 */
static int fs_can_clone(int fd)
{
#if defined(__APPLE__)
	struct statfs sfs;

	if (fstatfs(fd, &sfs))
		return 0;
	return !strcmp(sfs.f_fstypename, "apfs");
#else
	struct statfs sfs;
	unsigned long type;

	if (fstatfs(fd, &sfs))
		return 0;
	type = (unsigned long)sfs.f_type & 0xffffffffUL;
	return type == 0x9123683EUL ||	/* btrfs */
	       type == 0x58465342UL ||	/* xfs */
	       type == 0xca451a4eUL ||	/* bcachefs */
	       type == 0x794c7630UL;	/* overlayfs */
#endif
}
#endif

#if defined(__APPLE__)
/*
 * The umask, read once. clone_file() is only called from single-threaded
 * code (checkout and its worker processes), so the umask(0)/umask(mask)
 * dance cannot race with another thread creating a file.
 */
static mode_t current_umask(void)
{
	static int initialized;
	static mode_t mask;

	if (!initialized) {
		mask = umask(0);
		umask(mask);
		initialized = 1;
	}
	return mask;
}

/*
 * clonefile() copies extended attributes such as com.apple.quarantine
 * along with the data. A file written by checkout would not carry them,
 * so drop them. "com.apple.provenance" is kernel-managed and is attached
 * to every file this process creates anyway, so leave it alone.
 */
static int strip_xattrs(int fd)
{
	char stack_buf[1024], *buf = stack_buf;
	ssize_t len, i;
	int ret = 0;

	len = flistxattr(fd, NULL, 0, 0);
	if (len <= 0)
		return len < 0 ? -1 : 0;
	if ((size_t)len > sizeof(stack_buf))
		buf = xmalloc(len);
	len = flistxattr(fd, buf, len, 0);
	if (len < 0)
		ret = -1;
	for (i = 0; !ret && i < len; i += strlen(buf + i) + 1) {
		if (!strcmp(buf + i, "com.apple.provenance"))
			continue;
		if (fremovexattr(fd, buf + i, 0))
			ret = -1;
	}
	if (buf != stack_buf)
		free(buf);
	return ret;
}

/* Make a fresh clone look like a file we just created and wrote. */
static int fix_up_clone(int fd, int mode)
{
	struct attrlist al = { 0 };
	struct {
		struct timespec birth, mtime, atime;
		uint32_t mode;
	} __attribute__((packed)) attrs;
	struct timespec now;
	struct stat st;

	if (fstat(fd, &st))
		return -1;
	if (!S_ISREG(st.st_mode)) {
		errno = EINVAL;
		return -1;
	}
	if (st.st_flags) {
		/* the source had none a moment ago; do not keep any */
		fchflags(fd, 0);
		errno = EINVAL;
		return -1;
	}
	/*
	 * Strip extended attributes first: removing them needs write
	 * permission, which the final mode may not give us.
	 */
	if (strip_xattrs(fd))
		return -1;
	/*
	 * clonefile() keeps the source's timestamps, including the
	 * creation time. A written file is created and modified "now";
	 * build tools rely on the mtime being new.
	 */
	if (clock_gettime(CLOCK_REALTIME, &now))
		return -1;
	al.bitmapcount = ATTR_BIT_MAP_COUNT;
	al.commonattr = ATTR_CMN_CRTIME | ATTR_CMN_MODTIME |
		ATTR_CMN_ACCTIME | ATTR_CMN_ACCESSMASK;
	/* setattrlist packs attributes in bitmap order, on four-byte boundaries. */
	attrs.birth = attrs.mtime = attrs.atime = now;
	attrs.mode = mode & ~current_umask();
	return fsetattrlist(fd, &al, &attrs, sizeof(attrs), 0);
}
#endif

int path_fs_can_clone(const char *path)
{
#if defined(__APPLE__) || defined(__linux__)
	int fd = open(path, O_RDONLY | O_NONBLOCK);
	int ret;

	if (fd < 0)
		return 0;
	ret = fs_can_clone(fd);
	close(fd);
	return ret;
#else
	(void)path;
	return 0;
#endif
}

int clone_fd_to_file(int src_fd, const char *dst, int mode)
{
#if defined(__APPLE__) || defined(__linux__)
	struct stat st;
	int fd, saved;

	mode = (mode & 0100) ? 0777 : 0666;
	if (fstat(src_fd, &st))
		return -1;
	if (!S_ISREG(st.st_mode)) {
		errno = EINVAL;
		return -1;
	}
	if (!fs_can_clone(src_fd)) {
		errno = ENOTSUP;
		return -1;
	}
#if defined(__APPLE__)
	if (st.st_flags) {
		/* immutable, compressed, dataless, ...: not what we write */
		errno = EINVAL;
		return -1;
	}
	if (fclonefileat(src_fd, AT_FDCWD, dst,
			 CLONE_NOFOLLOW | CLONE_NOOWNERCOPY))
		return -1;
	/*
	 * "dst" is now ours: a clone of the regular file behind src_fd.
	 * Fix it up through a descriptor; on failure remove it again.
	 */
	fd = open(dst, O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
	if (fd < 0 || fix_up_clone(fd, mode)) {
		saved = errno;
		if (fd >= 0)
			close(fd);
		unlink(dst);
		errno = saved;
		return -1;
	}
	return fd;
#else
	/*
	 * Create the destination exactly as checkout does, so that mode,
	 * owner, security label and timestamps are those of a new file;
	 * FICLONE then only replaces its (empty) data.
	 */
	fd = open(dst, O_RDWR | O_CREAT | O_EXCL, mode);
	if (fd < 0)
		return -1;
	if (ioctl(fd, FICLONE, src_fd) < 0) {
		saved = errno;
		close(fd);
		unlink(dst);
		errno = saved;
		return -1;
	}
	return fd;
#endif
#else
	(void)src_fd;
	(void)dst;
	(void)mode;
	/*
	 * No other platform has a primitive we trust. In particular, ReFS
	 * block cloning (FSCTL_DUPLICATE_EXTENTS_TO_FILE) on Windows can
	 * publish zeros for cached source data (git-lfs#6312), so it is not
	 * used.
	 */
	errno = ENOSYS;
	return -1;
#endif
}

int clone_file(const char *dst, const char *src, int mode)
{
#if defined(__APPLE__) || defined(__linux__)
	int src_fd, fd, saved;

	src_fd = open(src, O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
	if (src_fd < 0)
		return -1;
	fd = clone_fd_to_file(src_fd, dst, mode);
	saved = errno;
	close(src_fd);
	errno = saved;
	return fd;
#else
	(void)dst;
	(void)src;
	(void)mode;
	errno = ENOSYS;
	return -1;
#endif
}

#if defined(__linux__)
/* Stable Linux uapi, kept local to avoid linux/fs.h/libc header conflicts. */
struct git_fiemap_extent {
	uint64_t logical, physical, length, reserved64[2];
	uint32_t flags, reserved[3];
};
struct git_fiemap {
	uint64_t start, length;
	uint32_t flags, mapped_extents, extent_count, reserved;
	struct git_fiemap_extent extents[64];
};
struct git_fiemap_header {
	uint64_t start, length;
	uint32_t flags, mapped_extents, extent_count, reserved;
};
#define GIT_FIEMAP _IOWR('f', 11, struct git_fiemap_header)
#define GIT_FIEMAP_SYNC 0x1
#define GIT_FIEMAP_LAST 0x1
#define GIT_FIEMAP_UNKNOWN 0x2
#define GIT_FIEMAP_DELALLOC 0x4
#define GIT_FIEMAP_INLINE 0x200
#define GIT_FIEMAP_SHARED 0x2000

struct git_dedupe_range {
	uint64_t src_offset, src_length;
	uint16_t dest_count, reserved1;
	uint32_t reserved2;
};
struct git_dedupe_info {
	int64_t dest_fd;
	uint64_t dest_offset, bytes_deduped;
	int32_t status;
	uint32_t reserved;
};
#define GIT_DEDUPE_RANGE _IOWR(0x94, 54, struct git_dedupe_range)
#endif

int get_file_data_usage(int fd, struct file_data_usage *usage)
{
	struct stat st;

	memset(usage, 0, sizeof(*usage));
	if (fstat(fd, &st))
		return -1;
	if (!S_ISREG(st.st_mode)) {
		errno = EINVAL;
		return -1;
	}
	usage->allocated = on_disk_bytes(st);
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
		if (fgetattrlist(fd, &al, &buf, sizeof(buf), FSOPT_ATTR_CMN_EXTENDED))
			return -1;
		if (!(buf.returned.forkattr & ATTR_CMNEXT_PRIVATESIZE) ||
		    buf.private_size < 0) {
			errno = ENOTSUP;
			return -1;
		}
		usage->private_bytes = buf.private_size;
		return 0;
	}
#elif defined(__linux__)
	{
		struct git_fiemap fm;
		uint64_t start = 0;

		for (;;) {
			uint64_t next = start;
			int last = 0;

			memset(&fm, 0, sizeof(fm));
			fm.start = start;
			fm.length = UINT64_MAX - start;
			fm.flags = GIT_FIEMAP_SYNC;
			fm.extent_count = ARRAY_SIZE(fm.extents);
			if (ioctl(fd, GIT_FIEMAP, &fm))
				return -1;
			if (!fm.mapped_extents)
				break;
			if (fm.mapped_extents > ARRAY_SIZE(fm.extents)) {
				errno = EIO;
				return -1;
			}
			for (size_t i = 0; i < fm.mapped_extents; i++) {
				struct git_fiemap_extent *e = &fm.extents[i];

				if (e->flags & (GIT_FIEMAP_UNKNOWN | GIT_FIEMAP_DELALLOC)) {
					errno = ENOTSUP;
					return -1;
				}
				if (!(e->flags & (GIT_FIEMAP_SHARED | GIT_FIEMAP_INLINE)))
					usage->private_bytes += e->length;
				if (e->logical > UINT64_MAX - e->length) {
					errno = EOVERFLOW;
					return -1;
				}
				next = e->logical + e->length;
				last |= !!(e->flags & GIT_FIEMAP_LAST);
			}
			if (last)
				break;
			if (next <= start) {
				errno = EIO;
				return -1;
			}
			start = next;
		}
		if (fstat(fd, &st))
			return -1;
		usage->allocated = on_disk_bytes(st);
		return 0;
	}
#else
	errno = ENOTSUP;
	return -1;
#endif
}

int can_dedupe_file_data(int fd)
{
#if defined(__linux__)
	return fs_can_clone(fd);
#else
	(void)fd;
	return 0;
#endif
}

int dedupe_file_data(int src_fd, int dst_fd, uintmax_t size, uintmax_t *done)
{
	*done = 0;
#if defined(__linux__)
	if (!can_dedupe_file_data(src_fd) || !can_dedupe_file_data(dst_fd)) {
		errno = ENOTSUP;
		return -1;
	}
	while (*done < size) {
		struct {
			struct git_dedupe_range range;
			struct git_dedupe_info info;
		} arg;
		uintmax_t remaining = size - *done;
		uintmax_t length = remaining < 16 * 1024 * 1024 ?
			remaining : 16 * 1024 * 1024;

		memset(&arg, 0, sizeof(arg));
		arg.range.src_offset = *done;
		arg.range.src_length = length;
		arg.range.dest_count = 1;
		arg.info.dest_fd = dst_fd;
		arg.info.dest_offset = *done;
		if (ioctl(src_fd, GIT_DEDUPE_RANGE, &arg))
			return -1;
		if (arg.info.status == 1)
			return 1;
		if (arg.info.status < 0) {
			errno = -arg.info.status;
			return -1;
		}
		if (arg.info.status || !arg.info.bytes_deduped ||
		    arg.info.bytes_deduped > length) {
			errno = EIO;
			return -1;
		}
		*done += arg.info.bytes_deduped;
	}
	return 0;
#else
	(void)src_fd;
	(void)dst_fd;
	(void)size;
	errno = ENOTSUP;
	return -1;
#endif
}
