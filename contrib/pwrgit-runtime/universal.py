#!/usr/bin/env python3
"""Merge completed macOS slices before Developer ID signing, never afterwards."""
import argparse
import json
from pathlib import Path
import shutil

from runtime import inventory, is_macho, package, run, seal, verify_inventory, write_json

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--arm64', type=Path, required=True)
p.add_argument('--x64', type=Path, required=True)
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
for root in (a.arm64, a.x64):
    verify_inventory(root)
manifests = [json.loads((x / 'pwrgit-build.json').read_text()) for x in (a.arm64, a.x64)]
for field in ('version', 'source_revision', 'primary_sha1', 'source_archive_sha256', 'minimum_os', 'lfs_version'):
    if manifests[0][field] != manifests[1][field]:
        raise ValueError(f'Slice provenance differs: {field}')
if [m['architecture'] for m in manifests] != ['arm64', 'x64'] or any(m['platform'] != 'darwin' for m in manifests):
    raise ValueError('Expected macOS arm64 and x64 slices')
if any(m['signing'] != 'ad-hoc' for m in manifests):
    raise ValueError('Refusing to modify Developer ID signed inputs')
left, right = inventory(a.arm64), inventory(a.x64)
if left.keys() != right.keys():
    raise ValueError('Slice file sets differ')
if a.output.exists():
    raise ValueError('Universal destination already exists')
shutil.copytree(a.arm64, a.output, symlinks=True)
for name in left:
    if name in ('pwrgit-build.json', 'SOURCES'):
        continue
    src, other, dest = a.arm64 / name, a.x64 / name, a.output / name
    if is_macho(src):
        if not is_macho(other):
            raise ValueError(f'Non-Mach-O slice: {name}')
        run(['lipo', '-create', src, other, '-output', dest])
        if set(run(['lipo', '-archs', dest]).split()) != {'arm64', 'x86_64'}:
            raise ValueError(f'Missing universal slice: {name}')
        run(['codesign', '--force', '--sign', '-', '--timestamp=none', dest])
    elif left[name] != right[name]:
        raise ValueError(f'Architecture-dependent data file: {name}')
manifest = dict(manifests[0], architecture='universal', slices=manifests)
write_json(a.output / 'pwrgit-build.json', manifest)
(a.output / 'SOURCES').write_text(
    'Universal payload; the two original slice notices follow. Exact inputs and flags are in pwrgit-build.json.\n\n'
    + '\n'.join((root / 'SOURCES').read_text() for root in (a.arm64, a.x64)))
seal(a.output)
package(a.output, a.output.parent / f'pwrgit-{manifest["version"]}-{manifest["source_revision"][:7]}-darwin-universal-candidate.tar.gz')
print(a.output)
