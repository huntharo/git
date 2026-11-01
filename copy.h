#ifndef COPY_H
#define COPY_H

struct repository;

#define COPY_READ_ERROR (-2)
#define COPY_WRITE_ERROR (-3)
int copy_fd(int ifd, int ofd);
int copy_file(struct repository *repo,
	      const char *dst, const char *src, int mode);
int copy_file_with_time(struct repository *repo,
			const char *dst, const char *src, int mode);

/*
 * Create "dst" as a copy-on-write clone of the regular file open on
 * "src_fd" (APFS clonefile(2), or FICLONE on btrfs, XFS, bcachefs and
 * overlayfs). Only the data is cloned: "dst" ends up as a regular file
 * that shares data blocks with the source, but whose owner, permission
 * bits (from "mode" and the umask, exactly as open(dst, O_CREAT, mode)
 * gives), timestamps (including the creation time) and extended
 * attributes are those of a newly created file.
 *
 * "dst" must not exist. On success, returns a file descriptor open for
 * reading on "dst". On failure, returns -1 with errno set and leaves
 * nothing at "dst". errno is ENOSYS where cloning is not implemented
 * (including Windows), ENOTSUP if the source's filesystem is not one we
 * clone on, EXDEV if "dst" is on another filesystem, and EINVAL if this
 * particular source cannot be cloned.
 */
int clone_fd_to_file(int src_fd, const char *dst, int mode);

/* Is "path" on a filesystem clone_fd_to_file() is willing to clone on? */
int path_fs_can_clone(const char *path);

/* Like clone_fd_to_file(), opening "src" (not following symlinks). */
int clone_file(const char *dst, const char *src, int mode);

#endif /* COPY_H */
