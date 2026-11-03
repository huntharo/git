#!/usr/bin/env python3
"""Build a full optimized POSIX application runtime from an immutable Git commit.

Adapted from desktop/dugite-native build-macos.sh/build-ubuntu.sh (MIT).
Unlike its Windows recipe, this never substitutes an upstream MinGit binary.
"""
import argparse
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess

from runtime import HERE, download, extract, is_macho, package, run, seal, sha256, unpack_lfs, write_json

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--output', type=Path, required=True)
p.add_argument('--arch', choices=['arm64', 'x64'], required=True)
p.add_argument('--jobs', type=int, default=4)
p.add_argument('--resume', action='store_true', help='Re-extract pinned source and run incremental make in this build directory')
p.add_argument('--lock', type=Path, default=HERE / 'build-lock.json')
a = p.parse_args()
lock = json.loads(a.lock.read_text())
host = {'Darwin': 'darwin', 'Linux': 'linux'}[platform.system()]
arch = 'x86_64' if a.arch == 'x64' else 'arm64'
if host == 'linux' and platform.machine() not in ({'x86_64', 'amd64'} if a.arch == 'x64' else {'aarch64', 'arm64'}):
    p.error('Linux builds require a native runner/container for the selected architecture')
out = a.output.resolve()
out.mkdir(parents=True, exist_ok=a.resume)
source = out / 'source'
source.mkdir(exist_ok=a.resume)
stage = out / 'stage'
root = stage / 'pwrgit'
revision = lock['source']['revision']
repo = HERE.parents[1]
if run(['git', 'rev-parse', revision], cwd=repo) != revision:
    raise ValueError('Source must be a full immutable commit SHA')
archive = out / 'git-source.tar.gz'
with archive.open('wb') as stream:
    subprocess.run(['git', 'archive', '--format=tar.gz', revision], cwd=repo, stdout=stream, check=True)
extract(archive, source)
env = {k: v for k, v in os.environ.items() if not k.startswith(('GIT_', 'DYLD_'))}
env.update(GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull,
           GIT_ATTR_NOSYSTEM='1', GIT_VERSION=lock['version'],
           GIT_BUILT_FROM_COMMIT=revision, GIT_DATE=run(['git', 'show', '-s', '--format=%cs', revision], cwd=repo),
           SOURCE_DATE_EPOCH=run(['git', 'show', '-s', '--format=%ct', revision], cwd=repo))
flags = ['NO_RUST=1', 'NO_GETTEXT=1', 'NO_TCLTK=1', 'NO_PERL=1',
         'RUNTIME_PREFIX=YesPlease', 'INSTALL_SYMLINKS=YesPlease', 'prefix=/pwrgit',
         'CFLAGS=-g -O2 -Wall -fstack-protector-strong']
if host == 'darwin':
    env['MACOSX_DEPLOYMENT_TARGET'] = lock['macos_deployment_target']
    flags += ['NO_HOMEBREW=1', 'NO_DARWIN_PORTS=1', 'CURL_CONFIG=/usr/bin/curl-config',
              'APPLE_COMMON_CRYPTO_SHA1_UNSAFE=1', f'CC=clang -arch {arch}', f'HOST_CPU={arch}']
else:
    # SHA1_DC remains primary; no SHA1_UNSAFE or SHA1_APPLE replaces it.
    flags += ['NO_OPENSSL=1']


def make(targets, log):
    with (out / log).open('w') as stream:
        subprocess.run(['make', f'-j{a.jobs}', *flags, *targets], cwd=source, env=env,
                       stdout=stream, stderr=subprocess.STDOUT, check=True)


print(f'Building {host}-{a.arch} {lock["version"]} from {revision} (-j{a.jobs})', flush=True)
make(['all', 't/helper/test-tool'], 'build.log')
make([f'DESTDIR={stage}', 'install'], 'install.log')
if host == 'darwin':
    helper = 'contrib/credential/osxkeychain/git-credential-osxkeychain'
    make([helper], 'keychain.log')
    shutil.copy2(source / helper, root / 'libexec/git-core/git-credential-osxkeychain')
dependency = next(x for x in lock['lfs']['files'] if x['platform'] == host and x['arch'] == ('amd64' if a.arch == 'x64' else 'arm64'))
lfs = download(dependency['url'], dependency['checksum'], out / dependency['filename'])
unpack_lfs(lfs, root / 'libexec/git-core/git-lfs')
(root / 'bin/git-lfs').unlink(missing_ok=True)
(root / 'bin/git-lfs').symlink_to('../libexec/git-core/git-lfs')
shutil.copy2(source / 'COPYING', root / 'COPYING')
shutil.copy2(source / 'LGPL-2.1', root / 'LGPL-2.1')
# Upstream LFS binary archives omit the license. Take it from pinned source.
import tarfile
lfs_source = download(lock['lfs_source']['url'], lock['lfs_source']['sha256'], out / 'git-lfs-source.tar.gz')
with tarfile.open(lfs_source) as t:
    licenses = [x for x in t.getmembers() if x.name.endswith('/LICENSE.md') and x.isfile()]
    if len(licenses) != 1:
        raise ValueError('Missing LFS license')
    with t.extractfile(licenses[0]) as stream:
        (root / 'LICENSE.git-lfs').write_bytes(stream.read())
(root / 'etc').mkdir(exist_ok=True)
(root / 'etc/gitconfig').write_text('[checkout]\n\treflink = true\n')
(root / 'SOURCES').write_text(
    f'Git {lock["version"]}: {lock["source"]["repository"]}/tree/{revision}\n'
    'Git is a separate GPL-2.0-only command-line program. Enclosing apps retain their licenses.\n'
    f'Complete matching source: git-source.tar.gz (SHA256 {sha256(archive)}) beside this release.\n'
    f'Git LFS {lock["lfs"]["version"]}: https://github.com/git-lfs/git-lfs/tree/{lock["lfs"]["version"]}\n'
    f'Unmodified upstream LFS input: {dependency["url"]}\nSHA256: {dependency["checksum"]}\n'
    'Build lock, build scripts and dependency notices accompany the release.\n'
    'Git helpers use system shell/SSH and OS credential integration; no GCM/.NET runtime is included.\n')
debug = out / 'symbols'
debug.mkdir(exist_ok=a.resume)
for path in sorted(root.rglob('*')):
    if path.is_symlink() or not path.is_file():
        continue
    if host == 'darwin' and is_macho(path):
        if path.name != 'git-lfs':
            symbol = debug / path.relative_to(root)
            symbol.parent.mkdir(parents=True, exist_ok=True)
            run(['dsymutil', path, '-o', str(symbol) + '.dSYM'])
            run(['strip', '-S', path])
        # Final Developer ID signing happens only after universal merging.
        run(['codesign', '--force', '--sign', '-', '--timestamp=none', path])
    elif host == 'linux' and path.read_bytes()[:4] == b'\x7fELF':
        if path.name != 'git-lfs':
            symbol = debug / path.relative_to(root)
            symbol.parent.mkdir(parents=True, exist_ok=True)
            run(['objcopy', '--only-keep-debug', path, str(symbol) + '.debug'])
            run(['strip', '--strip-debug', path])
manifest = dict(schema=1, version=lock['version'], source_revision=revision,
                recipe_files={p.name: sha256(p) for p in sorted(HERE.iterdir()) if p.is_file()},
                recipe_revision=run(['git', 'rev-parse', 'HEAD'], cwd=repo),
                platform=host, architecture=a.arch, flags=flags,
                primary_sha1='SHA1_DC', secondary_sha1='Apple CommonCrypto' if host == 'darwin' else 'builtin',
                signing='ad-hoc' if host == 'darwin' else 'unsigned', notarized=False,
                lfs=dependency, lfs_source=lock['lfs_source'], lfs_version=lock['lfs']['version'].lstrip('v'),
                source_archive_sha256=sha256(archive), recipe_reference=lock['recipe_reference'],
                minimum_os=lock['macos_deployment_target'] if host == 'darwin' else 'glibc ' + lock['linux_glibc_baseline'],
                minimum_os_tested=False, build_host=platform.platform(),
                source_date_epoch=env['SOURCE_DATE_EPOCH'],
                compiler=run(['clang' if host == 'darwin' else 'cc', '--version']),
                lfs_debug_symbols='Not provided in upstream prebuilt release',
                optional_components_omitted=['Perl commands', 'Tcl/Tk GUI', 'gettext translations', 'Rust', 'GCM'])
write_json(root / 'pwrgit-build.json', manifest)
seal(root)
package(root, out / f'pwrgit-{lock["version"]}-{revision[:7]}-{host}-{a.arch}-candidate.tar.gz')
package(debug, out / f'pwrgit-{lock["version"]}-{revision[:7]}-{host}-{a.arch}-symbols.tar.gz')
shutil.copy2(a.lock, out / 'build-lock.json')
print(f'Built candidate: {root}', flush=True)
