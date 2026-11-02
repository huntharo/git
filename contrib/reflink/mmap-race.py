#!/usr/bin/env python3
"""Reproduce the stat trust boundary with an already-dirtied writable mmap.

The root must not exist. Results include ordinary checkout and PR #1 controls.
"""
import argparse
import json
import mmap
import os
from pathlib import Path
import subprocess
import time

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--alternative', type=Path, required=True)
p.add_argument('--original', type=Path, required=True)
p.add_argument('--root', type=Path, required=True)
a = p.parse_args()
a.root = a.root.resolve()
a.root.mkdir()
repo = a.root / 'source'
env_base = {k: v for k, v in os.environ.items() if not k.startswith('GIT_')}
env_base.update(GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull,
                GIT_ATTR_NOSYSTEM='1', LC_ALL='C')


def run(build, args, ok=True, trace=None):
    build = build.resolve()
    env = dict(env_base, GIT_EXEC_PATH=str(build),
               GIT_TEMPLATE_DIR=str(build / 'templates/blt'))
    if trace is not None:
        env['GIT_TRACE2_EVENT'] = str(trace)
    done = subprocess.run([str(build / 'git')] + [str(x) for x in args],
                          env=env, capture_output=True)
    if ok:
        done.check_returncode()
    return done


alt = a.alternative.resolve()
orig = a.original.resolve()
run(alt, ['init', '-q', repo])
for key, value in [('user.name', 'Reflink experiment'), ('user.email', 'test@example.com'),
                   ('commit.gpgsign', 'false'), ('core.useNanoSec', 'true')]:
    run(alt, ['-C', repo, 'config', key, value])
path = repo / 'a'
expected = b'A' * (256 * 1024)
path.write_bytes(expected)
with path.open('r+b') as stream, mmap.mmap(stream.fileno(), 0) as mapping:
    mapping[0] = ord('A')
    mapping.flush()
    old = time.time_ns() - 60_000_000_000
    os.utime(path, ns=(old, old))
    run(alt, ['-C', repo, 'add', 'a'])
    run(alt, ['-C', repo, 'commit', '-qm', 'baseline'])
    # Rewriting a real index through Git, not synthesizing any stat fields.
    run(alt, ['-C', repo, 'update-index', '--refresh', '--force-write-index'])
    before = path.stat()
    mapping[0] = ord('X')
    after = path.stat()
    result = dict(platform=os.uname().sysname,
                  mtime_unchanged=before.st_mtime_ns == after.st_mtime_ns,
                  ctime_unchanged=before.st_ctime_ns == after.st_ctime_ns,
                  inode_unchanged=before.st_ino == after.st_ino,
                  source_diff_exit=run(alt, ['-C', repo, 'diff-files', '--quiet'], False).returncode,
                  checkouts={})
    for name, build, flag in [('ordinary', alt, '--no-reflink'),
                               ('alternative', alt, '--reflink'),
                               ('original', orig, '--reflink')]:
        target = a.root / name
        trace = a.root / (name + '-trace.json')
        run(build, ['-C', repo, 'worktree', 'add', '-q', '--detach', flag, target], trace=trace)
        counters = {}
        for line in trace.read_text().splitlines():
            event = json.loads(line)
            if event.get('event') == 'counter' and event.get('category') == 'reflink':
                key = event['name']
                counters[key] = counters.get(key, 0) + event['count']
        contents = (target / 'a').read_bytes()
        result['checkouts'][name] = dict(matches_blob=contents == expected,
                                        first_byte=contents[:1].decode(), counters=counters,
                                        diff_exit=run(build, ['-C', target, 'diff-files', '--quiet'], False).returncode)
    mapping[1] = ord('Y')
    result['recipient_independent_of_later_mmap_edit'] = (a.root / 'alternative/a').read_bytes()[1] == ord('A')
    run(alt, ['-C', repo, '-c', 'checkout.reflink=false', 'reset', '-q', '--hard'])
    result['ordinary_reset_kept_hidden_source_edit'] = path.read_bytes() != expected
(a.root / 'results.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result, indent=2))
