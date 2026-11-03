#!/usr/bin/env python3
"""Content-asserting tests of an extracted app runtime; never edits its payload."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

from runtime import write_json

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('runtime', type=Path)
p.add_argument('--test-tool', type=Path, required=True)
p.add_argument('--require-sharing', action='store_true')
p.add_argument('--https', action='store_true')
p.add_argument('--report', type=Path, required=True)
p.add_argument('--root', type=Path, help='Place test files on this filesystem')
a = p.parse_args()
runtime = a.runtime.resolve()
git = runtime / 'bin/git'
helper = a.test_tool.resolve()
env = {k: v for k, v in os.environ.items() if not k.startswith(('GIT_', 'DYLD_'))}
env.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_ATTR_NOSYSTEM='1', GIT_TERMINAL_PROMPT='0',
           LC_ALL='C', PATH=str(runtime / 'bin') + ':/usr/bin:/bin:/usr/sbin:/sbin')


def cmd(args, cwd, input=None, extra=None):
    return subprocess.check_output([str(x) for x in args], cwd=cwd, input=input,
                                   env=dict(env, **(extra or {})), stderr=subprocess.PIPE)


def g(cwd, *args, **kw):
    return cmd([git, *args], cwd, **kw)


results = []
with tempfile.TemporaryDirectory(prefix='pwrgit-runtime-smoke-', dir=a.root) as tmp:
    root = Path(tmp)
    for workers in (1, 8):
        base = root / str(workers)
        base.mkdir()
        src = base / 'src'
        g(base, 'init', '-q', src)
        for key, value in [('user.name', 'Runtime smoke'), ('user.email', 'runtime@example.invalid'),
                           ('commit.gpgsign', 'false'), ('checkout.workers', str(workers)),
                           ('checkout.thresholdForParallelism', '0')]:
            g(src, 'config', key, value)
        g(src, 'lfs', 'install', '--local')
        g(src, 'lfs', 'track', '*.lfs')
        with (src / '.gitattributes').open('a') as out:
            out.write('converted.txt text eol=crlf\nexternal.txt filter=marker\n')
        # Exercise an external filter independently of deterministic EOL conversion.
        g(src, 'config', 'filter.marker.smudge', 'sed s/canonical/expanded/g')
        g(src, 'config', 'filter.marker.clean', 'sed s/expanded/canonical/g')
        data = os.urandom(1024 * 1024)
        lfs_data = os.urandom(65536)
        (src / 'payload').write_bytes(data)
        (src / 'local.lfs').write_bytes(lfs_data)
        (src / 'converted.txt').write_bytes(b'first\nsecond\n')
        (src / 'external.txt').write_bytes(b'canonical\n')
        (src / 'dir').mkdir()
        (src / 'dir/selected').write_bytes(b'sparse selection\n')
        g(src, 'add', '.')
        g(src, 'commit', '-qm', 'runtime smoke')
        # Git's ordinary index stat trust deliberately stays in force.
        time.sleep(1.1)
        g(src, 'update-index', '--refresh', '--force-write-index')
        wt = base / 'wt'
        trace = base / 'trace.json'
        g(src, 'worktree', 'add', '-q', '--detach', wt, extra={'GIT_TRACE2_EVENT': str(trace)})
        assert (wt / 'payload').read_bytes() == data
        assert (wt / 'local.lfs').read_bytes() == lfs_data
        assert (wt / 'converted.txt').read_bytes() == b'first\r\nsecond\r\n'
        assert (wt / 'external.txt').read_bytes() == b'expanded\n'
        assert g(wt, 'show', 'HEAD:local.lfs').startswith(b'version https://git-lfs.github.com/spec/v1\n')
        assert not g(wt, 'status', '--porcelain')
        sharing = subprocess.run([str(helper), 'reflink', 'shared', str(src / 'payload'), str(wt / 'payload')],
                                 env=env, capture_output=True).returncode == 0
        if a.require_sharing:
            assert sharing, 'Expected actual filesystem block sharing'
        inode = (wt / 'payload').stat().st_ino
        for args in [('status', '--porcelain'), ('reset', '-q', '--hard'), ('checkout', '--', '.'),
                     ('restore', '.'), ('checkout-index', '-af')]:
            g(wt, '-c', 'checkout.reflink=false', *args)
        assert (wt / 'payload').stat().st_ino == inode
        if sharing:
            cmd([helper, 'reflink', 'shared', src / 'payload', wt / 'payload'], base)
        (src / 'payload').write_bytes(b'D' + data[1:])
        dirty = base / 'dirty'
        g(src, 'worktree', 'add', '-q', '--detach', dirty)
        assert (dirty / 'payload').read_bytes() == data
        assert (src / 'payload').read_bytes() == b'D' + data[1:]
        (wt / 'payload').write_bytes(b'W' + data[1:])
        assert (dirty / 'payload').read_bytes() == data
        # A disabled clone exercises ordinary fallback, even on a reflink FS.
        fallback = base / 'fallback'
        g(src, '-c', 'checkout.reflink=false', 'worktree', 'add', '-q', '--detach', fallback)
        assert (fallback / 'payload').read_bytes() == data
        sparse = base / 'sparse'
        g(src, 'clone', '-q', '--no-checkout', src, sparse)
        g(sparse, 'sparse-checkout', 'set', 'dir')
        g(sparse, '-c', 'filter.lfs.smudge=git-lfs smudge --skip',
          '-c', 'filter.lfs.process=git-lfs filter-process --skip', 'checkout', '-q', 'HEAD')
        assert (sparse / 'dir/selected').read_bytes() == b'sparse selection\n'
        sub = base / 'sub'
        g(base, 'init', '-q', sub)
        (sub / 'nested').write_bytes(b'submodule bytes\n')
        g(sub, 'add', '.')
        g(sub, '-c', 'user.name=Smoke', '-c', 'user.email=smoke@example.invalid',
          '-c', 'commit.gpgsign=false', 'commit', '-qm', 'submodule')
        g(src, '-c', 'protocol.file.allow=always', 'submodule', 'add', '-q', sub, 'nested-repo')
        assert (src / 'nested-repo/nested').read_bytes() == b'submodule bytes\n'
        events = [json.loads(line) for line in trace.read_text().splitlines()]
        counts = {e['name']: e['count'] for e in events if e.get('event') == 'counter' and e.get('category') == 'reflink'}
        results.append(dict(workers=workers, real_block_sharing=sharing, trace_counters=counts,
                            lfs_smudge_and_pointer=True, crlf=True, external_filter=True,
                            dirty_donor=True, changed_contents_independent=True, disabled_fallback=True,
                            noop_preserved=True, sparse=True, submodule=True,
                            payload_sha256=hashlib.sha256(data).hexdigest()))
    if a.https:
        assert g(root, '-c', 'credential.helper=', 'ls-remote', 'https://github.com/huntharo/git.git', 'HEAD')
    write_json(a.report, dict(version=g(root, '--version').decode().strip(), https=a.https, cases=results))
print(json.dumps({'report': str(a.report), 'workers': [1, 8], 'https': a.https, 'passed': True}))
