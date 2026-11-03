#!/usr/bin/env python3
"""Verify a relocated extracted payload, every executable and its provenance."""
import argparse
import json
import os
from pathlib import Path
import platform
import re
import tempfile

from runtime import is_macho, run, verify_inventory, write_json

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('root', type=Path)
p.add_argument('--require-signed', action='store_true')
p.add_argument('--report', type=Path)
a = p.parse_args()
root = a.root.resolve()
verify_inventory(root)
m = json.loads((root / 'pwrgit-build.json').read_text())
if m['primary_sha1'] != 'SHA1_DC' or not re.fullmatch('[0-9a-f]{40}', m['source_revision']):
    raise ValueError('Invalid source/hash provenance')
if a.require_signed and (m['signing'] != 'Developer ID Application: PwrDrvr LLC (T44CNHC4UH)' or m['notarized'] is not True):
    raise ValueError('Expected notarized PwrDrvr payload')
env = {k: v for k, v in os.environ.items() if not k.startswith(('GIT_', 'DYLD_', 'LD_'))}
env.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_ATTR_NOSYSTEM='1',
           PATH=str(root / 'bin') + os.pathsep + '/usr/bin:/bin:/usr/sbin:/sbin',
           GIT_TERMINAL_PROMPT='0')
git = root / 'bin/git'
assert run([git, '--version'], env=env) == 'git version ' + m['version']
build_options = run([git, 'version', '--build-options'], env=env).splitlines()
if 'SHA-1: SHA1_DC' not in build_options or 'built from commit: ' + m['source_revision'] not in build_options:
    raise ValueError('Executable source revision or primary SHA1_DC protection differs from provenance')
assert run([git, '--exec-path'], env=env) == str(root / 'libexec/git-core')
assert run([git, 'lfs', 'version'], env=env).startswith('git-lfs/' + m['lfs_version'] + ' ')
assert (root / 'share/git-core/templates/hooks').is_dir()
for name in ['COPYING', 'LICENSE.git-lfs', 'SOURCES']:
    assert (root / name).is_file(), name
executables = {}
for path in sorted(root.rglob('*')):
    if platform.system() == 'Linux' and path.is_file() and not path.is_symlink():
        with path.open('rb') as stream:
            elf = stream.read(4) == b'\x7fELF'
        if elf:
            versions = {(int(x), int(y)) for x, y in re.findall(r'GLIBC_(\d+)\.(\d+)', run(['readelf', '--version-info', path]))}
            assert not versions or max(versions) <= (2, 35), (path, versions)
            deps = run(['ldd', path], env=env) if 'NEEDED' in run(['readelf', '-d', path]) else 'static'
            assert 'not found' not in deps, (path, deps)
            for name, target in re.findall(r'(\S+) => (/\S+)', deps):
                if not re.match(r'lib(c|m|dl|rt|pthread|resolv|util|anl)\.so\.', name):
                    assert Path(target).resolve().is_relative_to(root), (path, name, target)
            executables[path.relative_to(root).as_posix()] = {'dependencies': deps, 'glibc_versions': sorted(versions)}
    if not is_macho(path):
        continue
    arches = run(['lipo', '-archs', path]).split()
    expected = {'arm64', 'x86_64'} if m['architecture'] == 'universal' else {'arm64' if m['architecture'] == 'arm64' else 'x86_64'}
    assert set(arches) == expected, (path, arches)
    deps = [x.strip() for x in run(['otool', '-L', path]).splitlines() if x.startswith('\t')]
    assert all(x.strip().startswith(('/usr/lib/', '/System/Library/')) for x in deps), (path, deps)
    command = ['codesign', '--verify', '--all-architectures', '--strict']
    if a.require_signed:
        command += ['--test-requirement', '=anchor apple generic and certificate leaf[subject.OU] = "T44CNHC4UH"']
    run([*command, path])
    executables[path.relative_to(root).as_posix()] = {'architectures': arches, 'dependencies': deps}
with tempfile.TemporaryDirectory(prefix='pwrgit-relocated-') as tmp:
    repo = Path(tmp) / 'repo'
    run([git, 'init', repo], env=env)
    assert (repo / '.git/hooks/pre-commit.sample').is_file()
    if platform.system() == 'Darwin':
        # Empty input tests helper launch without retrieving or storing credentials.
        run([git, 'credential-osxkeychain', 'get'], input=b'\n', env=env)
    # Resolution must be through the relocated exec path. This command does not
    # make a network request and fails after the helper validates the protocol.
    try:
        run([git, 'remote-https', 'origin', 'invalid://pwrgit.invalid/repository'], input=b'capabilities\n', env=env)
    except Exception as error:
        if not hasattr(error, 'returncode'):
            raise
result = dict(version=m['version'], source_revision=m['source_revision'],
              build_options=build_options,
              architecture=m['architecture'], sealed_inventory=True,
              relocated_exec_path=True, lfs=True, templates=True, executables=executables)
if a.report:
    write_json(a.report, result)
print(json.dumps({k: v for k, v in result.items() if k != 'executables'}, sort_keys=True))
