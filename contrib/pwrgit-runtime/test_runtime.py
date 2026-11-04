import io
import errno
import importlib.util
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

from runtime import extract, ldd_dependencies, seal, verify_inventory


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

    def test_only_metadata_suite_uses_image_and_other_failures_remain_fatal(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name).resolve()
        source, out = root / 'source', root / 'output'
        (source / 't').mkdir(parents=True)
        names = [f't241{i}-fixture.sh' for i in range(6)] + ['t2416-worktree-reflink.sh']
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
                patch.object(self.macos, 'suite', side_effect=[1, 0, 0, 0, 0, 0, 0]) as suite, \
                patch.object(self.macos, 'detach_volume') as detach:
            self.assertEqual(self.macos.main(), 1)
        self.assertEqual(suite.call_count, 7)
        self.assertEqual([c.args[2] for c in suite.call_args_list[:6]], [source / 't'] * 6)
        self.assertEqual(suite.call_args_list[-1].args[2], out / 'metadata-volume')
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
