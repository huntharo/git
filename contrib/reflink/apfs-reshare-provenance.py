#!/usr/bin/env python3
"""Native APFS re-share oracle with controlled cross-application metadata.

Only creates --root (which must not exist). Provenance is modeled at the
syscall boundary: writing that kernel-owned xattr cannot reliably forge it.
All data, allocation, other xattrs, ACLs and stat checks use real scratch files.
"""
import argparse
import ctypes as C
import os
from pathlib import Path
import subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--build', type=Path, required=True)
p.add_argument('--root', type=Path, required=True)
p.add_argument('--provenance', choices=('different', 'target-only', 'clone-only', 'same', 'absent'),
               help='run one provenance model (default: all five)')
a = p.parse_args()
build, root = a.build.resolve(), a.root.resolve()
root.mkdir(parents=True, exist_ok=False)
lib = C.CDLL(None, use_errno=True)
env = {k: v for k, v in os.environ.items()
       if not k.startswith(('GIT_', 'DYLD_', 'APFS_RESHARE_'))}
env.update(GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null',
           GIT_AUTHOR_NAME='Re-share test', GIT_AUTHOR_EMAIL='test@example.com',
           GIT_COMMITTER_NAME='Re-share test', GIT_COMMITTER_EMAIL='test@example.com',
           GIT_EXEC_PATH=str(build), PATH=str(build) + os.pathsep + env['PATH'])


def run(args, extra=None):
    return subprocess.run([str(x) for x in args], env=env | (extra or {}),
                          check=True, capture_output=True)


def git(repo, *args, extra=None):
    return run([build / 'git', '-C', repo, *args], extra)


def usage(path):
    return tuple(map(int, run([build / 't/helper/test-tool', 'reflink',
                              'usage-loop', 1, path]).stdout.split()))


def xattrs(path):
    path = os.fsencode(path)
    size = lib.listxattr(path, None, 0, 0)
    assert size >= 0, C.get_errno()
    names = C.create_string_buffer(size)
    assert lib.listxattr(path, names, size, 0) == size
    result = {}
    for name in names.raw.split(b'\0'):
        if not name or name == b'com.apple.provenance':
            continue
        size = lib.getxattr(path, name, None, 0, 0, 0)
        assert size >= 0, C.get_errno()
        value = C.create_string_buffer(size)
        assert lib.getxattr(path, name, value, size, 0, 0) == size
        result[name] = value.raw
    return result


def setxattr(path, name, value):
    assert not lib.setxattr(os.fsencode(path), name.encode(), value,
                            len(value), 0, 0), C.get_errno()


def metadata(path):
    st = path.stat()
    # The helper includes full nanosecond birthtime, unlike Python's float.
    raw = run([build / 't/helper/test-tool', 'reflink', 'metadata', path]).stdout
    birth = next(line for line in raw.splitlines() if line.startswith(b'birth'))
    acl = run(['ls', '-le', path]).stdout.splitlines()[1:]
    return (st.st_mode, st.st_uid, st.st_gid, st.st_flags,
            st.st_mtime_ns, st.st_atime_ns, birth, xattrs(path), acl)


interposer = root / 'interpose.dylib'
run(['cc', '-Wall', '-Wextra', '-Werror', '-dynamiclib',
     Path(__file__).with_name('apfs-reshare-interpose.c'), '-o', interposer])
source = root / 'source'
source.mkdir()
git(source, 'init', '-q')
git(source, 'config', 'checkout.reflink', 'false')
payload = b're-share provenance oracle\n' * 4096
(source / 'file').write_bytes(payload)
git(source, 'add', 'file')
git(source, 'commit', '-qm', 'fixture')
old = 1_000_000_000_000_000_000
os.utime(source / 'file', ns=(old, old))
git(source, 'update-index', '--refresh')

faults = ('none', 'bare', 'value', 'size', 'missing', 'extra', 'rename', 'quarantine',
          'quarantine-value', 'quarantine-missing',
          'prefix', 'list-error', 'value-error', 'malformed', 'mode', 'mtime', 'acl')
cases = 0
models = [a.provenance] if a.provenance else ('different', 'target-only', 'clone-only', 'same', 'absent')
for provenance in models:
    for fault in faults:
        label = f'{provenance}/{fault}'
        target = root / 'target'
        git(source, 'worktree', 'add', '-q', '--detach', '--no-reflink', target, 'HEAD')
        path = target / 'file'
        if fault != 'bare':
            setxattr(path, 'org.git-scm.reshare', b'value')
            setxattr(path, 'org.git-scm.empty', b'')
            setxattr(path, 'com.apple.provenance.test', b'value')
            run(['chmod', '+a', 'everyone allow read', path])
        if fault in ('quarantine-value', 'quarantine-missing'):
            setxattr(path, 'com.apple.quarantine', b'0081;5f000000;Re-shareOracle;')
        # Future atime prevents ordinary reads from advancing it on atime mounts.
        os.utime(path, ns=(2_000_000_000_000_000_000, old))
        git(target, 'update-index', '--refresh')
        before = metadata(path)
        inode = path.stat().st_ino
        private, allocated = usage(path)
        assert private == allocated and private > 0, label
        extra = dict(DYLD_INSERT_LIBRARIES=str(interposer),
                     APFS_RESHARE_PROVENANCE=provenance, APFS_RESHARE_FAULT=fault)
        reply = git(target, 'worktree', 'reflink', '--porcelain', extra=extra)
        shared = fault in ('none', 'bare')
        expected = b'reshared' if shared else b'skipped'
        assert b'status ' + expected + b'\n' in reply.stdout, (label, reply.stdout, reply.stderr)
        assert b'reshare-oracle 1 ' in reply.stderr, (label, reply.stderr)
        if shared:
            assert b'reason fully-shared\n' in reply.stdout, (label, reply.stdout)
            assert usage(path) == (0, allocated), label
            assert path.stat().st_ino != inode, label
        else:
            assert b'reason metadata-unavailable\n' in reply.stdout, (label, reply.stdout)
            assert usage(path) == (private, allocated), label
            assert path.stat().st_ino == inode, label
        assert metadata(path) == before, label
        assert path.read_bytes() == payload, label
        if shared:
            after = metadata(path)
            second = git(target, 'worktree', 'reflink', '--porcelain', extra=extra)
            assert b'status already-shared\n' in second.stdout, label
            assert b'reshare-oracle 0 0 0' in second.stderr, label
            assert path.stat().st_ino != inode and metadata(path) == after, label
        git(source, 'worktree', 'remove', '--force', target)
        cases += 1
        print('ok', label, flush=True)
print(f'{cases} native re-share provenance/metadata cases passed')
