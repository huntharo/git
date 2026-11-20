#!/usr/bin/env python3
"""Warm-cache, frozen-index benchmark. Dev-only; Python 3.9+ and macOS."""
import argparse
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import platform
import random
import statistics
import subprocess
import tempfile
import time

HERE = Path(__file__).resolve().parent
MIB = 1024 * 1024


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def checked(argv, **kwargs):
    return subprocess.run(argv, check=True, capture_output=True, **kwargs).stdout


def identity(path):
    s = path.stat()
    return (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns)


def summary(values):
    ordered = sorted(values)
    median = statistics.median(values)
    return dict(median_ms=median, min_ms=min(values), max_ms=max(values),
                p25_ms=ordered[len(values) // 4],
                p75_ms=ordered[3 * len(values) // 4],
                mad_ms=statistics.median(abs(x - median) for x in values))


def machine():
    data = dict(uname=list(platform.uname()), python=platform.python_version())
    hardware = HERE / 'local/hardware.json'
    if hardware.exists():
        data['verified_system_profiler'] = json.loads(hardware.read_text())
    for label, argv in [('os', ['sw_vers']), ('compiler', ['cc', '--version']),
                        ('hardware', ['sysctl', '-n', 'hw.model', 'hw.memsize',
                                      'hw.ncpu', 'machdep.cpu.brand_string'])]:
        r = subprocess.run(argv, capture_output=True, text=True)
        data[label] = dict(argv=argv, returncode=r.returncode,
                           stdout=r.stdout.strip(), stderr=r.stderr.strip())
    return data


@contextmanager
def mapped(helper, paths):
    process = subprocess.Popen([str(helper), 'map', *map(str, paths)],
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True)
    try:
        ready = process.stdout.readline().strip()
        assert ready == 'ready: descriptors closed; generation zero', ready
        yield process
    finally:
        if process.poll() is None:
            process.stdin.write('quit\n')
            process.stdin.flush()
        stdout, stderr = process.communicate(timeout=15)
        assert process.returncode == 0, (stdout, stderr)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--git', action='append', required=True,
                        help='LABEL=/absolute/path/to/git; repeat for all variants')
    parser.add_argument('--reference', default='baseline',
                        help='fixture builder; incorrect mapped-write output is recorded')
    parser.add_argument('--builds', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--work-root', type=Path, default=HERE / 'local')
    parser.add_argument('--mapper', type=Path, default=HERE / 'local/mapper')
    parser.add_argument('--diagnostic-shim', type=Path,
                        help='optional SEPARATE untimed diagnostic for every row')
    parser.add_argument('--repetitions', type=int, default=9)
    parser.add_argument('--warmups', type=int, default=2)
    parser.add_argument('--seed', type=int, default=20261109)
    parser.add_argument('--profile', choices=['full', 'smoke'], default='smoke')
    parser.add_argument('--fixtures', nargs='+',
                        choices=['small', 'one-large', 'ten-large', 'mixed'],
                        default=['small', 'one-large', 'ten-large', 'mixed'])
    args = parser.parse_args()
    assert args.repetitions >= 1 and args.warmups >= 1
    binaries = dict(item.split('=', 1) for item in args.git)
    assert len(binaries) == 3, 'supply exactly three distinct labels'
    binaries = {label: Path(path).resolve() for label, path in binaries.items()}
    assert args.reference in binaries
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(('GIT_', 'DYLD_', 'BENCH_COUNT_'))}
    env.update(GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null',
               GIT_ATTR_NOSYSTEM='1', GIT_OPTIONAL_LOCKS='0', LC_ALL='C')
    builds = json.loads(args.builds.read_text()) if args.builds else {}
    for label, binary in binaries.items():
        if label in builds:
            assert sha256(binary) == builds[label]['binary_sha256']
    args.work_root.mkdir(parents=True, exist_ok=True)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    rng = random.Random(args.seed)
    result = dict(schema=1, started_utc=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
                  profile=args.profile, machine=machine(), builds=builds,
                  binaries={k: dict(path=str(v), sha256=sha256(v))
                            for k, v in binaries.items()},
                  parameters=dict(repetitions=args.repetitions, warmups=args.warmups,
                                  seed=args.seed, reference=args.reference),
                  method='perf_counter_ns around subprocess.run; stdout/stderr captured; '
                         'all output validation, stats, hashing index and diagnostics untimed; '
                         'warm cache, no cache purging, fresh process per sample; '
                         'frozen per-mode index + GIT_OPTIONAL_LOCKS=0; baseline index recaptured '
                         'between mapping groups after final unmap may update ctime',
                  fixtures=[], rows=[], diagnostics=[])
    reference = binaries[args.reference]
    large_size = 100 * MIB if args.profile == 'full' else MIB
    small_count = 5000 if args.profile == 'full' else 80
    specs = dict(small=(small_count, 0), **{'one-large': (0, 1),
                 'ten-large': (0, 10), 'mixed': (small_count, 2)})

    def save():
        args.output.write_text(json.dumps(result, indent=2) + '\n')

    for fixture in args.fixtures:
        small, large = specs[fixture]
        with tempfile.TemporaryDirectory(prefix=f'fixture-{fixture}-',
                                         dir=args.work_root) as tmp:
            repo = Path(tmp)
            files = repo / 'files'
            files.mkdir()
            sizes = {f'files/small-{i:05d}': (16384 if i < 64 else 1024)
                     for i in range(small)}
            sizes.update({f'files/large-{i:02d}': large_size for i in range(large)})
            # Explicit writes, no sparse files, hardlinks, copy/clone/reflink calls.
            block = b'A' * MIB
            age = time.time_ns() - 60_000_000_000
            for name, size in sizes.items():
                with (repo / name).open('wb', buffering=0) as stream:
                    remaining = size
                    while remaining:
                        chunk = block[:min(remaining, len(block))]
                        n = stream.write(chunk)
                        assert n == len(chunk)
                        remaining -= n
                    os.fsync(stream.fileno())
                os.utime(repo / name, ns=(age, age))
            allocation = sum((repo / p).stat().st_blocks * 512 for p in sizes)
            total = sum(sizes.values())
            fixture_info = dict(name=fixture, files=len(sizes), bytes=total,
                                MiB=total / MIB, allocated_bytes=allocation,
                                content='deterministic repeated ASCII A; fully written + fsync',
                                large_file_bytes=large_size, large_file_MiB=large_size / MIB,
                                small_files=small, large_files=large)
            result['fixtures'].append(fixture_info)
            def git(*argv, **kw):
                return checked([str(reference), *argv], cwd=repo, env=env, **kw)
            git('init', '-q', '--template=')
            for key, value in [('core.preloadIndex', 'true'), ('core.untrackedCache', 'false'),
                               ('core.ignoreStat', 'false'), ('core.ignoreCase', 'false'),
                               ('core.checkStat', 'default'), ('core.trustctime', 'true'),
                               ('core.autocrlf', 'false'), ('index.version', '2')]:
                git('config', key, value)
            # Avoid racy index entries for BOTH mtime and ctime at index creation.
            time.sleep(1.1)
            git('add', 'files')
            git('-c', 'user.name=Benchmark', '-c', 'user.email=bench@example.invalid',
                '-c', 'commit.gpgSign=false', 'commit', '-qm', 'plain fixture')
            hook = repo / '.git/hooks/benchmark-fsmonitor'
            hook.parent.mkdir(exist_ok=True)
            hook.write_text("#!/bin/sh\nprintf 'benchmark-token\\0'\n")
            hook.chmod(0o755)
            off = repo / '.git/frozen-off'
            off.write_bytes((repo / '.git/index').read_bytes())
            monitor_args = ['-c', f'core.fsmonitor={hook}',
                            '-c', 'core.fsmonitorHookVersion=2']
            git(*monitor_args, 'update-index', '--fsmonitor')
            git(*monitor_args, 'update-index', '--fsmonitor-valid', '--stdin',
                input=('\n'.join(sizes) + '\n').encode())
            valid = git(*monitor_args, 'ls-files', '-f').decode().splitlines()
            assert valid == sorted('h ' + name for name in sizes), valid[:5]
            frozen_valid = repo / '.git/frozen-valid'
            frozen_valid.write_bytes((repo / '.git/index').read_bytes())
            snapshots = dict(off=off, valid=frozen_valid)
            fixture_info['index_sha256'] = {k: sha256(v) for k, v in snapshots.items()}
            fixture_info['index_epochs'] = [dict(reason='initial',
                sha256=dict(fixture_info['index_sha256']))]
            original_stats = {name: identity(repo / name) for name in sizes}
            for index in snapshots.values():
                index_ns = index.stat().st_mtime_ns
                assert all(st[3] < index_ns and st[4] < index_ns
                           and st[3] // 10**9 < index_ns // 10**9
                           and st[4] // 10**9 < index_ns // 10**9
                           for st in original_stats.values())
            preferred = sorted(p for p in sizes if '/large-' in p) or sorted(sizes)[:64]
            candidates = [repo / name for name in preferred]
            generations = list(map(int, checked([str(args.mapper), 'query',
                                                *map(str, candidates)]).splitlines()))
            assert all(generations), generations
            fixture_info['generation_before_mapping'] = generations

            def assert_stats():
                assert all(identity(repo / name) == old
                           for name, old in original_stats.items()), 'metadata changed'
                for mode, snapshot in snapshots.items():
                    assert sha256(snapshot) == fixture_info['index_sha256'][mode]

            def measure(state, mapped_paths, modified):
                expected_paths = sorted(str(p.relative_to(repo)) for p in mapped_paths) if modified else []
                assert_stats()
                for mode, index in snapshots.items():
                    common = monitor_args if mode == 'valid' else ['-c', 'core.fsmonitor=false']
                    command_env = dict(env, GIT_INDEX_FILE=str(index))
                    for command, argv in [('status', ['status', '--porcelain', '--untracked-files=no']),
                                          ('diff', ['diff', '--name-only'])]:
                        expected = ''.join((' M ' if command == 'status' else '') + p + '\n'
                                           for p in expected_paths).encode()
                        row = dict(fixture=fixture, state=state, fsmonitor=mode,
                                   index_sha256=fixture_info['index_sha256'][mode],
                                   index_epoch=len(fixture_info['index_epochs']) - 1,
                                   command=command, mapped_files=len(mapped_paths),
                                   mapped_bytes=sum(p.stat().st_size for p in mapped_paths),
                                   mapped_paths=sorted(str(p.relative_to(repo)) for p in mapped_paths),
                                   modified_files=len(expected_paths),
                                   modified_file_bytes=sum(p.stat().st_size for p in mapped_paths) if modified else 0,
                                   changed_byte_count=len(expected_paths),
                                   case_role='nominal expected' if state == 'unmapped' else 'mapped stress case',
                                   expected_paths=expected_paths, samples=[], warmups=[], variants={})
                        # Each block of 3 rotations gives every variant every position.
                        orders = []
                        for start in range(0, args.repetitions, 3):
                            base = list(binaries)
                            rng.shuffle(base)
                            orders.extend([base[i:] + base[:i] for i in range(3)])
                        warm_orders = [rng.sample(list(binaries), len(binaries))
                                       for _ in range(args.warmups)]
                        all_orders = warm_orders + orders[:args.repetitions]
                        for trial, order in enumerate(all_orders):
                            for position, label in enumerate(order):
                                assert_stats()
                                begin = time.perf_counter_ns()
                                process = subprocess.run([str(binaries[label]), *common, *argv],
                                                         cwd=repo, env=command_env, capture_output=True)
                                elapsed = (time.perf_counter_ns() - begin) / 1_000_000
                                # Exact byte output, rc, and nanosecond metadata checked after clock stops.
                                correct = process.returncode == 0 and process.stdout == expected
                                assert process.returncode == 0, (label, process.stderr)
                                if label != args.reference or not modified:
                                    assert correct, (fixture, state, mode, command, label,
                                                     expected, process.stdout, process.stderr)
                                assert_stats()
                                sample = dict(label=label, round=trial - args.warmups,
                                              position=position, ms=elapsed, correct=correct,
                                              stdout=process.stdout.decode(), returncode=process.returncode)
                                row['warmups' if trial < args.warmups else 'samples'].append(sample)
                        for label in binaries:
                            samples = [s for s in row['samples'] if s['label'] == label]
                            row['variants'][label] = dict(summary([s['ms'] for s in samples]),
                                                         correct=all(s['correct'] for s in samples))
                        result['rows'].append(row)
                        # Diagnostic process is separate and its elapsed time is never recorded.
                        if args.diagnostic_shim:
                            for label, binary in binaries.items():
                                log = repo / '.git/counts.jsonl'
                                log.unlink(missing_ok=True)
                                diagnostic_env = dict(command_env,
                                    DYLD_INSERT_LIBRARIES=str(args.diagnostic_shim.resolve()),
                                    BENCH_COUNT_PREFIX=str(files) + '/', BENCH_COUNT_OUTPUT=str(log))
                                p = subprocess.run([str(binary), *common, *argv], cwd=repo,
                                                   env=diagnostic_env, capture_output=True)
                                assert p.returncode == 0
                                assert p.stdout == next(s['stdout'].encode() for s in row['samples']
                                                        if s['label'] == label)
                                counters = [json.loads(line) for line in log.read_text().splitlines()]
                                assert len(counters) == 1, counters
                                result['diagnostics'].append(dict(fixture=fixture, state=state,
                                    fsmonitor=mode, command=command, label=label, **counters[0]))
                                assert_stats()
                        save()
                print(f'{fixture}: {state} ({len(mapped_paths)} mapped) complete', flush=True)

            measure('unmapped', [], False)
            groups = [('one', candidates[:1])]
            if len(candidates) > 1:
                groups.append(('many', candidates))
            for group, paths in groups:
                if group != 'one':
                    # Last munmap of a dirty shared mapping can update ctime.
                    # Restore a fresh non-racy baseline BEFORE the next group;
                    # keep it identical/frozen for all variants within that group.
                    time.sleep(1.1)
                    git('-c', 'core.fsmonitor=false', 'add', 'files')
                    off.write_bytes((repo / '.git/index').read_bytes())
                    git(*monitor_args, 'update-index', '--fsmonitor')
                    git(*monitor_args, 'update-index', '--fsmonitor-valid', '--stdin',
                        input=('\n'.join(sizes) + '\n').encode())
                    valid = git(*monitor_args, 'ls-files', '-f').decode().splitlines()
                    assert valid == sorted('h ' + name for name in sizes)
                    frozen_valid.write_bytes((repo / '.git/index').read_bytes())
                    fixture_info['index_sha256'] = {k: sha256(v) for k, v in snapshots.items()}
                    fixture_info['index_epochs'].append(dict(reason='after-final-unmap',
                        sha256=dict(fixture_info['index_sha256'])))
                    original_stats = {name: identity(repo / name) for name in sizes}
                    for index in snapshots.values():
                        index_ns = index.stat().st_mtime_ns
                        assert all(st[3] // 10**9 < index_ns // 10**9 and
                                   st[4] // 10**9 < index_ns // 10**9
                                   for st in original_stats.values())
                with mapped(args.mapper, paths) as process:
                    assert_stats()
                    measure(f'{group}-mapped-unchanged', paths, False)
                    process.stdin.write('write B\n')
                    process.stdin.flush()
                    assert process.stdout.readline().strip() == 'written: quiescent'
                    assert_stats()
                    for path in paths:
                        with path.open('rb') as stream:
                            assert stream.read(1) == b'B'
                    measure(f'{group}-mapped-modified', paths, True)
                    process.stdin.write('write A\n')
                    process.stdin.flush()
                    assert process.stdout.readline().strip() == 'written: quiescent'
                    assert_stats()
            fixture_info['invariants_passed'] = True
            save()
    result['finished_utc'] = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
    save()
    print(args.output)


if __name__ == '__main__':
    main()
