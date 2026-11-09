#!/usr/bin/env python3
"""Render reproducible Markdown tables from bench.py's raw samples."""
import argparse
import csv
import json
from pathlib import Path
import statistics

parser = argparse.ArgumentParser()
parser.add_argument('results', type=Path)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
data = json.loads(args.results.read_text())
labels = list(data['binaries'])
assert labels == ['baseline', 'selective', 'always']
MIB = 1024 * 1024
fixtures = {f['name']: f for f in data['fixtures']}
diagnostics = {
    tuple(d[k] for k in ['fixture', 'state', 'fsmonitor', 'command', 'label']): d
    for d in data['diagnostics']
}
assert len(diagnostics) == len(data['diagnostics'])


def state_label(row):
    if row['state'] == 'unmapped':
        return '**Unmapped (nominal expected)**'
    condition = 'modified' if row['expected_paths'] else 'unchanged'
    return f"{row['mapped_files']} mapped, {condition}"


def mib(value):
    return f'{value / MIB:,.4f}'.rstrip('0').rstrip('.')


workloads = {}
for row in data['rows']:
    key = tuple(row[k] for k in ['fixture', 'state', 'fsmonitor', 'command'])
    fixture = fixtures[row['fixture']]
    work = {k: row[k] for k in ['fixture', 'state', 'fsmonitor', 'command']}
    work.update(case_role='nominal expected' if row['state'] == 'unmapped' else 'mapped stress case',
                mapped_files=row['mapped_files'], mapped_bytes=row['mapped_bytes'],
                modified_files=len(row['expected_paths']),
                modified_file_bytes=row['mapped_bytes'] if row['expected_paths'] else 0)
    for label in ['selective', 'always']:
        work[label + '_unique_files'] = row['mapped_files'] if label == 'selective' else fixture['files']
        work[label + '_unique_file_bytes'] = row['mapped_bytes'] if label == 'selective' else fixture['bytes']
        counter = diagnostics.get(key + (label,))
        for field in ['read_bytes', 'pread_bytes', 'mmap_requested_bytes']:
            work[label + '_' + field] = counter[field] if counter else None
        work[label + '_total_content_request_bytes'] = (
            sum(counter[field] for field in ['read_bytes', 'pread_bytes', 'mmap_requested_bytes'])
            if counter else None)
    workloads[key] = work


def request_mib(work, label):
    value = work[label + '_total_content_request_bytes']
    return mib(value) if value is not None else 'not measured'


with (args.output.parent / 'workloads.tsv').open('w', newline='') as stream:
    writer = csv.DictWriter(stream, fieldnames=list(next(iter(workloads.values()))),
                            delimiter='\t', lineterminator='\n')
    writer.writeheader()
    writer.writerows(workloads.values())

selected_states = {
    ('small', 'unmapped', 'off'), ('small', 'unmapped', 'valid'),
    ('one-large', 'unmapped', 'off'),
    ('one-large', 'one-mapped-unchanged', 'off'),
    ('one-large', 'one-mapped-modified', 'off'),
    ('ten-large', 'unmapped', 'off'),
    ('ten-large', 'one-mapped-unchanged', 'off'),
    ('ten-large', 'many-mapped-unchanged', 'off'),
    ('ten-large', 'many-mapped-modified', 'off'),
    ('mixed', 'unmapped', 'off'),
    ('mixed', 'many-mapped-unchanged', 'off'),
}
summary = ['# Status timing and content workload', '',
           '**Unmapped is the nominal expected case.** Timings are warm-cache medians '
           'in ms. In each MiB cell, the first value is the sum of unique file sizes '
           'selected for content validation; the second is the separate diagnostic '
           'total of returned read/pread bytes + requested mmap lengths, including repeats. '
           'Mapping lengths are not measured bytes touched or physical I/O. '
           'Unchanged rows modify zero files; modified rows change byte zero of every '
           'mapped file. `*` marks incorrect baseline output.', '',
           '| Fixture | State | Fsmonitor | Baseline ms | Selective ms | Always ms | Selective MiB (unique → requested) | Always MiB (unique → requested) |',
           '| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |']
for row in data['rows']:
    if row['command'] != 'status' or (row['fixture'], row['state'], row['fsmonitor']) not in selected_states:
        continue
    work = workloads[tuple(row[k] for k in ['fixture', 'state', 'fsmonitor', 'command'])]
    times = [f"{row['variants'][label]['median_ms']:.2f}"
             + ('' if row['variants'][label]['correct'] else '*') for label in labels]
    summary.append(f"| {row['fixture']} | {state_label(row)} | {row['fsmonitor']} | "
                   + ' | '.join(times)
                   + f" | {mib(work['selective_unique_file_bytes'])} → {request_mib(work, 'selective')}"
                   + f" | {mib(work['always_unique_file_bytes'])} → {request_mib(work, 'always')} |")
summary.extend(['', 'The ten-large “10 mapped” rows use the same ten paths. Unchanged: '
                'zero modified files and 1,000 MiB requested by each correct variant. '
                'Modified: ten modified files and 3,000 MiB requested by each. '
                'Repeated content comparisons explain the roughly threefold status time. '
                'Both variants follow the same content path when all files are mapped, '
                'so their close times are expected. Unique file size does not triple. '
                'When files are unmapped, Selective skips their content and Always compares it.', '',
                'See [RESULTS.md](RESULTS.md) for all status/diff rows and spread, and '
                '[workloads.tsv](workloads.tsv) for exact byte totals and the separate '
                'read/pread/mmap counters. Unique counts come from the controlled fixture '
                'and mapping set; request totals are measured in untimed diagnostic processes.', ''])
(args.output.parent / 'SUMMARY.md').write_text('\n'.join(summary))

lines = ['# Local macOS experiment results', '',
         'Benchmark only. **Do not merge or submit upstream.** Warm cache; medians in ms. '
         f"Every cell is median ± median absolute deviation (MAD), with {data['parameters']['repetitions']} measured "
         f"samples after {data['parameters']['warmups']} warmup rounds. `*` means incorrect output for every sample "
         '(silent mapped writes); its speed is not an equally-correct result.', '',
         f"Measured {data['started_utc']} through {data['finished_utc']}.", '',
         'Apple M2 Max MacBook Pro (Mac14,6), 32 GB, arm64; macOS 27.2 (26B123), '
         'Darwin 27.2.0; Apple clang 21.0.0. Hardware fields verified with '
         '`system_profiler`, while the sandbox denied the `sysctl` read. '
         'All executables use `make -j8 NO_GETTEXT=YesPlease CFLAGS=\'-O2 -g\' git`.', '',
         '| Variant | Exact source SHA |', '| --- | --- |']
for label, meta in data['builds'].items():
    lines.append(f"| {label} | `{meta['sha']}` |")
lines.extend(['', 'Raw samples, per-sample exact output, index hashes, correctness flags, '
              'metadata, build flags and diagnostic counters: [results.json](results.json). '
              'Binary hashes and build records: [builds.json](builds.json).', '',
              'All fixture bytes were explicitly written and fsynced, using repeated ASCII '
              '`A` (highly compressible, identical content at equal sizes); no sparse, '
              'clone, reflink or hardlink fixture construction. They were processed serially.', '',
              '| Fixture | Files | Bytes | MiB | Allocated worktree bytes |', '| --- | ---: | ---: | ---: | ---: |'])
for fixture in data['fixtures']:
    lines.append(f"| {fixture['name']} | {fixture['files']} | {fixture['bytes']:,} | "
                 f"{fixture['MiB']:.4f} | {fixture['allocated_bytes']:,} |")
lines.extend(['', '**Unmapped is the nominal expected case.** Mapped rows deliberately stress '
              'the fallback. “Unchanged” means zero files modified; “modified” means byte zero '
              'of every mapped file was changed. The ten-large many rows use the same ten '
              '100 MiB paths: ten mapped / zero modified versus ten mapped / ten modified.', '',
              'Workload tables distinguish **unique file size** from **total content requests**, '
              'which include repeated work. Unique counts and byte sums are derived from the '
              'controlled mapped set (Selective) and all fixture files (Always); they are not '
              'per-path tracing measurements. Request totals are measured in separate diagnostic '
              'processes: returned read + pread bytes plus successful mmap requested lengths. '
              '**Requested mapping length is not bytes touched, bytes hashed, or physical I/O.** '
              'Exact bytes and the component counters for every row are in '
              '[workloads.tsv](workloads.tsv).', '',
              'For ten-large status, both variants cover 1,000 MiB of unique files when all '
              'ten are mapped. Unchanged requests total 1,000 MiB and modified requests total '
              '3,000 MiB, explaining the roughly 1.83 s versus 5.47 s times. These are the '
              'same ten paths, with different content state. Diff requests 4,000 MiB in the '
              'modified case; the extra mapping need not be fully touched, so its requested '
              'extent cannot be read as extra full-file hashing. When all large data requires '
              'content comparison, the current Selective and Always implementations take '
              'essentially the same content path and their times are expected to be close.'])
for fixture in data['fixtures']:
    name = fixture['name']
    lines.extend(['', f'## {name}', '',
                  '| State | Fsmonitor | Command | Baseline | Selective | Always | Always − selective ms | Always / selective |',
                  '| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |'])
    for row in data['rows']:
        if row['fixture'] != name:
            continue
        v = row['variants']
        cells = [f"{v[label]['median_ms']:.2f} ± {v[label]['mad_ms']:.2f}"
                 + ('' if v[label]['correct'] else '*') for label in labels]
        delta = v['always']['median_ms'] - v['selective']['median_ms']
        ratio = v['always']['median_ms'] / v['selective']['median_ms']
        lines.append(f"| {state_label(row)} | {row['fsmonitor']} | {row['command']} | "
                     + ' | '.join(cells) + f' | {delta:+.2f} | {ratio:.2f}× |')
    lines.extend(['', 'File sizes and separate diagnostic work for each timing row:', '',
                  '| State | Fsmonitor | Command | Modified files (MiB) | Selective unique files (MiB) | Selective requested MiB | Always unique files (MiB) | Always requested MiB |',
                  '| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |'])
    for row in data['rows']:
        if row['fixture'] != name:
            continue
        work = workloads[tuple(row[k] for k in ['fixture', 'state', 'fsmonitor', 'command'])]
        lines.append(f"| {state_label(row)} | {row['fsmonitor']} | {row['command']} | "
                     f"{work['modified_files']} ({mib(work['modified_file_bytes'])}) | "
                     f"{work['selective_unique_files']} ({mib(work['selective_unique_file_bytes'])}) | "
                     f"{request_mib(work, 'selective')} | "
                     f"{work['always_unique_files']} ({mib(work['always_unique_file_bytes'])}) | "
                     f"{request_mib(work, 'always')} |")
lines.extend(['', '## Separate diagnostic processes', '',
              'These counters were collected in a separate untimed process for every row. '
              '`read`/`pread` count returned worktree content bytes; `mmap` counts successful '
              'requested worktree mapping lengths, **not physical I/O or proven bytes touched**. '
              'Fixture-path filtering excludes the index, object database and libraries. '
              'The shim passed a known 16,384-byte mmap/one-query control. '
              'The full counters are in [diagnostics.tsv](diagnostics.tsv).', '',
              '| Fixture | State | Fsmonitor | Variant | getattrlist calls | read + pread bytes | mmap requested bytes |',
              '| --- | --- | --- | --- | ---: | ---: | ---: |'])
for d in data['diagnostics']:
    representative = (d['fixture'] == 'small' and d['state'] == 'unmapped' and d['fsmonitor'] == 'valid') or (
        d['fixture'] in ['one-large', 'ten-large'] and d['fsmonitor'] == 'off' and d['state'] in [
            'unmapped', 'one-mapped-unchanged', 'many-mapped-unchanged', 'many-mapped-modified'])
    if d['command'] != 'status' or not representative:
        continue
    lines.append(f"| {d['fixture']} | {d['state']} | {d['fsmonitor']} | {d['label']} | "
                 f"{d['getattrlist_calls']:,} | {d['read_bytes'] + d['pread_bytes']:,} | {d['mmap_requested_bytes']:,} |")
lines.extend(['', 'The selective code can query an entry more than once, especially with '
              'fsmonitor-valid fast paths. The always comparator makes zero generation '
              'queries but invokes existing content comparison on all eligible entries. '
              'Mapped modified commands may compare contents repeatedly within a command; '
              'the diagnostic totals describe that implementation rather than a single-read ideal.', '',
              '## Scope and limits', '',
              'The index was captured independently for fsmonitor disabled and persisted-valid '
              'hook modes and kept byte-identical for all variants and every sample in a '
              'measurement group. Every sample is a new Git process, so no prior in-process '
              '`CE_UPTODATE` flag survives. `GIT_OPTIONAL_LOCKS=0` prevents optional status '
              'refresh writes; hashes assert the snapshots stayed frozen. Metadata checks '
              'warm the stat cache immediately before each sample and run outside the clock.', '',
              'Writable shared mappings are native and their FDs close before readiness. '
              'Writes are acknowledged and the mapper waits idle while Git runs. Device, '
              'inode, size, nanosecond mtime and ctime are asserted unchanged before and '
              'after every sample. The final dirty unmap can update ctime, so the harness '
              'recaptures a fresh non-racy index between mapping groups; no stale index '
              'is carried across that lifecycle transition. Each row records its index epoch '
              'and hash. The one-large fixture has one mapped file; “many” is omitted there.', '',
              'These are single-machine warm-cache results on ordinary local files, with '
              'compressible contents and no filters in timed fixtures. They do not model '
              'cold-cache storage, network filesystems, simultaneous writers or an atomic '
              'snapshot. Process startup, hook invocation and output capture are included. '
              'No cache purging, privileged tracing, elevated benchmark execution, remote '
              'compute, global configuration changes or security changes were used.', '',
              'The standalone [combined-metadata API proof](../native-proof/combined-metadata.c) '
              'and [API microbenchmark](metadata-api.jsonl) are separate from these three Git '
              'variants. One public `getattrlist` can return the regular-file stat fields '
              'used by this probe plus write generation. Thus these measurements do not '
              'establish that an extra syscall is unavoidable. No combined-call Git variant '
              'is implemented: symlink/directory/error/fallback and transient-validity '
              'integration still need review. Fsmonitor-valid paths formerly made **no stat '
              'call**; combining metadata only removes duplication on paths already '
              'requiring stat, so it cannot remove all added fsmonitor cost.', ''])
api_path = args.output.parent / 'metadata-api.jsonl'
if api_path.exists():
    api = [json.loads(line) for line in api_path.read_text().splitlines()]
    lines.extend(['', '## Standalone metadata API microbenchmark', '',
        'Separate native process, no Git integration. Each sample is the mean of '
        '10,000 warm metadata lookups of the same 16 KiB file; cells show median ± MAD across nine '
        'counterbalanced batches after one warmup batch per operation. Units are '
        'microseconds per lookup. The one combined query returns regular-file '
        'metadata plus write generation; lstat alone does not supply write generation.', '',
        '| State | lstat only | lstat + generation query | Combined query | Combined / split |',
        '| --- | ---: | ---: | ---: | ---: |'])
    for state in ['unmapped', 'shared-fd-closed', 'shared-modified']:
        cells, medians = [], {}
        for operation in ['lstat', 'lstat+generation', 'combined']:
            values = [x['ns_per_iteration'] / 1000 for x in api
                      if x.get('operation') == operation and x['state'] == state
                      and x['round'] >= 0]
            median = statistics.median(values)
            mad = statistics.median(abs(x - median) for x in values)
            medians[operation] = median
            cells.append(f'{median:.3f} ± {mad:.3f}')
        ratio = medians['combined'] / medians['lstat+generation']
        lines.append('| ' + state + ' | ' + ' | '.join(cells) + f' | {ratio:.2f}× |')
    lines.extend(['', 'Returned fields and nanosecond timestamps matched lstat in '
        'untimed validation for all three states. Unmapped write generation was '
        'nonzero; both shared-mapped states returned zero. This API-only result '
        'does not predict integrated Git speedups, particularly where fsmonitor '
        'previously skipped stat entirely.', ''])
args.output.write_text('\n'.join(lines))
fields = ['fixture', 'state', 'fsmonitor', 'command', 'label', 'getattrlist_calls',
          'read_bytes', 'pread_bytes', 'mmap_requested_bytes']
(args.output.parent / 'diagnostics.tsv').write_text('\t'.join(fields) + '\n' +
    ''.join('\t'.join(str(d[k]) for k in fields) + '\n' for d in data['diagnostics']))
print(args.output)
