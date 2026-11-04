#!/usr/bin/env python3
"""Run strict metadata regressions on an owned, verified noatime APFS volume.

Ordinary-volume package smoke tests remain separate. Reads can advance atime
there; a noatime pass must not be reported as an unchanged-atime guarantee.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import threading
import time


def run(args, **kwargs):
    return subprocess.run([str(x) for x in args], check=True, **kwargs)


def stat(path):
    s = path.stat()
    return dict(atime_ns=s.st_atime_ns, mtime_ns=s.st_mtime_ns,
                ctime_ns=s.st_ctime_ns, inode=s.st_ino, mode=s.st_mode)


def read_probe(root):
    path = root / 'ordinary-read-control'
    path.write_bytes(b'ordinary read control\n')
    now = time.time_ns()
    os.utime(path, ns=(now - 120_000_000_000, now - 60_000_000_000))
    before = stat(path)
    assert path.read_bytes() == b'ordinary read control\n'
    after = stat(path)
    path.unlink()
    return dict(before=before, after=after,
                atime_changed=before['atime_ns'] != after['atime_ns'])


def suite(source, arch, root, name, args=()):
    result = subprocess.run(['/usr/bin/arch', arch, '/bin/sh', './' + name,
                             '--verbose-log', '-x', '--root=' + str(root), *args],
                            cwd=source / 't')
    if result.returncode:
        log = source / 't/test-results' / (name[:-3] + '.out')
        print(log.read_text() if log.exists() else 'Suite did not produce a log: ' + name,
              flush=True)
    return result.returncode


def retain_reader_trace(stream, log, capture):
    # Keep fixture events from any reader and related descriptor activity.
    # Drain the pipe after the bound so tracing cannot block the test process.
    descriptors = set()
    for line in stream:
        fields = line.split()
        process = fields[-1] if fields else ''
        fd = re.search(r'\bF=(\d+)', line)
        key = (process, fd[1]) if fd else None
        fixture = re.search(r'\b(?:plain|crlf)\b', line) or 'ordinary-root' in line
        if fixture and key and len(fields) > 1 and fields[1].startswith('open'):
            descriptors.add(key)
        if fixture or key in descriptors or line.startswith(('fs_usage:', 'sudo:')):
            size = len(line.encode('utf-8'))
            if capture['bytes'] + size <= capture['limit_bytes']:
                log.write(line)
                capture['bytes'] += size
            else:
                capture['truncated'] = True
        if key and len(fields) > 1 and fields[1].startswith('close'):
            descriptors.discard(key)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--source', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--arch', choices=['arm64', 'x64'], required=True)
    a = p.parse_args()
    source, out = a.source.resolve(), a.output.resolve()
    suites = sorted((source / 't').glob('t241[0-6]-*.sh'))
    assert len(suites) == 7, 'Expected all seven focused source suites'
    out.mkdir(parents=True)
    arch = '-x86_64' if a.arch == 'x64' else '-arm64'
    report = dict(architecture=a.arch, strict_metadata_condition='APFS noatime',
                  ordinary_volume_unchanged_atime_guarantee=False, suites={})
    report['git_build_options'] = subprocess.check_output(
        ['/usr/bin/arch', arch, str(source / 'git'), 'version', '--build-options'], text=True)
    report['ordinary_read_control'] = read_probe(out)

    # Preserve evidence from the original environment, including already-shared
    # and hardlink skips. This diagnostic is not the strict regression gate.
    if a.arch == 'x64':
        ordinary = out / 'ordinary-root'
        ordinary.mkdir()
        with (out / 'ordinary-fs-usage.log').open('w') as log:
            capture = dict(bytes=0, limit_bytes=16_000_000, truncated=False)
            report['fs_usage_capture'] = capture
            tracer = subprocess.Popen(['sudo', '-n', '/usr/bin/fs_usage', '-w',
                                       '-f', 'filesys', '-t', '30'],
                                      stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                      text=True, errors='replace')
            reader = threading.Thread(target=retain_reader_trace,
                                      args=(tracer.stdout, log, capture), daemon=True)
            reader.start()
            time.sleep(1)
            try:
                report['ordinary_metadata_diagnostic_exit'] = suite(
                    source, arch, ordinary, 't2416-worktree-reflink.sh',
                    ['--run=1,5,19'])
            finally:
                report['fs_usage_exit'] = tracer.wait(timeout=40)
                reader.join(timeout=5)
                assert not reader.is_alive(), 'Filesystem trace did not drain'
        results = out / 'ordinary-test-results'
        results.mkdir()
        for f in (source / 't/test-results').glob('t2416-worktree-reflink.*'):
            (results / f.name).write_bytes(f.read_bytes())

    image, volume = out / 'metadata.sparseimage', out / 'metadata-volume'
    volume.mkdir()
    run(['hdiutil', 'create', '-quiet', '-size', '2g', '-type', 'SPARSE',
         '-fs', 'APFS', '-volname', 'PwrGitMetadataTests', image])
    attached = False
    try:
        run(['hdiutil', 'attach', '-nobrowse', '-owners', 'on',
             '-mountpoint', volume, image])
        attached = True
        run(['sudo', '-n', '/sbin/mount', '-u', '-o', 'noatime', volume])
        mounts = subprocess.check_output(['/sbin/mount'], text=True).splitlines()
        mount = next(line for line in mounts if ' on ' + str(volume) + ' (' in line)
        flags = mount.rsplit(' (', 1)[1].rstrip(')').split(', ')
        assert 'apfs' in flags and 'noatime' in flags, mount
        report['mount'] = mount
        report['controlled_read_control'] = read_probe(volume)
        assert not report['controlled_read_control']['atime_changed']
        print('Strict metadata regressions: verified APFS noatime; ordinary-volume '
              'access-time behavior is recorded separately.', flush=True)
        for path in suites:
            report['suites'][path.name] = suite(source, arch, volume, path.name)
    finally:
        (out / 'conditions.json').write_text(json.dumps(report, indent=2) + '\n')
        if attached:
            run(['hdiutil', 'detach', volume])
        image.unlink()
    return int(any(report['suites'].values()))


if __name__ == '__main__':
    raise SystemExit(main())
