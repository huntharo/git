#!/usr/bin/env python3
"""Repeated warm-cache hard-reset controls; verify contents/allocation untimed."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import random
import statistics
import subprocess
import time

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--ordinary', required=True)
p.add_argument('--pr3', required=True)
p.add_argument('--candidate', required=True)
p.add_argument('--tool', required=True)
p.add_argument('--root', required=True)
p.add_argument('--files', type=int, default=2048)
p.add_argument('--kib', type=int, default=64)
p.add_argument('--repetitions', type=int, default=5)
a = p.parse_args()
builds = {k: str(Path(getattr(a, k)).resolve()) for k in ('ordinary', 'pr3', 'candidate')}
tool = str(Path(a.tool).resolve())
root = Path(a.root).resolve()
root.mkdir(parents=True, exist_ok=False)
env = {k: v for k, v in os.environ.items() if not k.startswith('GIT_')}
env.update(GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null',
           GIT_AUTHOR_NAME='Reflink benchmark', GIT_AUTHOR_EMAIL='test@example.com',
           GIT_COMMITTER_NAME='Reflink benchmark', GIT_COMMITTER_EMAIL='test@example.com')


def run(args, extra=None):
    try:
        return subprocess.check_output([str(x) for x in args], env=env | (extra or {}), stderr=subprocess.PIPE)
    except subprocess.CalledProcessError as e:
        raise RuntimeError((args, e.stderr.decode(errors='replace'))) from e


def git(build, repo, *args, trace=None):
    binary = builds[build]
    extra = dict(PATH=str(Path(binary).parent) + os.pathsep + env['PATH'],
                 GIT_EXEC_PATH=str(Path(binary).parent))
    if trace:
        extra['GIT_TRACE2_EVENT'] = str(trace)
    return run([binary, '-C', repo, *args], extra)


def usage(repo):
    keys = ('private', 'allocated', 'files', 'fully_shared')
    return dict(zip(keys, map(int, run([tool, 'reflink', 'private-bytes', repo]).split())))


def digest(repo):
    h = hashlib.sha256()
    for path in sorted(repo.iterdir()):
        if path.is_file() and path.name != '.git':
            h.update(path.name.encode())
            h.update(path.read_bytes())
    return h.hexdigest()


fixtures = {}
for conversion in ('raw', 'crlf'):
    source, target = root / (conversion + '-source'), root / (conversion + '-target')
    source.mkdir()
    git('ordinary', source, 'init', '-q')
    git('ordinary', source, 'config', 'checkout.reflink', 'false')
    if conversion == 'crlf':
        (source / '.gitattributes').write_text('* text eol=crlf\n.gitattributes -text\n')
    for i in range(a.files):
        line = (hashlib.sha256(str(i).encode()).hexdigest() + '\n').encode()
        data = (line * (a.kib * 1024 // len(line) + 1))[:a.kib * 1024]
        (source / f'f{i:05d}').write_bytes(data)
    git('ordinary', source, 'add', '.')
    git('ordinary', source, 'commit', '-qm', conversion)
    for path in source.iterdir():
        if path.is_file():
            path.unlink()
    git('ordinary', source, 'reset', '-q', '--hard')
    for path in source.iterdir():
        if path.is_file():
            st = path.stat()
            os.utime(path, ns=(st.st_atime_ns, st.st_mtime_ns - 60_000_000_000))
    git('ordinary', source, 'update-index', '--refresh', '--force-write-index')
    git('pr3', source, 'worktree', 'add', '-q', '--detach', '--no-reflink', target, 'HEAD')
    fixtures[conversion] = dict(source=source, target=target, digest=digest(target))

ops = ('ordinary', 'pr3', 'disabled', 'dry-run', 'private', 'shared')
cells = [(conversion, workers, op) for conversion in fixtures for workers in (1, 8) for op in ops]
samples = [(rep, cell) for rep in range(a.repetitions) for cell in cells]
random.Random(20261103).shuffle(samples)
result = dict(platform=platform.platform(), files=a.files, kib=a.kib,
              repetitions=a.repetitions, seed=20261103, cache='warm; setup and verification outside timing',
              started_utc=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()), initial_load=os.getloadavg(),
              builds={k: dict(path=v, sha256=hashlib.sha256(Path(v).read_bytes()).hexdigest(),
                             version=run([v, '--version']).decode().strip()) for k, v in builds.items()},
              samples=[], evidence=[])


def prepare(fixture, shared):
    target = fixture['target']
    for path in target.iterdir():
        if path.is_file() and path.name != '.git':
            path.unlink()
    git('ordinary', target, '-c', 'checkout.reflink=false', 'reset', '-q', '--hard')
    for path in target.iterdir():
        if path.is_file() and path.name != '.git':
            st = path.stat()
            os.utime(path, ns=(st.st_atime_ns, st.st_mtime_ns - 60_000_000_000))
    git('ordinary', target, 'update-index', '--refresh', '--force-write-index')
    if shared:
        git('candidate', target, '-c', 'checkout.reflink=true', 'reset', '-q', '--hard')


def invoke(fixture, workers, op, trace=None):
    build = op if op in ('ordinary', 'pr3') else 'candidate'
    enabled = 'false' if op in ('ordinary', 'disabled') else 'true'
    args = ['worktree', 'reflink', '--dry-run', '--porcelain'] if op == 'dry-run' else ['reset', '-q', '--hard']
    git(build, fixture['target'], '-c', f'checkout.workers={workers}',
        '-c', f'checkout.reflink={enabled}', *args, trace=trace)


def verify(fixture, op):
    assert digest(fixture['target']) == fixture['digest']
    after = usage(fixture['target'])
    if op in ('private', 'shared'):
        assert after['private'] == 0, after
    else:
        assert after['private'] > 0, after
    return after


# Trace2/accounting evidence is collected in separate untimed controls.
for conversion, workers, op in cells:
    fixture = fixtures[conversion]
    prepare(fixture, op == 'shared')
    before = usage(fixture['target'])
    trace = root / f'{conversion}-{workers}-{op}.trace'
    invoke(fixture, workers, op, trace)
    after = verify(fixture, op)
    counts = {x['key']: x.get('value') for x in map(json.loads, trace.read_text().splitlines())
              if x.get('event') == 'data' and x.get('category') == 'reflink-reshare'}
    result['evidence'].append(dict(conversion=conversion, workers=workers, operation=op,
                                   before=before, after=after, counts=counts))

for rep, (conversion, workers, op) in samples:
    fixture = fixtures[conversion]
    prepare(fixture, op == 'shared')
    start = time.perf_counter_ns()
    invoke(fixture, workers, op)
    elapsed = (time.perf_counter_ns() - start) / 1e6
    after = verify(fixture, op)
    result['samples'].append(dict(repetition=rep, conversion=conversion, workers=workers,
                                  operation=op, ms=elapsed, after=after))
    (root / 'results.json').write_text(json.dumps(result, indent=2) + '\n')
result['summary'] = []
for conversion, workers, op in cells:
    values = [x['ms'] for x in result['samples']
              if (x['conversion'], x['workers'], x['operation']) == (conversion, workers, op)]
    result['summary'].append(dict(conversion=conversion, workers=workers, operation=op,
                                  median_ms=statistics.median(values), min_ms=min(values), max_ms=max(values)))
result['finished_utc'] = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
result['final_load'] = os.getloadavg()
(root / 'results.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result['summary'], indent=2))
