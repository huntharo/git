import io
from pathlib import Path
import tarfile
import tempfile
import unittest

from runtime import extract, ldd_dependencies, seal, verify_inventory


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
