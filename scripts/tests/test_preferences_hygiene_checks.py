import importlib.util
from pathlib import Path
import tempfile
import unittest

source = Path(__file__).with_name("test_preferences_hygiene.py")
spec = importlib.util.spec_from_file_location("preferences_hygiene", source)
hygiene = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hygiene)


class PreferenceHygieneChecks(unittest.TestCase):
    def testMissingDirectoryIsAnEmptyBaseline(self):
        with tempfile.TemporaryDirectory() as temporary:
            self.assertEqual(hygiene.preference_files(Path(temporary) / "missing"), set())

    def testInventoryIncludesEveryClipShelfDomainAndIgnoresOtherApplications(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name in ("ClipShelf.cleanup-tests.fixture.plist", "io.github.bestbbb.clipshelf.dev.plist", "other-app.plist"):
                (root / name).write_bytes(b"fixture")
            (root / "clipshelf-directory").mkdir()
            self.assertEqual(hygiene.preference_files(root),
                             {"ClipShelf.cleanup-tests.fixture.plist", "io.github.bestbbb.clipshelf.dev.plist"})

    def testAddedAndRemovedPreferenceFilesAreDetectedSeparately(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            old = root / "clipshelf-old.plist"
            old.write_bytes(b"fixture")
            before = hygiene.preference_files(root)
            old.unlink()
            (root / "clipshelf-new.plist").write_bytes(b"fixture")
            after = hygiene.preference_files(root)
            self.assertEqual(after - before, {"clipshelf-new.plist"})
            self.assertEqual(before - after, {"clipshelf-old.plist"})
