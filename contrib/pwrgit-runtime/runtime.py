#!/usr/bin/env python3
"""Shared, fail-closed archive and payload operations for the Git distribution."""
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import tarfile
import urllib.request
import zipfile

HERE = Path(__file__).resolve().parent
MACHO = {b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca'}


def run(args, **kwargs):
    return subprocess.check_output([str(x) for x in args], **kwargs).decode().strip()


def sha256(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def write_json(path, data):
    Path(path).write_text(json.dumps(data, indent=2, sort_keys=True) + '\n')


def download(url, checksum, destination):
    if not url.startswith('https://github.com/') or len(checksum) != 64:
        raise ValueError('Expected a checksum-pinned GitHub HTTPS dependency')
    destination = Path(destination)
    if not destination.exists() or sha256(destination) != checksum:
        partial = destination.with_suffix('.partial')
        with urllib.request.urlopen(url, timeout=120) as inp, partial.open('wb') as out:
            import shutil
            shutil.copyfileobj(inp, out)
        if sha256(partial) != checksum:
            partial.unlink()
            raise ValueError(f'Dependency checksum mismatch: {url}')
        partial.replace(destination)
    return destination


def extract(archive, destination):
    # Python's data filter rejects escaping links, devices and traversal.
    with tarfile.open(archive) as tar:
        tar.extractall(destination, filter='data')


def is_macho(path):
    if path.is_symlink() or not path.is_file():
        return False
    with path.open('rb') as stream:
        return stream.read(4) in MACHO


def inventory(root):
    root = Path(root)
    files = {}
    for path in sorted(root.rglob('*')):
        name = path.relative_to(root).as_posix()
        if name == 'runtime-files.json':
            continue
        if path.is_symlink():
            target = os.readlink(path)
            if not path.resolve().is_relative_to(root.resolve()):
                raise ValueError(f'Escaping symlink: {name}')
            files[name] = {'link': target}
        elif path.is_file():
            files[name] = {'sha256': sha256(path), 'mode': stat.S_IMODE(path.stat().st_mode)}
    return files


def seal(root):
    write_json(Path(root) / 'runtime-files.json', inventory(root))


def verify_inventory(root):
    expected = json.loads((Path(root) / 'runtime-files.json').read_text())
    if inventory(root) != expected:
        raise ValueError('Runtime bytes, modes, symlinks or file set differ from sealed payload')


def package(root, archive):
    # dereference=False preserves Git helper symlinks, without external paths.
    with tarfile.open(archive, 'w:gz', dereference=False) as tar:
        for child in sorted(Path(root).iterdir()):
            tar.add(child, arcname=child.name)
    Path(str(archive) + '.sha256').write_text(f'{sha256(archive)}  {Path(archive).name}\n')


def unpack_lfs(archive, output):
    # Only the expected executable and notices are read; no installer executes.
    if zipfile.is_zipfile(archive):
        with zipfile.ZipFile(archive) as z:
            candidates = [x for x in z.namelist() if x.endswith('/git-lfs')]
            if len(candidates) != 1:
                raise ValueError('Ambiguous LFS executable')
            output.write_bytes(z.read(candidates[0]))
    else:
        with tarfile.open(archive) as t:
            candidates = [x for x in t.getmembers() if x.name.endswith('/git-lfs') and x.isfile()]
            if len(candidates) != 1:
                raise ValueError('Ambiguous LFS executable')
            with t.extractfile(candidates[0]) as stream:
                output.write_bytes(stream.read())
    output.chmod(0o755)
