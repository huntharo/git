#!/usr/bin/env python3
"""Native APFS allocation and clone metadata regression oracle.

Only --root (which must not exist) is written; no existing user trees are scanned.
Run with no other builds/tests active. Use an APFS noatime volume for exact times.
"""
import argparse
import ctypes as C
import os
from pathlib import Path
import struct
import subprocess
import time

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--after', type=Path, required=True)
p.add_argument('--root', type=Path, required=True)
a = p.parse_args()
builds = {'after': a.after.resolve()}
root = a.root.resolve()
root.mkdir(parents=True, exist_ok=False)
lib = C.CDLL(None, use_errno=True)
env = {k: v for k, v in os.environ.items() if not k.startswith(('GIT_', 'DYLD_', 'APFS_TEST_'))}
env.update(GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null',
           GIT_AUTHOR_NAME='APFS test', GIT_AUTHOR_EMAIL='test@example.com',
           GIT_COMMITTER_NAME='APFS test', GIT_COMMITTER_EMAIL='test@example.com')


class Attr(C.Structure):
    _fields_ = [('count', C.c_uint16), ('reserved', C.c_uint16)] + [
        (n, C.c_uint32) for n in ('common', 'vol', 'dir', 'file', 'fork')]


def run(args, extra=None, mask=0o022):
    return subprocess.run([str(x) for x in args], env=env | (extra or {}),
                          check=True, capture_output=True, umask=mask)


def git(build, repo, *args, trace=None):
    b = builds[build]
    extra = dict(GIT_EXEC_PATH=str(b), PATH=str(b) + os.pathsep + env['PATH'])
    if trace:
        extra['GIT_TRACE2_EVENT'] = str(trace)
    return run([b / 'git', '-C', repo, *args], extra).stdout


def tool(build, repetitions, files, extra=None):
    directory = builds[build]
    return run([directory / 't/helper/test-tool', 'reflink', 'usage-loop',
                repetitions, *files], extra)


def attrs(path, common=0, fork=0, size=128):
    fd = os.open(path, os.O_RDONLY)
    try:
        al = Attr(5, 0, 0x80000000 | common, 0, 0, 0, fork)
        buf = C.create_string_buffer(size)
        assert not lib.fgetattrlist(fd, C.byref(al), buf, size, 0x20), C.get_errno()
        return buf.raw
    finally:
        os.close(fd)


def oracle(path):
    # The original unconditional private-size request; allocation from fstat.
    return struct.unpack_from('=q', attrs(path, fork=8), 24)[0], path.stat().st_blocks * 512


def setxattr(path, name, value):
    assert not lib.setxattr(os.fsencode(path), name.encode(), value, len(value), 0, 0), C.get_errno()


def xattrs(path):
    path = os.fsencode(path)
    n = lib.listxattr(path, None, 0, 0)
    assert n >= 0, C.get_errno()
    buf = C.create_string_buffer(n)
    assert lib.listxattr(path, buf, n, 0) == n
    out = {}
    for name in buf.raw.split(b'\0'):
        if not name or name == b'com.apple.provenance':
            continue
        n = lib.getxattr(path, name, None, 0, 0, 0)
        assert n >= 0
        value = C.create_string_buffer(n)
        assert lib.getxattr(path, name, value, n, 0, 0) == n
        out[name.decode()] = value.raw.hex()
    return out


def clone(src, dst):
    assert not lib.clonefile(os.fsencode(src), os.fsencode(dst), 0), C.get_errno()


def times(path):
    # Birth, modification, access times, each with full nanosecond precision.
    return struct.unpack_from('=6q', attrs(path, common=0x200 | 0x400 | 0x1000), 24)


# Generated native oracle: full/modified clones, holes, hardlinks, empty files,
# resource forks, removed peers, and ordinary files.
fixture = root / 'oracle'
fixture.mkdir()
for i in range(100):
    source, target = fixture / f'p{i}', fixture / f'c{i}'
    source.write_bytes(bytes([i]) * (i * 1901))
    clone(source, target)
    if i % 3 == 0:
        with target.open('r+b') as f:
            f.seek(i * 70)
            f.write(b'modified')
    if i % 7 == 0:
        setxattr(source, 'com.apple.ResourceFork', b'resource' * 2000)
    if i % 9 == 0:
        os.link(source, fixture / f'h{i}')
    if i % 11 == 0:
        with source.open('r+b') as f:
            f.truncate(8 * 1024 * 1024)
    if i % 13 == 0:
        source.unlink()
for path in fixture.iterdir():
    expected = oracle(path)
    for build in builds:
        assert tuple(map(int, tool(build, 1, [path]).stdout.split())) == expected, path.name
print('native oracle passed', len(list(fixture.iterdir())), flush=True)

# Exercise Git's descriptor clone repair itself, including non-default umasks.
repair_source = root / 'repair-source'
repair_source.mkdir()
git('after', repair_source, 'init', '-q')
git('after', repair_source, 'config', 'checkout.reflink', 'false')
for name, mode in (('plain', 0o600), ('executable', 0o700)):
    path = repair_source / name
    path.write_bytes((name.encode() + b' source data\n') * 1000)
    path.chmod(mode)
    setxattr(path, 'org.git-scm.metadata-test', b'must not leak')
    os.utime(path, ns=(1_000_000_000, 1_000_000_000))
git('after', repair_source, 'add', '.')
git('after', repair_source, 'commit', '-qm', 'clone repair')
time.sleep(1.05)
git('after', repair_source, 'update-index', '--refresh', '--force-write-index')
for mask in (0o022, 0o077, 0o002, 0o027):
    target = root / ('repair-mask-' + str(mask))
    started = time.time_ns()
    run([builds['after'] / 'git', '-C', repair_source, 'worktree', 'add', '-q',
         '--detach', '--reflink', target, 'HEAD'],
        dict(GIT_EXEC_PATH=str(builds['after']), PATH=str(builds['after']) + os.pathsep + env['PATH']),
        mask=mask)
    ended = time.time_ns()
    for name, mode in (('plain', 0o666), ('executable', 0o777)):
        path = target / name
        st = path.stat()
        assert st.st_mode & 0o777 == mode & ~mask
        bsec, bnsec, msec, mnsec, asec, ansec = times(path)
        assert (bsec, bnsec) == (msec, mnsec) == (asec, ansec)
        assert started <= bsec * 10**9 + bnsec <= ended
        assert not xattrs(path)
        assert path.read_bytes() == (repair_source / name).read_bytes()
        assert oracle(path)[0] == 0
    git('after', repair_source, 'worktree', 'remove', '--force', target)
print('clone repair mode/time/xattr checks passed', flush=True)
