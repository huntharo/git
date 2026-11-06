#!/usr/bin/env python3
"""Interleave ordinary, original-PR and alternative checkouts of one fixture.

Use dedicated fixture/output directories. All worktrees created here are removed.
Builds must have matching options except for the named secondary SHA-1 backend.
"""
import argparse
import hashlib
import itertools
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
p.add_argument('--repo', type=Path, required=True)
p.add_argument('--output', type=Path, required=True)
p.add_argument('--repetitions', type=int, default=5)
for name in ['original-dc', 'original-fast', 'alternative-dc', 'alternative-fast']:
    p.add_argument('--' + name, type=Path, required=True)
a = p.parse_args()
if a.repetitions < 1:
    p.error('--repetitions must be positive')
a.repo = a.repo.resolve()
a.output = a.output.resolve()
a.output.mkdir(parents=True, exist_ok=True)
builds = {name: getattr(a, name.replace('-', '_')).resolve()
          for name in ['original-dc', 'original-fast', 'alternative-dc', 'alternative-fast']}
env_base = {k: v for k, v in os.environ.items()
            if not k.startswith('GIT_') and k != 'LOCAL_GIT_DIRECTORY'}
env_base.update(GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull,
                GIT_ATTR_NOSYSTEM='1', LC_ALL='C', GIT_TERMINAL_PROMPT='0')


def env_for(build):
    return dict(env_base, GIT_EXEC_PATH=str(build),
                GIT_TEMPLATE_DIR=str(build / 'templates/blt'),
                PATH=str(build) + os.pathsep + env_base['PATH'])


def run(build, args, cwd=None, env=None, data=None):
    done = subprocess.run([str(build / 'git')] + [str(x) for x in args],
                          cwd=cwd, env=env or env_for(build), input=data,
                          capture_output=True, check=True)
    return done.stdout


control = builds['alternative-dc']
commit = run(control, ['-C', a.repo, 'rev-parse', 'HEAD']).decode().strip()
if run(control, ['-C', a.repo, 'status', '--porcelain', '--untracked-files=no']):
    raise RuntimeError('Fixture is dirty')
# Write a new, real index after the fixture has aged. This uses Git's normal
# racy-file/content checks; donor stat fields and file timestamps are not forged.
run(control, ['-C', a.repo, 'update-index', '--refresh', '--force-write-index'])
entries = []
for record in run(control, ['-C', a.repo, 'ls-files', '-s', '-z']).split(b'\0'):
    if record:
        header, name = record.split(b'\t', 1)
        mode, oid, stage = header.split()
        if mode.startswith(b'100'):
            if b'\n' in name:
                raise RuntimeError('This fixture verifier requires newline-free paths')
            entries.append((name, oid))
configs = list(itertools.product(['dc', 'fast'], [1, 8],
                                ['normal-original', 'normal-alternative',
                                 'reflink-original', 'reflink-alternative']))
metadata = dict(platform=platform.platform(), commit=commit, repo=str(a.repo),
                cache='warm; no global cache purge', repetitions=a.repetitions,
                seed=20261102, regular_files=len(entries), started=time.time(),
                versions={k: run(v, ['version', '--build-options']).decode()
                          for k, v in builds.items()},
                provenance={k: dict(
                    reflink_source_sha256=hashlib.sha256((v / 'reflink-checkout.c').read_bytes()).hexdigest(),
                    compiler_options=(v / 'GIT-CFLAGS').read_text(),
                    linker_options=(v / 'GIT-LDFLAGS').read_text())
                    for k, v in builds.items()}, runs=[])


def save():
    (a.output / 'results.json').write_text(json.dumps(metadata, indent=2) + '\n')


def trial(config, repetition):
    hasher, workers, mode = config
    action, implementation = mode.split('-')
    build = builds[implementation + '-' + hasher]
    target = a.output / 'worktree'
    trace = a.output / 'trace.json'
    if target.exists():
        raise RuntimeError('Refusing existing target: ' + str(target))
    trace.unlink(missing_ok=True)
    environment = dict(env_for(build), GIT_TRACE2_EVENT=str(trace))
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    load = os.getloadavg()
    started = time.perf_counter()
    run(build, ['-c', 'core.hooksPath=/dev/null', '-c', f'checkout.workers={workers}',
                '-c', 'checkout.thresholdForParallelism=100', '-C', a.repo,
                'worktree', 'add', '-q', '--detach',
                '--reflink' if action == 'reflink' else '--no-reflink', target, commit],
        env=environment)
    elapsed = time.perf_counter() - started
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    counters = {}
    for line in trace.read_text().splitlines():
        event = json.loads(line)
        if event.get('event') == 'counter' and event.get('category') == 'reflink':
            name = event['name']
            counters[name] = counters.get(name, 0) + event['count']
    if action == 'reflink' and not counters.get('cloned'):
        raise RuntimeError('No real reflinks: ' + str(counters))
    if counters.get('verify-failed') or counters.get('scratch-donor'):
        raise RuntimeError('Unexpected fallback or synthetic donor: ' + str(counters))
    if run(build, ['-C', target, 'status', '--porcelain', '--untracked-files=no']):
        raise RuntimeError('Dirty checkout')
    usage = None
    if repetition == -1:
        actual = run(build, ['-C', target, 'hash-object', '--no-filters', '--stdin-paths'],
                     data=b''.join(name + b'\n' for name, _ in entries)).splitlines()
        if actual != [oid for _, oid in entries]:
            raise RuntimeError('Raw checkout bytes differ from the index blobs')
        usage = subprocess.check_output([str(build / 't/helper/test-tool'), 'reflink',
                                         'private-bytes', str(target)], env=env_for(build)).decode().strip()
    run(build, ['-c', 'core.hooksPath=/dev/null', '-C', a.repo,
                'worktree', 'remove', '--force', target])
    result = dict(hasher=hasher, workers=workers, mode=mode, repetition=repetition,
                  wall_seconds=elapsed, user_seconds=after.ru_utime - before.ru_utime,
                  system_seconds=after.ru_stime - before.ru_stime, load=load,
                  counters=counters, private_allocated_files_shared=usage)
    metadata['runs'].append(result)
    save()
    print(json.dumps(result), flush=True)


for config in configs:
    trial(config, -1)
rng = random.Random(metadata['seed'])
for repetition in range(a.repetitions):
    order = configs.copy()
    rng.shuffle(order)
    for config in order:
        trial(config, repetition)
metadata['summary'] = []
for hasher, workers, mode in configs:
    rows = [x for x in metadata['runs'] if x['repetition'] >= 0 and
            (x['hasher'], x['workers'], x['mode']) == (hasher, workers, mode)]
    times = [x['wall_seconds'] for x in rows]
    metadata['summary'].append(dict(hasher=hasher, workers=workers, mode=mode,
                                    median_seconds=statistics.median(times),
                                    min_seconds=min(times), max_seconds=max(times),
                                    stdev_seconds=statistics.stdev(times) if len(times) > 1 else 0,
                                    samples=len(times)))
metadata['finished'] = time.time()
save()
print(json.dumps(metadata['summary']), flush=True)
