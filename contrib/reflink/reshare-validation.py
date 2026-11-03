#!/usr/bin/env python3
"""Independent file-data/metadata and real-binary interop evidence.

Use a new --root on the filesystem being tested. All repository settings are
fixture-local. Timings belong in the separate reshare benchmark.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import struct
import subprocess
import time

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--git', required=True)
p.add_argument('--tool', required=True)
p.add_argument('--ordinary', action='append', required=True)
p.add_argument('--root', required=True)
p.add_argument('--lfs', action='store_true', help='also exercise the installed git-lfs offline')
p.add_argument('--historical', action='store_true', help='also preserve stale ident/encoding representations')
a = p.parse_args()
candidate, tool = str(Path(a.git).resolve()), str(Path(a.tool).resolve())
root = Path(a.root).resolve()
root.mkdir(parents=True, exist_ok=False)
env = os.environ.copy()
for key in list(env):
    if key.startswith('GIT_'):
        del env[key]
env.update(GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null',
           GIT_AUTHOR_NAME='Reflink test', GIT_AUTHOR_EMAIL='test@example.com',
           GIT_COMMITTER_NAME='Reflink test', GIT_COMMITTER_EMAIL='test@example.com')


def run(args, cwd=None, extra=None):
    try:
        return subprocess.check_output([str(x) for x in args], cwd=cwd,
                                       env=env | (extra or {}), stderr=subprocess.PIPE)
    except subprocess.CalledProcessError as e:
        raise RuntimeError((args, e.stderr.decode(errors='replace'))) from e


def git(repo, *args, binary=candidate, extra=None):
    child_env = {'PATH': str(Path(binary).parent) + os.pathsep + env['PATH']}
    if binary == candidate:
        child_env['GIT_EXEC_PATH'] = str(Path(candidate).parent)
    else:
        child_env['GIT_EXEC_PATH'] = run([binary, '--exec-path']).decode().strip()
    return run([binary, '-C', repo, *args], extra=child_env | (extra or {}))


def stable(repo):
    for path in repo.iterdir():
        if path.is_file() and path.name != '.git':
            st = path.stat()
            os.utime(path, ns=(st.st_atime_ns, st.st_mtime_ns - 60_000_000_000))
    git(repo, 'update-index', '--refresh', '--force-write-index')


def usage(repo):
    private, allocated, files, shared = map(int, run([tool, 'reflink', 'private-bytes', repo]).split())
    return dict(private=private, allocated=allocated, files=files, shared=shared)


def snapshot(repo):
    out = {}
    for path in sorted(repo.iterdir()):
        if not path.is_file() or path.name == '.git':
            continue
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        st = path.stat()
        if platform.system() == 'Darwin':
            attrs = {n: b''.join(run(['xattr', '-px', n, path]).split()).decode()
                     for n in run(['xattr', path]).decode().splitlines()}
        else:
            attrs = {n: os.getxattr(path, n).hex() for n in os.listxattr(path)}
        acl = run(['ls', '-le', path]).decode().splitlines()[1:] if platform.system() == 'Darwin' else []
        out[path.name] = dict(mode=st.st_mode, uid=st.st_uid, gid=st.st_gid,
                              size=st.st_size, atime=st.st_atime_ns, mtime=st.st_mtime_ns,
                              ino=st.st_ino, ctime=st.st_ctime_ns, xattrs=attrs, acl=acl,
                              sha256=digest)
    return out


def assert_preserved(before, after, replacement):
    for name in before:
        for key in before[name]:
            if replacement and key in ('ino', 'ctime'):
                continue
            assert before[name][key] == after[name][key], (name, key, before[name], after[name])


def trace_summary(path):
    return {x['key']: x.get('value') for x in map(json.loads, path.read_text().splitlines())
            if x.get('event') == 'data' and x.get('category') == 'reflink-reshare'}


rows = []
for ordinary in a.ordinary:
    ordinary = str(Path(ordinary).resolve())
    for workers in (1, 8):
        for operation in ('command', 'hard-reset'):
            case = root / f'{len(rows):02d}'
            case.mkdir()
            source, target = case / 'source', case / 'target'
            run([candidate, 'init', '-q', source])
            git(source, 'config', 'checkout.reflink', 'false')
            git(source, 'config', 'checkout.workers', str(workers))
            git(source, 'config', 'checkout.thresholdForParallelism', '0')
            (source / '.gitattributes').write_text('crlf text eol=crlf\n')
            names = ('plain', 'crlf', 'executable') + tuple(f'extra{i}' for i in range(9))
            for i, name in enumerate(names):
                (source / name).write_bytes((f'line {i} abcdefghijklmnopqrstuvwxyz\n'.encode() * 10000))
            (source / 'executable').chmod(0o755)
            git(source, 'add', '.')
            git(source, 'commit', '-qm', 'A')
            base = git(source, 'rev-parse', 'HEAD').decode().strip()
            for name in names:
                with (source / name).open('ab') as f:
                    f.write(b'changed\n')
            git(source, 'commit', '-qam', 'B')
            other = git(source, 'rev-parse', 'HEAD').decode().strip()
            git(source, 'reset', '-q', '--hard', base)
            stable(source)
            git(source, 'worktree', 'add', '-q', '--detach', '--no-reflink', target, base)
            ordinary_workers = []
            for step, commit in enumerate((other, base)):
                ordinary_trace = case / f'ordinary-{step}.trace'
                git(target, '-c', f'checkout.workers={workers}', '-c', 'checkout.reflink=false',
                    'reset', '-q', '--hard', commit, binary=ordinary,
                    extra={'GIT_TRACE2_EVENT': str(ordinary_trace)})
                started = sum(x.get('event') == 'child_start' and
                              any('checkout--worker' in arg for arg in x.get('argv', []))
                              for x in map(json.loads, ordinary_trace.read_text().splitlines()))
                assert started == (8 if workers == 8 else 0), started
                ordinary_workers.append(started)
            # Ordinary refresh after natural aging avoids inventing index/stat state.
            time.sleep(1.05)
            git(target, 'update-index', '--refresh', '--force-write-index')
            attr = 'com.pwrgit.test' if platform.system() == 'Darwin' else 'user.pwrgit.test'
            if platform.system() == 'Darwin':
                run(['xattr', '-wx', attr, b'target metadata'.hex(), target / 'plain'])
                run(['xattr', '-wx', attr + '.donor', b'must not leak'.hex(), source / 'plain'])
            else:
                os.setxattr(target / 'plain', attr, b'target metadata')
                os.setxattr(source / 'plain', attr + '.donor', b'must not leak')
            posix_acl = 'not applicable'
            if platform.system() == 'Linux':
                acl = struct.pack('<I', 2) + b''.join(struct.pack('<HHI', tag, perm, ident)
                    for tag, perm, ident in ((1, 6, 0xffffffff), (2, 4, 1001),
                                            (4, 4, 0xffffffff), (16, 4, 0xffffffff), (32, 4, 0xffffffff)))
                try:
                    os.setxattr(target / 'plain', 'system.posix_acl_access', acl)
                    posix_acl = 'set and verified in xattr snapshot'
                except OSError as error:
                    posix_acl = f'unavailable errno {error.errno}'
            if platform.system() == 'Darwin':
                run(['chmod', '+a', 'everyone allow read', target / 'plain'])
            git(source, 'update-index', '--refresh')
            git(target, 'update-index', '--refresh', '--force-write-index')
            before, before_usage = snapshot(target), usage(target)
            assert before_usage['private'] > 0
            trace = case / 'first.trace'
            args = ['worktree', 'reflink', '--porcelain'] if operation == 'command' else ['reset', '-q', '--hard']
            output = git(target, '-c', f'checkout.workers={workers}', '-c', 'checkout.reflink=true',
                         *args, extra={'GIT_TRACE2_EVENT': str(trace)})
            (case / 'porcelain').write_bytes(output)
            after, after_usage = snapshot(target), usage(target)
            assert_preserved(before, after, platform.system() == 'Darwin')
            assert after_usage['private'] == 0, after_usage
            first_counts = trace_summary(trace)
            assert int(first_counts['content-checked']) == 0, first_counts
            trace = case / 'second.trace'
            git(target, '-c', 'checkout.reflink=true', *args,
                extra={'GIT_TRACE2_EVENT': str(trace)})
            assert_preserved(after, snapshot(target), False)
            second_counts = trace_summary(trace)
            for key in ('native-attempts', 'clone-attempts', 'content-checked', 'userspace-compared'):
                assert int(second_counts[key]) == 0, second_counts
            # Unpatched writers make changed files private again; disabled control retains it.
            for commit in (other, base):
                git(target, '-c', 'checkout.reflink=false', 'reset', '-q', '--hard', commit, binary=ordinary)
            private = usage(target)
            git(target, '-c', 'checkout.reflink=false', 'reset', '-q', '--hard')
            assert usage(target) == private
            rows.append(dict(ordinary=ordinary, version=run([ordinary, '--version']).decode().strip(),
                             ordinary_sha256=hashlib.sha256(Path(ordinary).read_bytes()).hexdigest(),
                             ordinary_checkout_workers=ordinary_workers,
                             workers=workers, operation=operation, before=before_usage, after=after_usage,
                             first_counts=first_counts, second_counts=second_counts,
                             metadata_preserved=True, posix_acl=posix_acl, disabled_control=private))
            (root / 'results.json').write_text(json.dumps(dict(platform=platform.platform(),
                candidate=candidate, candidate_sha256=hashlib.sha256(Path(candidate).read_bytes()).hexdigest(),
                cases=rows), indent=2) + '\n')
if a.historical:
    historical = []
    for conversion in ('ident', 'encoding'):
        for donor in ('historical', 'fresh'):
            source, target = root / f'{conversion}-{donor}-source', root / f'{conversion}-{donor}-target'
            run([candidate, 'init', '-q', source])
            git(source, 'config', 'checkout.reflink', 'false')
            payload = b'$Id$\n' + b'ordinary line\n' * 6000 if conversion == 'ident' else ('caf\u00e9\n' * 16000).encode()
            (source / 'file').write_bytes(payload)
            git(source, 'add', '.')
            git(source, 'commit', '-qm', 'old representation')
            stable(source)
            git(source, 'worktree', 'add', '-q', '--detach', '--no-reflink', target, 'HEAD')
            stable(target)
            rule = 'ident' if conversion == 'ident' else 'working-tree-encoding=UTF-16LE'
            (source / '.gitattributes').write_text('file ' + rule + '\n')
            git(source, 'add', '.gitattributes')
            git(source, 'commit', '-qm', 'attributes only')
            git(target, 'reset', '-q', '--hard', git(source, 'rev-parse', 'HEAD').decode().strip())
            assert (target / 'file').read_bytes() == payload
            assert git(target, 'status', '--porcelain', '--untracked-files=no') == b''
            if donor == 'fresh':
                (source / 'file').unlink()
                git(source, 'checkout-index', '-afu')
                stable(source)
                assert (source / 'file').read_bytes() != payload
            before = usage(target / 'file')
            trace = root / f'{conversion}-{donor}.trace'
            out = git(target, 'worktree', 'reflink', '--porcelain', extra={'GIT_TRACE2_EVENT': str(trace)})
            assert (target / 'file').read_bytes() == payload
            after = usage(target / 'file')
            assert after['private'] == (0 if donor == 'historical' else before['private'])
            if donor == 'fresh':
                assert b'reason representation-differs' in out
            git(target, '-c', 'checkout.reflink=true', 'reset', '-q', '--hard')
            assert (target / 'file').read_bytes() == payload
            assert git(target, 'status', '--porcelain', '--untracked-files=no') == b''
            historical.append(dict(conversion=conversion, donor=donor, bytes_preserved=True,
                                   before=before, after=after, counts=trace_summary(trace)))
    (root / 'historical-results.json').write_text(json.dumps(historical, indent=2) + '\n')

if a.lfs:
    source = root / 'lfs-source'
    run([candidate, 'init', '-q', source])
    git(source, 'config', 'checkout.reflink', 'false')
    git(source, 'lfs', 'install', '--local')
    (source / '.gitattributes').write_text('*.bin filter=lfs diff=lfs merge=lfs -text\n')
    payload = b'LFS actual checkout bytes\x00\n' * 20000
    (source / 'payload.bin').write_bytes(payload)
    git(source, 'add', '.')
    git(source, 'commit', '-qm', 'local offline LFS object')
    time.sleep(1.05)
    git(source, 'update-index', '--refresh', '--force-write-index')
    lfs_rows = []
    for workers in (1, 8):
        for operation in ('command', 'hard-reset'):
            target = root / f'lfs-{workers}-{operation}'
            git(source, '-c', f'checkout.workers={workers}', '-c', 'checkout.thresholdForParallelism=0',
                'worktree', 'add', '-q', '--detach', '--no-reflink', target, 'HEAD')
            assert (target / 'payload.bin').read_bytes() == payload
            time.sleep(1.05)
            git(target, 'update-index', '--refresh', '--force-write-index')
            before = usage(target)
            trace = root / f'lfs-{workers}-{operation}.trace'
            args = ['worktree', 'reflink', '--porcelain'] if operation == 'command' else ['reset', '-q', '--hard']
            git(target, '-c', 'checkout.reflink=true', *args, extra={'GIT_TRACE2_EVENT': str(trace)})
            assert (target / 'payload.bin').read_bytes() == payload
            after = usage(target)
            assert before['private'] > 0 and after['private'] == 0
            counts = trace_summary(trace)
            assert counts['content-checked'] == '0' and 'filter-process' not in trace.read_text()
            with (target / 'payload.bin').open('ab') as f:
                f.write(b'dirty\n')
            expected = (target / 'payload.bin').read_bytes()
            git(target, 'worktree', 'reflink')
            assert (target / 'payload.bin').read_bytes() == expected
            assert b'M payload.bin' in git(target, 'status', '--porcelain')
            lfs_rows.append(dict(workers=workers, operation=operation, before=before, after=after,
                                 payload_bytes=len(payload), counts=counts, dirty_preserved=True))
    (root / 'lfs-results.json').write_text(json.dumps(dict(version=git(source, 'lfs', 'version').decode().strip(),
                                                        cases=lfs_rows), indent=2) + '\n')
print(json.dumps(rows, indent=2))
