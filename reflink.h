#ifndef REFLINK_H
#define REFLINK_H

/* Does this build have a native clone backend? */
int reflink_supported(void);

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

/* Physical allocation, including partially shared files. Returns -1 if unknown. */
struct file_data_usage {
	uintmax_t allocated;
	uintmax_t private_bytes;
};
int get_file_data_usage(int fd, struct file_data_usage *usage);

/*
 * In-place compare-and-share, preserving the destination inode and contents.
 * Returns 0 for a complete range, 1 for differing bytes, -1 on error. Even a
 * partial operation never changes logical bytes. *done counts shared ranges,
 * not freed storage. Unsupported platforms (including APFS) return ENOTSUP.
 */
int can_dedupe_file_data(int fd);
int dedupe_file_data(int src_fd, int dst_fd, uintmax_t size, uintmax_t *done);

/* Copy and verify replacement metadata; unsupported platforms return -1. */
int preserve_reflink_metadata(int target, int clone, const struct stat *st);

/* Populate scratch-donor metadata for GIT_TEST_REFLINK_CHECKOUT. */
void prepare_reflink_scratch_donor(int fd);

#endif /* REFLINK_H */
