#!/usr/bin/env python3
"""Matched PR2 ordinary/reflink and candidate EOL checkout controls.

Creates only dedicated scratch fixtures under --output. Byte/mode validation,
physical sharing inspection and Trace2 evidence run outside timed intervals.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import random
import resource
import statistics
import subprocess
import time

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--pr2', type=Path, required=True)
p.add_argument('--candidate', type=Path, required=True)
p.add_argument('--output', type=Path, required=True)
p.add_argument('--repetitions', type=int, default=5)
p.add_argument('--files', type=int, default=128)
p.add_argument('--kib', type=int, default=256)
a = p.parse_args()
if min(a.repetitions, a.files, a.kib) < 1:
    p.error('counts and sizes must be positive')
a.output = a.output.resolve()
a.output.mkdir(parents=True, exist_ok=False)
builds = {'pr2': a.pr2.resolve(), 'candidate': a.candidate.resolve()}
base_env = {k: v for k, v in os.environ.items() if not k.startswith('GIT_')}
base_env.update(GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull,
                GIT_ATTR_NOSYSTEM='1', LC_ALL='C', GIT_TERMINAL_PROMPT='0')


def env(build):
    return dict(base_env, GIT_EXEC_PATH=str(build),
                GIT_TEMPLATE_DIR=str(build / 'templates/blt'),
                PATH=str(build) + os.pathsep + base_env['PATH'])


def run(build, args, extra=None):
    return subprocess.check_output([str(build / 'git'), *map(str, args)],
                                   env=dict(env(build), **(extra or {})),
                                   stderr=subprocess.PIPE)


def describe(root):
    return {str(f.relative_to(root)): (f.stat().st_mode & 0o777,
            f.stat().st_size, hashlib.sha256(f.read_bytes()).hexdigest())
            for f in root.rglob('*') if f.is_file() and f.name != '.git'
            and '.git' not in f.relative_to(root).parts}


candidate = builds['candidate']
result = dict(platform=platform.platform(), files=a.files, kib=a.kib,
              repetitions=a.repetitions, cache='warm, no global purge', seed=20261103,
              builds={}, fixtures={}, runs=[], started=time.time(), initial_load=os.getloadavg())
for name, build in builds.items():
    result['builds'][name] = dict(path=str(build),
        version=run(build, ['version', '--build-options']).decode(),
        cflags=(build / 'GIT-CFLAGS').read_text(),
        ldflags=(build / 'GIT-LDFLAGS').read_text(),
        reflink_c_sha256=hashlib.sha256((build / 'reflink-checkout.c').read_bytes()).hexdigest())
for fixture in ['eol-heavy', 'unconverted']:
    repo = a.output / fixture
    repo.mkdir()
    run(candidate, ['init', '-q', repo])
    run(candidate, ['-C', repo, 'config', 'user.name', 'Reflink fixture'])
    run(candidate, ['-C', repo, 'config', 'user.email', 'fixture@example.invalid'])
    if fixture == 'eol-heavy':
        (repo / '.gitattributes').write_text('*.crlf text eol=crlf\n*.auto text=auto eol=crlf\n')
    for i in range(a.files):
        data = random.Random(i + 971).randbytes(a.kib * 512).hex().encode()
        data = b'\n'.join(data[j:j+127] for j in range(0, len(data), 127)) + b'\n'
        suffix = ('crlf' if i % 2 else 'auto') if fixture == 'eol-heavy' else 'raw'
        (repo / f'file-{i:04}.{suffix}').write_bytes(data)
    run(candidate, ['-C', repo, 'add', '.'])
    run(candidate, ['-C', repo, 'commit', '-qm', fixture])
    for f in repo.glob('file-*'):
        f.unlink()
    run(candidate, ['-C', repo, 'checkout-index', '-afu'])
    time.sleep(1.1)  # natural aging; never forge file or index stat data
    run(candidate, ['-C', repo, 'update-index', '--refresh', '--force-write-index'])
    if run(candidate, ['-C', repo, 'status', '--porcelain']):
        raise RuntimeError('Dirty fixture')
    result['fixtures'][fixture] = dict(commit=run(candidate,
        ['-C', repo, 'rev-parse', 'HEAD']).decode().strip(),
        output_bytes=sum(x[1] for x in describe(repo).values()))


def save():
    (a.output / 'results.json').write_text(json.dumps(result, indent=2) + '\n')


def trial(fixture, workers, mode, repetition):
    build = builds['candidate' if mode == 'candidate' else 'pr2']
    repo, target = a.output / fixture, a.output / 'checkout'
    trace = a.output / 'trace.json'
    trace.unlink(missing_ok=True)
    args = ['-C', repo, '-c', 'core.hooksPath=/dev/null', '-c', f'checkout.workers={workers}',
            '-c', 'checkout.thresholdForParallelism=0', 'worktree', 'add', '-q', '--detach',
            '--no-reflink' if mode == 'ordinary' else '--reflink', target]
    load = os.getloadavg()
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    started = time.perf_counter()
    run(build, args, {'GIT_TRACE2_EVENT': str(trace)} if repetition < 0 else None)
    elapsed = time.perf_counter() - started
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    # Everything below is outside the timed creation interval.
    if describe(repo) != describe(target):
        raise RuntimeError('Checkout bytes or modes differ')
    if run(build, ['-C', target, 'status', '--porcelain']):
        raise RuntimeError('Dirty checkout')
    usage = subprocess.check_output([str(candidate / 't/helper/test-tool'), 'reflink',
                                     'private-bytes', str(target)], env=env(candidate)).decode().strip()
    counters, compare_seconds = {}, 0
    if trace.exists():
        for line in trace.read_text().splitlines():
            event = json.loads(line)
            if event.get('category') == 'reflink':
                if event.get('event') == 'counter':
                    key = event['name']
                    counters[key] = counters.get(key, 0) + event['count']
                if event.get('event') == 'region_leave' and event.get('label') == 'compare-output':
                    compare_seconds += event['t_rel']
    private, allocated, files, shared = map(int, usage.split())
    if mode == 'candidate' or (fixture == 'unconverted' and mode == 'pr2'):
        if private or shared != files:
            raise RuntimeError('Expected fully shared checkout: ' + usage)
    row = dict(fixture=fixture, workers=workers, mode=mode, repetition=repetition,
               wall_seconds=elapsed, load=load, user_seconds=after.ru_utime-before.ru_utime,
               system_seconds=after.ru_stime-before.ru_stime, counters=counters,
               compare_process_seconds=compare_seconds, private_bytes=private,
               allocated_bytes=allocated, files=files, fully_shared_files=shared)
    result['runs'].append(row)
    run(build, ['-C', repo, 'worktree', 'remove', '--force', target])
    save()
    print(json.dumps(row), flush=True)


configs = [(fixture, workers, mode) for fixture in result['fixtures']
           for workers in [1, 8] for mode in ['ordinary', 'pr2', 'candidate']]
for config in configs:
    trial(*config, -1)
rng = random.Random(result['seed'])
for repetition in range(a.repetitions):
    order = configs.copy()
    rng.shuffle(order)
    for config in order:
        trial(*config, repetition)
result['summary'] = []
for fixture, workers, mode in configs:
    rows = [r for r in result['runs'] if r['repetition'] >= 0 and
            (r['fixture'], r['workers'], r['mode']) == (fixture, workers, mode)]
    result['summary'].append(dict(fixture=fixture, workers=workers, mode=mode,
        median_seconds=statistics.median(r['wall_seconds'] for r in rows),
        min_seconds=min(r['wall_seconds'] for r in rows),
        max_seconds=max(r['wall_seconds'] for r in rows)))
result['finished'] = time.time()
save()
print(json.dumps(result['summary']), flush=True)
