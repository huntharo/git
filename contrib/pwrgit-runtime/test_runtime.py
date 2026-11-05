import io
import errno
import importlib.util
import hashlib
import json
from pathlib import Path
import subprocess
import shutil
import tarfile
import tempfile
import unittest
from unittest.mock import patch

from runtime import download, extract, ldd_dependencies, seal, verify_inventory
from configuration import verify_configuration
from certificates import install_ca_bundle, verify_ca_bundle


class CertificateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.runtime = self.root / 'runtime'
        self.runtime.mkdir()
        self.entry = json.loads(Path(__file__).with_name('build-lock.json').read_text())['ca_bundle']

    def test_install_uses_pinned_bytes_and_seals_exact_dugite_path(self):
        data = b'cached fixture CA input'
        entry = dict(self.entry, sha256=hashlib.sha256(data).hexdigest())
        (self.root / Path(entry['url']).name).write_bytes(data)
        with patch('runtime.urllib.request.urlopen') as network:
            install_ca_bundle(self.runtime, self.root, entry)
        network.assert_not_called()
        target = self.runtime / 'ssl/cacert.pem'
        self.assertEqual(target.read_bytes(), data)
        self.assertEqual(target.stat().st_mode & 0o777, 0o644)
        self.assertIn(entry['url'], (self.runtime / 'NOTICE.ca-bundle').read_text())
        seal(self.runtime)
        inventory = json.loads((self.runtime / 'runtime-files.json').read_text())
        self.assertEqual(inventory['ssl/cacert.pem']['sha256'], entry['sha256'])
        target.write_bytes(b'changed CA input')
        with self.assertRaises(ValueError):
            verify_inventory(self.runtime)

    def test_linux_requires_its_bundle(self):
        with self.assertRaisesRegex(ValueError, 'regular, readable'):
            verify_ca_bundle(self.runtime, dict(platform='linux', ca_bundle=self.entry))

    def test_macos_does_not_gain_a_ca_override(self):
        self.assertIsNone(verify_ca_bundle(self.runtime, dict(platform='darwin')))
        (self.runtime / 'ssl').mkdir()
        (self.runtime / 'ssl/cacert.pem').write_bytes(b'wrong platform')
        with self.assertRaises(ValueError):
            verify_ca_bundle(self.runtime, dict(platform='darwin'))

    def test_download_verifies_dated_curl_input_and_cache(self):
        data = b'fixed input'
        checksum = hashlib.sha256(data).hexdigest()
        target = self.root / 'download.pem'
        with patch('runtime.urllib.request.urlopen', return_value=io.BytesIO(data)) as network:
            self.assertEqual(download(self.entry['url'], checksum, target), target)
            self.assertEqual(download(self.entry['url'], checksum, target), target)
        self.assertEqual(network.call_count, 1)
        self.assertEqual(target.read_bytes(), data)

    def test_download_rejects_mutable_or_unapproved_ca_urls(self):
        for url in ('https://curl.se/ca/cacert.pem', 'http://curl.se/ca/cacert-2026-10-20.pem',
                    'https://curl.se.example/ca/cacert-2026-10-20.pem',
                    self.entry['url'] + '?latest=true'):
            with self.subTest(url=url), self.assertRaises(ValueError):
                download(url, '0' * 64, self.root / 'rejected')

    def test_download_rejects_wrong_checksum_without_publishing_file(self):
        target = self.root / 'download.pem'
        with patch('runtime.urllib.request.urlopen', return_value=io.BytesIO(b'wrong')):
            with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
                download(self.entry['url'], '0' * 64, target)
        self.assertFalse(target.exists())
        self.assertFalse(target.with_suffix('.partial').exists())


class ConfigurationTests(unittest.TestCase):
    def test_system_global_repository_and_explicit_overrides(self):
        import os
        result = verify_configuration(shutil.which('git'), Path(__file__).with_name('gitconfig'), os.environ)
        self.assertTrue(result['system_global_repository_visible'])
        self.assertTrue(result['includes_and_precedence'])
        self.assertTrue(result['explicit_system_override'])
        self.assertTrue(result['nosystem_honored'])

    def test_previous_runtime_config_regression_is_rejected(self):
        import os
        with tempfile.TemporaryDirectory() as tmp:
            config = Path(tmp) / 'gitconfig'
            config.write_text('[checkout]\n\treflink = true\n')
            with self.assertRaises(subprocess.CalledProcessError):
                verify_configuration(shutil.which('git'), config, os.environ)


class MacOSCleanupTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location(
            'runtime_macos_tests', Path(__file__).with_name('test-macos.py'))
        cls.macos = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.macos)

    def detach_result(self, code):
        return subprocess.CompletedProcess(['hdiutil', 'detach', '/owned/image'], code)

    def test_busy_volume_released_during_grace_period(self):
        with patch.object(self.macos.subprocess, 'run', side_effect=[
                self.detach_result(errno.EBUSY), self.detach_result(0)]) as detach, \
                patch.object(self.macos.time, 'sleep') as sleep:
            self.macos.detach_volume(Path('/owned/image'))
        self.assertEqual(detach.call_count, 2)
        sleep.assert_called_once_with(1)
        self.assertTrue(all(c.args[0] == ['hdiutil', 'detach', '/owned/image']
                            for c in detach.call_args_list))

    def test_persistently_busy_volume_fails_without_force(self):
        with patch.object(self.macos.subprocess, 'run',
                          return_value=self.detach_result(errno.EBUSY)) as detach, \
                patch.object(self.macos.time, 'sleep') as sleep:
            with self.assertRaises(subprocess.CalledProcessError):
                self.macos.detach_volume(Path('/owned/image'))
        self.assertEqual(detach.call_count, 5)
        self.assertEqual([c.args[0] for c in sleep.call_args_list], [1, 2, 4, 8])
        self.assertTrue(all('-force' not in c.args[0] for c in detach.call_args_list))

    def test_nonbusy_failure_is_not_retried(self):
        with patch.object(self.macos.subprocess, 'run',
                          return_value=self.detach_result(1)) as detach, \
                patch.object(self.macos.time, 'sleep') as sleep:
            with self.assertRaises(subprocess.CalledProcessError):
                self.macos.detach_volume(Path('/owned/image'))
        detach.assert_called_once()
        sleep.assert_not_called()

    def test_metadata_suites_use_image_and_interposers_match_both_slices(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name).resolve()
        source, out = root / 'source', root / 'output'
        (source / 't').mkdir(parents=True)
        names = [f't241{i}-fixture.sh' for i in range(6)] + [
            't2416-worktree-reflink.sh', 't2417-apfs-metadata.sh']
        for name in names:
            (source / 't' / name).touch()

        def fake_run(args):
            if args[:2] == ['hdiutil', 'create']:
                args[-1].write_bytes(b'owned image')

        argv = ['test-macos.py', '--arch', 'arm64', '--source', str(source),
                '--output', str(out)]
        mount = f'/dev/owned on {out}/metadata-volume (apfs, noatime)\n'
        with patch('sys.argv', argv), patch('sys.stdout', io.StringIO()), \
                patch.object(self.macos, 'run', side_effect=fake_run), \
                patch.object(self.macos.subprocess, 'check_output',
                             side_effect=['git build options', mount]), \
                patch.object(self.macos, 'read_probe', return_value={'atime_changed': False}), \
                patch.object(self.macos, 'suite', side_effect=[1, 0, 0, 0, 0, 0, 0, 0]) as suite, \
                patch.object(self.macos, 'detach_volume') as detach:
            self.assertEqual(self.macos.main(), 1)
        self.assertEqual(suite.call_count, 8)
        self.assertEqual([c.args[2] for c in suite.call_args_list[:6]], [source / 't'] * 6)
        self.assertEqual([c.args[2] for c in suite.call_args_list[-2:]],
                         [out / 'metadata-volume'] * 2)
        self.assertEqual(suite.call_args_list[-1].args[3], 't2417-apfs-metadata.sh')
        oracle_path = suite.call_args_list[-1].kwargs['env']['PATH'].split(':')[0]
        self.assertEqual(Path(oracle_path), out / 'interposer-compiler')
        self.assertIn('clang -arch arm64 -arch x86_64 "$@"',
                      (Path(oracle_path) / 'cc').read_text())
        conditions = json.loads((out / 'conditions.json').read_text())
        self.assertEqual(conditions['strict_metadata_suites'], names[-2:])
        self.assertEqual(conditions['ordinary_volume_suites'], names[:6])
        detach.assert_called_once_with(out / 'metadata-volume')
        self.assertFalse((out / 'metadata.sparseimage').exists())


class InventoryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / 'runtime'
        self.root.mkdir()
        (self.root / 'git').write_bytes(b'original bytes')
        (self.root / 'alias').symlink_to('git')
        seal(self.root)

    def test_relocated_inventory(self):
        other = self.root.with_name('a path with spaces')
        self.root.rename(other)
        verify_inventory(other)

    def test_changed_content(self):
        (self.root / 'git').write_bytes(b'changed bytes')
        with self.assertRaises(ValueError):
            verify_inventory(self.root)

    def test_changed_mode(self):
        path = self.root / 'git'
        path.chmod(path.stat().st_mode ^ 0o100)
        with self.assertRaises(ValueError):
            verify_inventory(self.root)

    def test_extra_file(self):
        (self.root / 'extra').write_bytes(b'unapproved')
        with self.assertRaises(ValueError):
            verify_inventory(self.root)

    def test_escaping_symlink(self):
        (self.root / 'alias').unlink()
        (self.root / 'alias').symlink_to('../outside')
        with self.assertRaises(ValueError):
            verify_inventory(self.root)

    def test_escaping_archive(self):
        archive = self.root.parent / 'escape.tar'
        with tarfile.open(archive, 'w') as tar:
            item = tarfile.TarInfo('../outside')
            item.size = 4
            tar.addfile(item, io.BytesIO(b'evil'))
        with self.assertRaises(tarfile.FilterError):
            extract(archive, self.root)
        self.assertFalse((self.root.parent / 'outside').exists())

    def archive_with_link(self, name, target, *, hard=False, following=None):
        archive = self.root.parent / 'link.tar'
        with tarfile.open(archive, 'w') as tar:
            source = tarfile.TarInfo('git-gui/content')
            source.size = 4
            tar.addfile(source, io.BytesIO(b'data'))
            link = tarfile.TarInfo(name)
            link.type = tarfile.LNKTYPE if hard else tarfile.SYMTYPE
            link.linkname = target
            tar.addfile(link)
            if following:
                source.name = following
                tar.addfile(source, io.BytesIO(b'data'))
        return archive

    def test_internal_parent_relative_source_symlink(self):
        archive = self.archive_with_link('subprojects/git-gui', '../git-gui')
        extract(archive, self.root)
        self.assertEqual((self.root / 'subprojects/git-gui').readlink(), Path('../git-gui'))
        self.assertEqual((self.root / 'subprojects/git-gui/content').read_bytes(), b'data')

    def test_root_relative_hard_link(self):
        archive = self.archive_with_link('subprojects/content', 'git-gui/content', hard=True)
        extract(archive, self.root)
        self.assertEqual((self.root / 'subprojects/content').stat().st_ino,
                         (self.root / 'git-gui/content').stat().st_ino)

    def test_external_archive_symlinks(self):
        for target in ('../../outside', str(self.root.parent / 'outside')):
            with self.subTest(target=target):
                archive = self.archive_with_link('subprojects/link', target)
                with self.assertRaises(tarfile.FilterError):
                    extract(archive, self.root)
                self.assertFalse((self.root / 'subprojects/link').is_symlink())

    def test_archive_cannot_write_through_escaping_link(self):
        archive = self.archive_with_link('subprojects/link', '../../outside',
                                         following='subprojects/link/content')
        with self.assertRaises(tarfile.FilterError):
            extract(archive, self.root)
        self.assertFalse((self.root.parent / 'outside').exists())

    def test_archive_cannot_follow_existing_external_parent(self):
        (self.root / 'subprojects').symlink_to(self.root.parent)
        archive = self.archive_with_link('subprojects/link', 'git-gui')
        with self.assertRaises(tarfile.FilterError):
            extract(archive, self.root)
        self.assertFalse((self.root.parent / 'link').is_symlink())


class DependencyTests(unittest.TestCase):
    def test_paths_with_spaces_and_parentheses(self):
        self.assertEqual(ldd_dependencies('''
        linux-vdso.so.1 (0x0000ffff)
        libz.so.1 => /out/relocated runtime (test)/lib/libz.so.1 (0x0000aaaa)
        libc.so.6 => /lib/aarch64-linux-gnu/libc.so.6 (0x0000bbbb)
        /lib/ld-linux-aarch64.so.1 (0x0000cccc)
'''), [('libz.so.1', '/out/relocated runtime (test)/lib/libz.so.1'),
       ('libc.so.6', '/lib/aarch64-linux-gnu/libc.so.6')])

    def test_missing_or_malformed_mapping_is_rejected(self):
        for output in ('libz.so.1 => not found', 'libz.so.1 => /out/lib/libz.so.1'):
            with self.subTest(output=output), self.assertRaises(ValueError):
                ldd_dependencies(output)


if __name__ == '__main__':
    unittest.main()
