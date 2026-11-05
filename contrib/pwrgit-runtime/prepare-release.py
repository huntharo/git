#!/usr/bin/env python3
"""Assemble immutable release files and the manifest shared by both apps."""
import argparse
import json
from pathlib import Path
import re
import shutil
import tarfile

from runtime import HERE, sha256, write_json

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--inputs', type=Path, required=True)
p.add_argument('--output', type=Path, required=True)
p.add_argument('--tag', required=True)
p.add_argument('--run-url', required=True)
p.add_argument('--expected-macos-sha256', required=True)
a = p.parse_args()
a.output.mkdir(exist_ok=False)
catalog = {'schema': 1, 'assets': {}, 'build_run': a.run_url, 'consumer_sha256': sha256(HERE / 'stage-runtime.mjs')}
for path in sorted(a.inputs.rglob('*.tar.gz')):
    name = path.name
    if name == 'git-source.tar.gz':
        name = f'git-source-{sha256(path)}.tar.gz'
    if name == 'macos-signing-input.tar.gz':
        continue
    if '-candidate' in name:
        if '-linux-' not in name:
            continue
        name = name.replace('-candidate', '')
    dest = a.output / name
    if dest.exists():
        if sha256(dest) != sha256(path):
            raise ValueError(f'Ambiguous source/build input: {name}')
        continue
    shutil.copy2(path, dest)
    if not re.search(r'-(darwin-universal|linux-(x64|arm64))\.tar\.gz$', name):
        continue
    with tarfile.open(path) as tar:
        members = {x.name.removeprefix('./'): x for x in tar.getmembers()}
        with tar.extractfile(members['pwrgit-build.json']) as stream:
            m = json.load(stream)
        with tar.extractfile(members['runtime-files.json']) as stream:
            import hashlib
            inventory_sha256 = hashlib.sha256(stream.read()).hexdigest()
    if a.tag != 'v' + m['version'] or m['primary_sha1'] != 'SHA1_DC':
        raise ValueError('Release tag, version or primary hash protection mismatch')
    for field in ('version', 'source_revision', 'source_pull_requests'):
        if field in catalog and catalog[field] != m[field]:
            raise ValueError(f'Release source set differs: {field}')
        catalog[field] = m[field]
    key = f'{m["platform"]}-{m["architecture"]}'
    entry = dict(url=f'https://github.com/huntharo/git/releases/download/{a.tag}/{name}',
                 sha256=sha256(path), inventory_sha256=inventory_sha256,
                 minimum_os=m['minimum_os'], minimum_os_tested=m['minimum_os_tested'],
                 signing=m['signing'], notarized=m['notarized'])
    if m['platform'] == 'darwin':
        if sha256(path) != a.expected_macos_sha256 or m['signing'] != 'Developer ID Application: PwrDrvr LLC (T44CNHC4UH)' or m['notarized'] is not True:
            raise ValueError('Mac payload must match protected signer output and Accepted notarization')
        entry['team_id'] = 'T44CNHC4UH'
    else:
        entry['ca_bundle'] = m['ca_bundle']
    if key in catalog['assets']:
        raise ValueError(f'Duplicate runtime: {key}')
    catalog['assets'][key] = entry
if set(catalog['assets']) != {'darwin-universal', 'linux-x64', 'linux-arm64'}:
    raise ValueError('The complete approved platform set is required')
write_json(a.output / 'runtime-manifest.json', catalog)
for report in sorted(a.inputs.rglob('*.json')):
    # Validation report names are scoped by artifact, avoiding same-name overwrites.
    if report.name in ('verify.json', 'smoke.json') or report.name.startswith('sharing-'):
        artifact = report.relative_to(a.inputs).parts[0]
        shutil.copy2(report, a.output / f'{artifact}-{report.name}')
feature_notes = ''
if 10 in catalog['source_pull_requests']:
    feature_notes += 'APFS clone repair batches mode and timestamps in one descriptor operation; the experimental allocation-query replacement is not applied.\n'
if 11 in catalog['source_pull_requests']:
    feature_notes += 'APFS re-sharing leaves kernel-managed com.apple.provenance to macOS; all other xattrs, including quarantine, still require exact equality.\n'
(a.output / 'RELEASE-NOTES.txt').write_text(
    f'Custom Git {catalog["version"]}\n\nExact C source: {catalog["source_revision"]}\n'
    'This is a custom build of the 2.56 development line, not a final upstream 2.56 release.\n'
    'Included source PRs: ' + ', '.join(f'#{n}' for n in catalog['source_pull_requests']) + '.\n'
    'Includes conversion-aware checkout, git worktree reflink, and enabled hard-reset re-sharing.\n'
    + feature_notes +
    'Runtime config includes /etc/gitconfig and retains the Azure DevOps useHttpPath rule.\n'
    'The runtime does not force checkout.reflink; apps and normal Git configuration control enablement.\n'
    'Existing donor/stat trust remains; this does not acquire PR #1 donor verification.\n'
    'APFS replacement changes inode/ctime. Do not use writable mmap or retain writable descriptors across replacement; ordinary writes after the last check can also race rename. Read-only object/pack mappings are unaffected.\n'
    'Git LFS 3.7.1, helpers, templates, notices, sources, symbols and checksums are included.\n'
    'macOS: final universal executables signed by PwrDrvr LLC (T44CNHC4UH) and accepted by Apple notarization.\n'
    'Linux: x64/ARM64, bundled non-glibc libraries and their exact source inputs; glibc 2.35 baseline.\n'
    'Linux includes the checksum-pinned Mozilla CA bundle at ssl/cacert.pem (MPL-2.0), matching Dugite; macOS keeps its native trust behavior.\n'
    'The macOS 13 deployment target is not an older-OS execution guarantee. See the explicit tested state in the manifest and attached reports.\n'
    'Known Git/APFS stat-trust and writable-mmap blind spots still apply. No arbitrary concurrent-writer guarantee is made.\n'
    'Both apps pin runtime-manifest.json and preserve the same macOS executable bytes/signatures. Each app still needs its own notarization.\n'
    f'Build and validation: {a.run_url}\n')
(a.output / 'SHA256SUMS').write_text(''.join(f'{sha256(p)}  {p.name}\n' for p in sorted(a.output.iterdir()) if p.is_file()))
print(json.dumps(catalog, sort_keys=True))
