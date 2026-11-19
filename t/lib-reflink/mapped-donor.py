"""APFS may omit stat updates for subsequent writes to a dirty mapped page."""
import mmap
import os
from pathlib import Path
import subprocess
import time


def git(*args):
    return subprocess.check_output(["git", "-C", "donor", *args])


path = Path("donor/data")
path.write_bytes(b"A" * 65536)
with path.open("r+b") as stream, mmap.mmap(stream.fileno(), 0) as mapping:
    mapping[0] = ord("B")
    mapping.flush()
    time.sleep(1.1)
    git("add", "data")
    git("commit", "-qm", "first mapped write")
    git("status", "--porcelain")
    mapping[1] = ord("C")
    time.sleep(1.1)
    # Stage by content so even a kernel that elides this stat change
    # records the second write before the adversarial third write.
    oid = git("hash-object", "-w", "--no-filters", "data").decode().strip()
    git("update-index", "--cacheinfo", f"100644,{oid},data")
    git("commit", "-qm", "second mapped write")
    git("update-index", "--really-refresh")
    expected = git("show", "HEAD:data")
    time.sleep(1.1)
    before = path.stat()
    mapping[2] = ord("D")
    after = path.stat()
    assert path.read_bytes() != expected
    invisible = (before.st_mtime_ns, before.st_ctime_ns) == (
        after.st_mtime_ns, after.st_ctime_ns
    )
    git("worktree", "add", "-q", "--no-reflink", "--detach", "../ordinary")
    git("worktree", "add", "-q", "--reflink-source=.", "--detach", "../actual")
    assert Path("ordinary/data").read_bytes() == expected
    assert Path("actual/data").read_bytes() == expected
    Path("donor/.git/info/attributes").write_text("data filter=passthru\n")
    git("config", "filter.passthru.smudge", "cat")
    git("worktree", "add", "-q", "--reflink-source=.", "--detach", "../filtered")
    assert Path("filtered/data").read_bytes() == expected
    print("stat-invisible" if invisible else "stat-changed")

# Quiesced through apply. Subsequent writes through old descriptors/mappings
# remain on the old inode; the pathname keeps the verified bytes.
for worktree in ("ordinary", "actual"):
    aged = time.time() - 60
    os.utime(Path(worktree) / "data", (aged, aged))
    subprocess.check_call(["git", "-C", worktree, "update-index", "--refresh"])
target = Path("ordinary/data")
with target.open("r+b") as stream, mmap.mmap(stream.fileno(), 0) as mapping:
    before = os.fstat(stream.fileno())
    subprocess.check_call([
        "git", "-C", "ordinary", "worktree", "reflink", "--reflink-source=../actual"
    ])
    assert target.stat().st_ino != before.st_ino
    assert target.read_bytes() == expected
    mapping[3] = ord("E")
    assert target.read_bytes() == expected
