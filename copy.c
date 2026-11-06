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
	struct timespec now, times[2];
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
	if (strip_xattrs(fd) || fchmod(fd, mode & ~current_umask()))
		return -1;
	/*
	 * clonefile() keeps the source's timestamps, including the
	 * creation time. A written file is created and modified "now";
	 * build tools rely on the mtime being new.
	 */
	if (clock_gettime(CLOCK_REALTIME, &now))
		return -1;
	al.bitmapcount = ATTR_BIT_MAP_COUNT;
	al.commonattr = ATTR_CMN_CRTIME;
	if (fsetattrlist(fd, &al, &now, sizeof(now), 0))
		return -1;
	times[0] = times[1] = now;
	return futimens(fd, times);
}
#endif

#if defined(__linux__)
/*
 * BTRFS_IOC_FS_INFO, spelled out like FICLONE (<linux/btrfs.h> is not
 * installed everywhere). Unprivileged; part of the stable uapi.
 */
struct reflink_btrfs_fs_info {
	uint64_t max_id, num_devices;
	uint8_t fsid[16];
	uint32_t nodesize, sectorsize, clone_alignment;
	uint16_t csum_type, csum_size;
	uint64_t flags, generation;
	uint8_t metadata_uuid[16];
	uint8_t reserved[944];
};
#define REFLINK_BTRFS_IOC_FS_INFO _IOR(0x94, 31, struct reflink_btrfs_fs_info)

/* The UUID of the btrfs filesystem "path" is on, or -1 if not btrfs. */
static int btrfs_fsid(const char *path, uint8_t *fsid)
{
	struct reflink_btrfs_fs_info info;
	struct statfs sfs;
	int fd = open(path, O_RDONLY | O_NONBLOCK), ret = -1;

	if (fd < 0)
		return -1;
	if (!fstatfs(fd, &sfs) &&
	    ((unsigned long)sfs.f_type & 0xffffffffUL) == 0x9123683EUL) {
		memset(&info, 0, sizeof(info));
		if (!ioctl(fd, REFLINK_BTRFS_IOC_FS_INFO, &info)) {
			memcpy(fsid, info.fsid, sizeof(info.fsid));
			ret = 0;
		}
	}
	close(fd);
	return ret;
}
#endif

int same_clone_filesystem(const char *a, const char *b)
{
#if defined(__APPLE__) || defined(__linux__)
	struct stat sa, sb;

	if (stat(a, &sa) || stat(b, &sb))
		return 0;
	if (sa.st_dev == sb.st_dev)
		return 1;
#if defined(__linux__)
	{
		/*
		 * btrfs gives each subvolume its own st_dev, yet clones
		 * between subvolumes of one filesystem.
		 */
		uint8_t fa[16], fb[16];

		if (!btrfs_fsid(a, fa) && !btrfs_fsid(b, fb))
			return !memcmp(fa, fb, sizeof(fa));
	}
#endif
#else
	(void)a;
	(void)b;
#endif
	return 0;
}

int fd_fs_can_clone(int fd)
{
#if defined(__APPLE__) || defined(__linux__)
	return fs_can_clone(fd);
#else
	(void)fd;
	return 0;
#endif
}

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
