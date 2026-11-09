#!/usr/bin/env python3
"""Independent structural/correctness audit of completed benchmark artifacts."""
import hashlib
import csv
import json
from pathlib import Path
import sys

root = Path(sys.argv[1])
data = json.loads((root / 'results.json').read_text())
assert data['profile'] == 'full'
assert data['finished_utc']
assert len(data['rows']) == 72
assert len(data['diagnostics']) == 216
assert len(data['fixtures']) == 4
assert data['parameters']['repetitions'] == 9
assert data['parameters']['warmups'] == 2
incorrect = 0
samples = 0
for row in data['rows']:
    assert len(row['samples']) == 27
    assert len(row['warmups']) == 6
    info = next(x for x in data['fixtures'] if x['name'] == row['fixture'])
    assert info['invariants_passed']
    assert row['index_sha256'] == info['index_epochs'][row['index_epoch']]['sha256'][row['fsmonitor']]
    expected = ''.join((' M ' if row['command'] == 'status' else '') + name + '\n'
                       for name in row['expected_paths'])
    for label in data['binaries']:
        selected = [s for s in row['samples'] if s['label'] == label]
        assert len(selected) == 9
        assert [sum(s['position'] == pos for s in selected) for pos in range(3)] == [3, 3, 3]
    for sample in row['samples'] + row['warmups']:
        assert sample['returncode'] == 0
        assert sample['correct'] == (sample['stdout'] == expected)
        if sample['label'] == 'baseline' and row['expected_paths']:
            assert not sample['correct'] and sample['stdout'] == ''
        else:
            assert sample['correct']
    incorrect += sum(not s['correct'] for s in row['samples'])
    samples += len(row['samples'])
assert incorrect == 252
for fixture in data['fixtures']:
    assert fixture['generation_before_mapping']
    assert all(fixture['generation_before_mapping'])
assert all(d['getattrlist_calls'] == 0 for d in data['diagnostics'] if d['label'] in ['baseline', 'always'])
assert all(d['getattrlist_calls'] > 0 for d in data['diagnostics'] if d['label'] == 'selective')
with (root / 'workloads.tsv').open(newline='') as stream:
    workload_rows = list(csv.DictReader(stream, delimiter='\t'))
assert len(workload_rows) == len(data['rows'])
for work, row in zip(workload_rows, data['rows']):
    assert all(work[k] == row[k] for k in ['fixture', 'state', 'fsmonitor', 'command'])
    fixture = next(f for f in data['fixtures'] if f['name'] == row['fixture'])
    assert work['case_role'] == ('nominal expected' if row['state'] == 'unmapped' else 'mapped stress case')
    assert int(work['mapped_files']) == row['mapped_files']
    assert int(work['mapped_bytes']) == row['mapped_bytes']
    assert int(work['modified_files']) == len(row['expected_paths'])
    assert int(work['modified_file_bytes']) == (row['mapped_bytes'] if row['expected_paths'] else 0)
    for label in ['selective', 'always']:
        assert int(work[label + '_unique_files']) == (row['mapped_files'] if label == 'selective' else fixture['files'])
        unique_bytes = row['mapped_bytes'] if label == 'selective' else fixture['bytes']
        assert int(work[label + '_unique_file_bytes']) == unique_bytes
        counter = next(d for d in data['diagnostics'] if d['label'] == label
                       and all(d[k] == row[k] for k in ['fixture', 'state', 'fsmonitor', 'command']))
        fields = ['read_bytes', 'pread_bytes', 'mmap_requested_bytes']
        for field in fields:
            assert int(work[label + '_' + field]) == counter[field]
        total = sum(counter[field] for field in fields)
        assert int(work[label + '_total_content_request_bytes']) == total
        # The diagnostic extents include repeated comparisons; mmap lengths
        # do not establish how many bytes were actually touched or hashed.
        passes = (3 if row['command'] == 'status' else 4) if row['expected_paths'] else 1
        expected = row['mapped_bytes'] * passes if label == 'selective' else fixture['bytes'] + (passes - 1) * row['mapped_bytes']
        assert total == expected
assert (root / 'focused-adapted.log').read_text().rstrip().endswith('Result: PASS')
assert (root / 'focused-original.log').read_text().rstrip().endswith('Result: FAIL')
proof = [json.loads(line) for line in (root / 'combined-proof.jsonl').read_text().splitlines()]
assert len(proof) == 8 and all(x['git_stat_fields_match'] for x in proof)
for mode in ['shared', 'private']:
    rows = [p for p in proof if p['mapping'] == mode]
    assert len(rows) == 4
    assert len({(p['mtime_sec'], p['mtime_ns'], p['ctime_sec'], p['ctime_ns']) for p in rows[:3]}) == 1
    assert all(p['lstat_st_gen'] == p['fstatat_st_gen'] == 0 for p in rows)
    assert rows[0]['write_generation'] > 0
    if mode == 'shared':
        assert all(p['write_generation'] == 0 for p in rows[1:3])
    else:
        assert all(p['write_generation'] > 0 for p in rows)
api = [json.loads(line) for line in (root / 'metadata-api.jsonl').read_text().splitlines()]
validation = [p for p in api if 'git_stat_fields_match' in p]
assert len(validation) == 3 and all(p['git_stat_fields_match'] for p in validation)
assert len({(p['mtime_sec'], p['mtime_ns'], p['ctime_sec'], p['ctime_ns']) for p in validation}) == 1
assert validation[0]['write_generation'] > 0
assert validation[1]['write_generation'] == validation[2]['write_generation'] == 0
api_samples = [p for p in api if 'operation' in p and p['round'] >= 0]
assert len(api_samples) == 81
assert all(p['iterations'] == 10000 and p['ns_per_iteration'] > 0 for p in api_samples)
manifest = {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
            for p in root.iterdir() if p.is_file() and p.name != 'audit.json'}
output = dict(passed=True, rows=72, measured_samples=samples,
              incorrect_baseline_samples=incorrect, diagnostics=216,
              workload_rows=len(workload_rows), content_request_volume_checks=2 * len(workload_rows),
              proof_snapshots=8, metadata_api_measured_batches=81,
              artifact_sha256=manifest)
(root / 'audit.json').write_text(json.dumps(output, indent=2) + '\n')
print(json.dumps({k: v for k, v in output.items() if k != 'artifact_sha256'}))
