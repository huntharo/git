# Can the generation query share Git's existing metadata call?

Checked the installed macOS 27.2 SDK, public Apple XNU sources and Git's
metadata paths on 2026-11-09. The current implementation adds a separate
`getattrlist` query to existing `lstat` paths. The ordinary metadata paths do
not already use `getattrlist` with an attribute selector to extend.

`stat`, `lstat` and `fstat` have no attribute-selection argument. `fstatat`
has lookup flags, but none requests a write generation count. The Darwin
`statx_np` variants add file-security output, not a Linux-style statx mask.
The installed SDK exposes no flag that requests `va_write_gencount` through
these calls. Their `st_gen` is sourced from `va_gen`, which is different
from `getattrlist`'s `ATTR_CMN_GEN_COUNT` / `va_write_gencount`. Public XNU
also suppresses `st_gen` for unprivileged users.

There is a public one-call alternative: **replace** a metadata call with
`getattrlist`, requesting ordinary stat fields and the write generation
together. `combined-metadata.c` is a disposable proof for regular files,
not an integrated Git implementation. It requests device, object type,
mtime/ctime, uid/gid, permissions, inode, data length and write generation
in one syscall, with returned-attribute validation and `FSOPT_NOFOLLOW`.

`combined-metadata.jsonl` records eight snapshots of two fresh, fully written
16 KiB files: shared/private, unmapped, mapped with FD closed, after a store,
and after unmapping. All Git stat-comparison fields matched `lstat` in all
eight snapshots. Shared write generations were `[2, 0, 0, 3]`; private were
`[2, 2, 2, 2]`. Both `lstat.st_gen` and `fstatat.st_gen` were zero throughout.
The mtime and ctime, including nanoseconds, stayed fixed through mapping
and the acknowledged store. No timing or general filesystem-compatibility
claim follows from this small probe.

Reproduce from this worktree root:

```sh
cc -std=c99 -Wall -Wextra -Werror -O2 mmap-investigation/combined-metadata.c \
  -o mmap-investigation/combined-metadata
./mmap-investigation/combined-metadata mmap-investigation/combined-file-XXXXXX
```

Integration would need an explicit way to carry both stat information and
the reliability result to the comparison, preserving symlink/directory,
error and unsupported-attribute fallbacks. It must not hide transient state
in reserved `struct stat` fields or reuse a stale path cache. Fsmonitor-valid
paths previously made no stat call, so combining metadata cannot remove
the need to validate those paths. The separate benchmark thread has been
given this proof and asked to distinguish combined-API feasibility from
measured end-to-end performance of the current two-call implementation.

Primary sources (public source release, not the running kernel's exact build):

- [stat declarations](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/sys/stat.h)
- [stat fields use va_gen](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/vfs/vfs_vnops.c#L1449)
- [generation attribute packs va_write_gencount](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/vfs/vfs_attrlist.c#L1892)
- [getattrlist contract](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/getattrlist.2.html)
