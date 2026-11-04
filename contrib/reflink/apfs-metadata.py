#!/usr/bin/env python3
"""Small-tree APFS oracle, fault tests and paired Git benchmarks.

Build before/after with identical options and this revision's test-reflink.c.
Only --root (which must not exist) is written; no existing user trees are scanned.
Run with no other builds/tests active. Use an APFS noatime volume for exact times.
"""
import argparse
import ctypes as C
import hashlib
import json
import os
from pathlib import Path
import platform
import resource
import statistics
import struct
import subprocess
import time

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--before', type=Path)
p.add_argument('--validate-only', action='store_true')
p.add_argument('--after', type=Path, required=True)
p.add_argument('--metadata-candidate', type=Path, help='optional build with the diagnostic query patch')
p.add_argument('--root', type=Path, required=True)
p.add_argument('--repetitions', type=int, default=12)
a = p.parse_args()
if not a.before:
    if not a.validate_only:
        p.error('--before is required for benchmarking')
    a.before = a.after
builds = {k: getattr(a, k).resolve() for k in ('before', 'after')}
candidate = a.metadata_candidate.resolve() if a.metadata_candidate else None
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
    directory = candidate if build == 'query-candidate' else builds[build]
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


result = dict(platform=platform.platform(), repetitions=a.repetitions, samples=[],
              started_utc=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()), initial_load=os.getloadavg(),
              binaries={k: hashlib.sha256((v / 'git').read_bytes()).hexdigest()
                        for k, v in builds.items()})
if candidate:
    result['query_candidate_binary'] = hashlib.sha256((candidate / 'git').read_bytes()).hexdigest()
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
    for build in (list(builds) + (['query-candidate'] if candidate else [])):
        assert tuple(map(int, tool(build, 1, [path]).stdout.split())) == expected, path.name
result['oracle_files'] = len(list(fixture.iterdir()))
print('native oracle passed', result['oracle_files'], flush=True)

interposer = root / 'interpose.dylib'
run(['cc', '-Wall', '-Wextra', '-Werror', '-dynamiclib',
     Path(__file__).with_name('apfs-metadata-interpose.c'), '-o', interposer])
if candidate:
    faults = ['unsupported', 'device', 'inode', 'volume', 'clone', 'allocation', 'flags', 'references']
    faults += [f'length:{i}' for i in range(68)] + ['length:69']
    faults += [f'missing:{bit}' for bit in (1, 25, 31, 106, 134, 136, 137, 140)]
    for fault in [None] + faults:
        extra = dict(DYLD_INSERT_LIBRARIES=str(interposer))
        if fault:
            extra['APFS_TEST_FAULT'] = fault
        reply = tool('query-candidate', 1, [fixture / 'c1'], extra)
        assert tuple(map(int, reply.stdout.split())) == oracle(fixture / 'c1'), fault
        assert b'apfs-queries 1 ' + (b'1' if fault else b'0') in reply.stderr, (fault, reply.stderr)
    # Prove that the regression check distinguishes the original implementation.
    reply = tool('before', 1, [fixture / 'c1'], dict(DYLD_INSERT_LIBRARIES=str(interposer)))
    if builds['before'] != builds['after']:
        assert b'apfs-queries 0 1' in reply.stderr
    result['fallback_cases'] = len(faults)
    print('fault guards passed', len(faults), flush=True)
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
result['clone_repair_umasks'] = ['022', '077', '002', '027']
print('clone repair mode/time/xattr checks passed', flush=True)
if a.validate_only:
    (root / 'results.json').write_text(json.dumps(result, indent=2) + '\n')
    raise SystemExit(0)

# Only public, tracked files from this Git source checkout, capped at 1536 files.
names = git('after', builds['after'], 'ls-files', '-z').split(b'\0')
names = [os.fsdecode(n) for n in names if n and Path(os.fsdecode(n)).suffix in ('.c', '.h', '.sh')][:1536]
fixtures = {}
for kind in ('source', 'dependencies'):
    source = root / (kind + '-source')
    source.mkdir()
    git('before', source, 'init', '-q')
    git('before', source, 'config', 'checkout.reflink', 'false')
    git('before', source, 'config', 'core.hooksPath', '/dev/null')
    entries = names if kind == 'source' else [f'pkg{i // 24}/file{i}.js' for i in range(2400)]
    for i, name in enumerate(entries):
        path = source / name
        path.parent.mkdir(parents=True, exist_ok=True)
        if kind == 'source':
            original = builds['after'] / name
            path.write_bytes(original.read_bytes())
            path.chmod(original.stat().st_mode & 0o777)
        else:
            path.write_bytes((f'export const value{i} = "dependency";\n'.encode() * (4 + i % 220)))
            path.chmod(0o755 if i % 20 == 0 else 0o644)
        if i % 100 == 0:
            setxattr(path, 'org.git-scm.metadata-test', b'donor only')
    (source / 'empty').touch()
    os.symlink(entries[0], source / 'link')
    git('before', source, 'add', '.')
    git('before', source, 'commit', '-qm', 'fixture')
    # Natural index refresh after aging; no invented index-stat tuples.
    time.sleep(1.05)
    git('before', source, 'update-index', '--refresh', '--force-write-index')
    regular = [name for name in entries if (source / name).stat().st_size]
    fixtures[kind] = source, entries + ['empty', 'link'], regular


def measure(fn):
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    start = time.perf_counter_ns()
    value = fn()
    wall = (time.perf_counter_ns() - start) / 1e6
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    return value, dict(wall_ms=wall, user_ms=(after.ru_utime-before.ru_utime)*1000,
                       system_ms=(after.ru_stime-before.ru_stime)*1000)


def verify(source, target, names, shared, start, end):
    actual = {str(p.relative_to(target)) for p in target.rglob('*')
              if (p.is_file() or p.is_symlink()) and p.relative_to(target) != Path('.git')}
    assert actual == set(names), (actual - set(names), set(names) - actual)
    for name in names:
        src, dst = source / name, target / name
        st = dst.lstat()
        if src.is_symlink():
            assert dst.is_symlink() and os.readlink(dst) == os.readlink(src)
            continue
        assert (st.st_mode & 0o777) == ((0o777 if src.stat().st_mode & 0o100 else 0o666) & ~0o022), name
        assert (st.st_uid, st.st_gid) == (os.getuid(), os.getgid()), name
        bsec, bnsec, msec, mnsec, asec, ansec = times(dst)
        for stamp in (bsec * 10**9 + bnsec, msec * 10**9 + mnsec, asec * 10**9 + ansec):
            assert start <= stamp <= end, (name, stamp, start, end)
        if shared and st.st_size:
            assert (bsec, bnsec) == (msec, mnsec) == (asec, ansec), name
        assert not xattrs(dst), name
        assert dst.read_bytes() == src.read_bytes(), name
        private, allocated = oracle(dst)
        if st.st_size:
            assert private == (0 if shared else allocated), (name, private, allocated)
        # Reading verification on noatime must leave all three times unchanged.
        assert times(dst) == (bsec, bnsec, msec, mnsec, asec, ansec), name


# Metadata-only queries on already opened descriptors: 20 passes over <=256 files.
for kind, (source, names, regular) in fixtures.items():
    shared = root / (kind + '-shared')
    git('after', source, 'worktree', 'add', '-q', '--detach', '--reflink', shared, 'HEAD')
    ordinary = root / (kind + '-ordinary')
    ordinary.mkdir()
    for name in regular[:256]:
        path = ordinary / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes((source / name).read_bytes())
        assert oracle(path)[0] == oracle(path)[1] > 0
    for mode, tree in (('ordinary', ordinary), ('shared', shared)):
        files = [tree / name for name in regular[:256]]
        for rep in range(-1, a.repetitions):
            order = ['before', 'after'] + (['query-candidate'] if candidate else [])
            for build in (order if rep % 2 == 0 else list(reversed(order))):
                reply, timing = measure(lambda: tool(build, 20, files))
                expected = tuple(sum(oracle(f)[i] for f in files) * 20 for i in (0, 1))
                assert tuple(map(int, reply.stdout.split())) == expected
                if rep >= 0:
                    result['samples'].append(dict(kind=kind, operation='metadata-'+mode,
                                                  build=build, rep=rep, **timing))
    for build in builds:
        target = root / ('repair-' + build)
        reply = run([builds[build] / 'git', '-C', source, '-c', 'checkout.workers=1',
            'worktree', 'add', '-q', '--detach', '--reflink', target, 'HEAD'],
            dict(DYLD_INSERT_LIBRARIES=str(interposer), GIT_EXEC_PATH=str(builds[build]),
                 PATH=str(builds[build]) + os.pathsep + env['PATH']))
        counts = [line for line in reply.stderr.decode().splitlines() if line.startswith('apfs-repairs ')]
        result.setdefault('repair_syscalls', []).append(dict(kind=kind, build=build, counts=counts))
        git('after', source, 'worktree', 'remove', '--force', target)
    # Full checkout and metadata-only already-shared repair, paired and alternating.
    for operation in ('checkout-copy', 'checkout-cow', 'reshare-shared'):
        for rep in range(-1, a.repetitions):
            for build in (('before', 'after') if rep % 2 == 0 else ('after', 'before')):
                target = root / 'checkout'
                trace = root / 'trace.json'
                trace.unlink(missing_ok=True)
                start = time.time_ns()
                if operation == 'reshare-shared':
                    reply, timing = measure(lambda: git(build, shared, 'worktree', 'reflink', '--porcelain'))
                    assert f'already-shared {len(regular)}'.encode() in reply
                else:
                    cow = operation == 'checkout-cow'
                    _, timing = measure(lambda: git(build, source, '-c', 'checkout.workers=1', 'worktree',
                        'add', '-q', '--detach', '--reflink' if cow else '--no-reflink', target, 'HEAD', trace=trace))
                    end = time.time_ns()
                    verify(source, target, names, cow, start, end)
                    counters = {e['name']: e['count'] for e in map(json.loads, trace.read_text().splitlines())
                                if e.get('event') == 'counter' and e.get('category') == 'reflink'}
                    if cow:
                        assert counters.get('cloned') == len(regular), counters
                        assert not counters.get('clone-failed') and not counters.get('verify-failed'), counters
                    git('after', source, 'worktree', 'remove', '--force', target)
                if rep >= 0:
                    result['samples'].append(dict(kind=kind, operation=operation, build=build, rep=rep, **timing))
                (root / 'results.json').write_text(json.dumps(result, indent=2) + '\n')
        print(kind, operation, 'passed', flush=True)
    result.setdefault('fixtures', {})[kind] = dict(files=len(names), nonempty=len(regular),
        bytes=sum((source / n).stat().st_size for n in regular))
result['summary'] = []
for kind in fixtures:
    for operation in sorted({s['operation'] for s in result['samples']}):
        row = dict(kind=kind, operation=operation)
        for build in (list(builds) + (['query-candidate'] if candidate else [])):
            cells = [s for s in result['samples'] if (s['kind'], s['operation'], s['build']) == (kind, operation, build)]
            if not cells:
                continue
            row[build] = {metric: dict(median=statistics.median(s[metric] for s in cells),
                minimum=min(s[metric] for s in cells), maximum=max(s[metric] for s in cells))
                for metric in ('wall_ms', 'user_ms', 'system_ms')}
        result['summary'].append(row)
result['final_load'] = os.getloadavg()
result['finished_utc'] = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
(root / 'results.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result['summary'], indent=2))
