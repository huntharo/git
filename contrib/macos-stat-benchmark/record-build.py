#!/usr/bin/env python3
"""Record the current checkout's sequential build and copy the executable."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

root = Path(os.environ.get('BENCH_HARNESS_ROOT', Path(__file__).resolve().parent))
label = sys.argv[1]
output = root / 'local' / label
output.mkdir(exist_ok=True, parents=True)
saved_sha = sys.argv[2] if len(sys.argv) > 2 else None
if not saved_sha:
    shutil.copyfile('git', output / 'git')
(output / 'git').chmod(0o755)
def run(*args):
    return subprocess.check_output(args, text=True).strip()
metadata = root / 'local' / 'builds.json'
data = json.loads(metadata.read_text()) if metadata.exists() else {}
data[label] = {
    'sha': saved_sha or run('git', 'rev-parse', 'HEAD'),
    'source_changes': '' if saved_sha else run('git', 'diff', '--', ':!contrib/macos-stat-benchmark'),
    'binary_sha256': hashlib.sha256((output / 'git').read_bytes()).hexdigest(),
    'binary': str(output / 'git'),
    'make_command': "make -j8 NO_GETTEXT=YesPlease CFLAGS='-O2 -g' git",
    'compiler': run('cc', '--version'),
    'build_options': run(str(output / 'git'), 'version', '--build-options'),
    'make_cflags': None if saved_sha else Path('GIT-CFLAGS').read_text(),
    'make_build_options': Path('GIT-BUILD-OPTIONS').read_text() if Path('GIT-BUILD-OPTIONS').exists() else None,
    'log': f'local/build-{label}.log',
}
assert not data[label]['source_changes']
metadata.write_text(json.dumps(data, indent=2) + '\n')
print(label, data[label]['sha'], data[label]['binary_sha256'])
