#!/usr/bin/env python3
"""Synthetic failure cases; never open an app or use a signing identity."""
import pathlib
import plistlib
import subprocess
import tempfile
import unittest


SCRIPT = pathlib.Path(__file__).resolve().with_name("embed-sparkle.sh")


class EmbedSparkleTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="clipshelf-embed-test-")
        self.root = pathlib.Path(self.temporary.name)
        self.app = self.root / "ClipShelf.app"
        (self.app / "Contents/MacOS").mkdir(parents=True)
        self.installed = self.app / "Contents/Frameworks/Sparkle.framework"
        self.installed.mkdir(parents=True)
        (self.installed / "existing").write_text("prior working bundle")
        self.source = self.root / "source/Sparkle.framework"
        resources = self.source / "Versions/B/Resources"
        resources.mkdir(parents=True)
        with (resources / "Info.plist").open("wb") as stream:
            plistlib.dump({"CFBundleShortVersionString": "2.10.0"}, stream)
        (self.source / "Versions/Current").symlink_to("B")
        (self.source / "Resources").symlink_to("Versions/Current/Resources")

    def tearDown(self):
        self.temporary.cleanup()

    def rejected(self, expected):
        result = subprocess.run(["/bin/bash", str(SCRIPT), str(self.source), str(self.app)],
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(expected, result.stderr)
        self.assertEqual((self.installed / "existing").read_text(), "prior working bundle")
        self.assertEqual(list(self.installed.parent.glob(".sparkle-embed.*")), [])

    def testWrongPinnedVersionCannotReplacePriorFramework(self):
        with (self.source / "Resources/Info.plist").open("wb") as stream:
            plistlib.dump({"CFBundleShortVersionString": "1.0.0"}, stream)
        self.rejected("expected pinned Sparkle 2.10.0")

    def testUnexpectedVersionLinkIsRejected(self):
        (self.source / "Versions/Current").unlink()
        (self.source / "Versions/Current").symlink_to("../Versions/B")
        self.rejected("unexpected framework version link")

    def testMissingHelperCannotReplacePriorFramework(self):
        self.rejected("missing helper XPCServices/Installer.xpc")

    def testSymlinkedDestinationCannotWriteOutsideBundle(self):
        frameworks = self.installed.parent
        outside = self.root / "outside"
        frameworks.rename(outside)
        frameworks.symlink_to(outside, target_is_directory=True)
        self.rejected("bundle destination must not be a symlink")

    def testReleaseBundleRejectsMissingOrAdHocIdentityBeforeBuilding(self):
        for identity in ["", "-"]:
            with self.subTest(identity=identity):
                result = subprocess.run(
                    ["/bin/bash", str(SCRIPT.with_name("build-macos.sh"))],
                    env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CLIPSHELF_DISTRIBUTION": "release",
                         "CODESIGN_IDENTITY": identity, "CLIPSHELF_APP_OUTPUT": str(self.app)},
                    capture_output=True, text=True, timeout=10)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("requires an explicit Developer ID Application", result.stderr)
                self.assertFalse((self.app / "Contents/Info.plist").exists())


if __name__ == "__main__":
    unittest.main()
