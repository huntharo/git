#!/usr/bin/env python3
"""Bundle non-glibc ELF dependencies, notices and exact Debian source inputs.

The baseline container uses an immutable Ubuntu snapshot for both architectures.
Only glibc and its ELF loader remain system requirements. RPATH changes happen
before sealing the runtime; original dependency sources remain unmodified.
"""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

from runtime import package, run, sha256, write_json

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('root', type=Path)
p.add_argument('--output', type=Path, required=True)
p.add_argument('--arch', choices=['x64', 'arm64'], required=True)
a = p.parse_args()
root = a.root.resolve()
lib = root / 'lib'
lib.mkdir()
notices = root / 'share/licenses/dependencies'
notices.mkdir(parents=True)
shutil.copytree('/usr/share/common-licenses', notices / 'common-licenses', symlinks=False)
sources = a.output / 'library-sources'
sources.mkdir()
glibc = re.compile(r'^(lib(c|m|dl|rt|pthread|resolv|util|anl)\.so\.|ld-linux|ld64)')
libraries = {}
elfs = []
for path in sorted(root.rglob('*')):
    if path.is_symlink() or not path.is_file():
        continue
    with path.open('rb') as stream:
        if stream.read(4) != b'\x7fELF':
            continue
    elfs.append(path)
    result = subprocess.run(['ldd', str(path)], capture_output=True, text=True)
    if 'not found' in result.stdout:
        raise ValueError(f'Unresolved dependency: {path}: {result.stdout}')
    for line in result.stdout.splitlines():
        match = re.match(r'\s*(\S+) => (/\S+) ', line)
        if not match:
            continue
        name, location = match.groups()
        if glibc.match(name):
            continue
        original = Path(location).resolve()
        if name in libraries and libraries[name]['original_sha256'] != sha256(original):
            raise ValueError(f'Conflicting dependency: {name}')
        package_name = run(['dpkg-query', '-S', str(original)]).split(': /', 1)[0]
        metadata = run(['dpkg-query', '-W', '-f=${source:Package}\t${source:Version}\t${Version}', package_name]).split('\t')
        source_name, source_version, binary_version = metadata
        libraries[name] = dict(original=str(original), original_sha256=sha256(original),
                               package=package_name, binary_version=binary_version,
                               source_package=source_name, source_version=source_version,
                               modification='ELF RPATH changed to $ORIGIN; original source unmodified')
        shutil.copy2(original, lib / name)
        copyright_file = Path('/usr/share/doc') / package_name.split(':')[0] / 'copyright'
        if not copyright_file.is_file():
            raise ValueError(f'Missing dependency notice: {package_name}')
        shutil.copy2(copyright_file, notices / (package_name.replace(':', '-') + '.copyright'))
for source_name, source_version in sorted({(x['source_package'], x['source_version']) for x in libraries.values()}):
    subprocess.run(['apt-get', 'source', '--download-only', f'{source_name}={source_version}'], cwd=sources, check=True)
for path in [*elfs, *(lib / name for name in libraries)]:
    # Go's static LFS binary has no dynamic section and needs no RPATH.
    if 'NEEDED' not in run(['readelf', '-d', path]):
        continue
    relative_lib = os.path.relpath(lib, path.parent)
    run(['patchelf', '--force-rpath', '--set-rpath', '$ORIGIN' + ('' if relative_lib == '.' else '/' + relative_lib), path])
for name, metadata in libraries.items():
    metadata['packaged_sha256'] = sha256(lib / name)
write_json(root / 'linux-libraries.json', dict(schema=1, baseline_glibc='2.35', libraries=libraries,
           source_files={p.name: sha256(p) for p in sorted(sources.iterdir()) if p.is_file()}))
(a.output / 'linux-packages.txt').write_text(run(['dpkg-query', '-W', '-f=${binary:Package}\t${Version}\n']) + '\n')
package(sources, a.output / f'linux-library-sources-{a.arch}.tar.gz')
print(json.dumps({'bundled_libraries': len(libraries), 'glibc_baseline': '2.35'}))
