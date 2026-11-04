"""Install and verify the Linux CA file at Dugite's existing payload path."""
from pathlib import Path
import shutil
import ssl

from runtime import HERE, download, sha256


def install_ca_bundle(root, output, entry):
    root, output = Path(root), Path(output)
    if entry['path'] != 'ssl/cacert.pem' or entry['license'] != 'MPL-2.0':
        raise ValueError('Unexpected CA path or license')
    source = download(entry['url'], entry['sha256'], output / Path(entry['url']).name)
    license_file = HERE / 'MPL-2.0'
    if sha256(license_file) != entry['license_sha256']:
        raise ValueError('CA license checksum mismatch')
    target = root / entry['path']
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, target)
    target.chmod(0o644)
    shutil.copy2(license_file, root / 'LICENSE.ca-bundle')
    (root / 'NOTICE.ca-bundle').write_text(
        'Mozilla CA certificate bundle, converted to PEM by curl.\n'
        f'Unmodified readable source input: {entry["url"]}\n'
        f'Bundle date: {entry["date"]}\nSHA256: {entry["sha256"]}\n'
        'The original PEM header, certificate data and notices are retained.\n'
        'This file is governed by the Mozilla Public License 2.0; see LICENSE.ca-bundle.\n'
        f'License source: {entry["license_source"]}\n'
        'Upstream extraction/source information: https://curl.se/docs/caextract.html\n'
        'Dugite-compatible installed path: ssl/cacert.pem.\n')


def verify_ca_bundle(root, manifest):
    root = Path(root)
    target = root / 'ssl/cacert.pem'
    if manifest['platform'] != 'linux':
        if target.exists() or target.is_symlink() or 'ca_bundle' in manifest:
            raise ValueError('The macOS runtime must keep its native trust behavior')
        return None
    entry = manifest['ca_bundle']
    if entry['path'] != 'ssl/cacert.pem' or entry['license'] != 'MPL-2.0':
        raise ValueError('Unexpected CA path or license')
    if target.is_symlink() or not target.is_file() or target.stat().st_mode & 0o444 != 0o444:
        raise ValueError('Linux runtime requires a regular, readable ssl/cacert.pem')
    if sha256(target) != entry['sha256']:
        raise ValueError('CA bundle checksum mismatch')
    if sha256(root / 'LICENSE.ca-bundle') != entry['license_sha256']:
        raise ValueError('CA license checksum mismatch')
    if entry['url'] not in (root / 'NOTICE.ca-bundle').read_text():
        raise ValueError('CA source notice missing')
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.load_verify_locations(cafile=str(target))
    count = context.cert_store_stats()['x509_ca']
    if count != entry['certificate_count']:
        raise ValueError('Unexpected parsed CA certificate count')
    return dict(path=entry['path'], sha256=entry['sha256'],
                certificates=count, date=entry['date'], license=entry['license'])
