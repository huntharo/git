#!/usr/bin/env python3
"""Render reproducible Markdown tables from bench.py's raw samples."""
import argparse
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
        lines.append(f"| {row['state']} | {row['fsmonitor']} | {row['command']} | "
                     + ' | '.join(cells) + f' | {delta:+.2f} | {ratio:.2f}× |')
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
