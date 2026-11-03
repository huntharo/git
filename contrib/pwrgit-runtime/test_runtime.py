import io
from pathlib import Path
import tarfile
import tempfile
import unittest

from runtime import extract, seal, verify_inventory


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


if __name__ == '__main__':
    unittest.main()
