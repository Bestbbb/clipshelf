"""Release gates and real Sparkle/CryptoKit interoperability using public test seeds.

No app launch, network request, Developer ID identity, Keychain, notarization or
installation. Set CLIPSHELF_TEST_SPARKLE_BIN to an already resolved official bin
directory when SwiftPM's default native/.build artifact location is not used.
"""
import base64
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("release_pipeline", ROOT / "scripts/release-macos.py")
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)
NS = release.SPARKLE_NS
# RFC 8032's public first Ed25519 test vector; never use this key outside tests.
TEST_SEED = bytes.fromhex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
TEST_PUBLIC = bytes.fromhex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")
OTHER_PUBLIC = bytes.fromhex("3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c")


def write_test_key(path):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as stream:
        stream.write(base64.b64encode(TEST_SEED) + b"\n")


class ReleasePipelineTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="clipshelf-release-pipeline-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.app = self.root / "ClipShelf.app"
        self.extension = self.app / "Contents/PlugIns/ClipShelfShare.appex"
        self.sparkle = self.app / "Contents/Frameworks/Sparkle.framework"
        self.manifest = {
            "appBundleIdentifier": "io.example.clipshelf", "shareBundleIdentifier": "io.example.clipshelf.share",
            "version": "1.2.3", "buildNumber": "42", "teamID": "ABCDE12345",
            "appGroupIdentifier": "group.io.example.clipshelf",
            "updateFeedURL": "https://updates.example.invalid/stable/appcast.xml",
            "updatePublicEDKey": base64.b64encode(TEST_PUBLIC).decode(),
            "provisioningProfiles": {"io.example.clipshelf": "App Profile", "io.example.clipshelf.share": "Share Profile"},
            "paths": {key: str(self.root / (key + " with spaces.plist")) for key in
                      ["appInfoPlist", "shareInfoPlist", "appEntitlements", "shareEntitlements", "exportOptionsPlist"]},
        }
        common = {"CFBundleVersion": "42", "CFBundleShortVersionString": "1.2.3",
                  "ClipShelfAppGroupIdentifier": self.manifest["appGroupIdentifier"]}
        self.main_info = dict(common, CFBundleIdentifier="io.example.clipshelf", ClipShelfDistribution="release",
                              SUFeedURL=self.manifest["updateFeedURL"], SUPublicEDKey=self.manifest["updatePublicEDKey"],
                              SUVerifyUpdateBeforeExtraction=True, SURequireSignedFeed=True,
                              SUSignedFeedFailureExpirationInterval=0, SUEnableSystemProfiling=False,
                              SUEnableAutomaticChecks=False, SUAutomaticallyUpdate=False)
        self.extension_info = dict(common, CFBundleIdentifier="io.example.clipshelf.share")
        self.write_plist(self.app / "Contents/Info.plist", self.main_info)
        self.write_plist(self.extension / "Contents/Info.plist", self.extension_info)
        self.write_plist(self.sparkle / "Resources/Info.plist", {"CFBundleShortVersionString": "2.10.0"})
        (self.app / "Contents/Resources/Metadata.appintents").mkdir(parents=True)
        (self.app / "Contents/Resources/Sparkle-LICENSE.txt").write_bytes(
            (ROOT / "native/Sources/ClipShelf/Sparkle-LICENSE.txt").read_bytes())
        self.archive = self.root / "ClipShelf 1.2.3-42.zip"
        self.archive.write_bytes(b"synthetic archive bytes, not an installable app")
        self.feed = self.root / "appcast.xml"
        self.prefix = "https://updates.example.invalid/archives/"

    def write_plist(self, path, values):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(plistlib.dumps(values))

    def appcast(self):
        root = ET.Element("rss", version="2.0")
        item = ET.SubElement(ET.SubElement(root, "channel"), "item")
        ET.SubElement(item, NS + "version").text = "42"
        enclosure = ET.SubElement(item, "enclosure", {
            "url": self.prefix + "ClipShelf%201.2.3-42.zip", "length": str(self.archive.stat().st_size),
            NS + "edSignature": base64.b64encode(bytes(range(64))).decode(),
        })
        return root, item, enclosure

    def save_feed(self, root):
        self.feed.write_bytes(ET.tostring(root, encoding="utf-8", xml_declaration=True))

    def testMatchingBundleMetadataAndPinnedFrameworkPass(self):
        self.assertEqual(release.verify_plists(self.app, self.manifest), (self.extension, self.sparkle))

    def testAppAndExtensionIdentityVersionAndGroupCannotDrift(self):
        for bundle, original in [(self.app, self.main_info), (self.extension, self.extension_info)]:
            for field in ["CFBundleIdentifier", "CFBundleVersion", "CFBundleShortVersionString", "ClipShelfAppGroupIdentifier"]:
                with self.subTest(bundle=bundle.name, field=field):
                    self.write_plist(bundle / "Contents/Info.plist", dict(original, **{field: "wrong"}))
                    with self.assertRaises(ValueError):
                        release.verify_plists(self.app, self.manifest)
                    self.write_plist(bundle / "Contents/Info.plist", original)

    def testReleaseRequiresExactTypedSecurityPolicy(self):
        invalid = {"ClipShelfDistribution": "development", "SUFeedURL": "http://example.invalid/feed.xml",
                   "SUPublicEDKey": base64.b64encode(OTHER_PUBLIC).decode(), "SURequireSignedFeed": 1,
                   "SUVerifyUpdateBeforeExtraction": False, "SUSignedFeedFailureExpirationInterval": False,
                   "SUEnableSystemProfiling": True, "SUEnableAutomaticChecks": True, "SUAutomaticallyUpdate": True}
        for field, value in invalid.items():
            with self.subTest(field=field):
                self.write_plist(self.app / "Contents/Info.plist", dict(self.main_info, **{field: value}))
                with self.assertRaises(ValueError):
                    release.verify_plists(self.app, self.manifest)
        self.write_plist(self.app / "Contents/Info.plist", self.main_info)

    def testMissingIntentMetadataAndWrongSparkleVersionReject(self):
        metadata = self.app / "Contents/Resources/Metadata.appintents"
        metadata.rmdir()
        with self.assertRaises(ValueError):
            release.verify_plists(self.app, self.manifest)
        metadata.mkdir()
        self.write_plist(self.sparkle / "Resources/Info.plist", {"CFBundleShortVersionString": "2.9.0"})
        with self.assertRaises(ValueError):
            release.verify_plists(self.app, self.manifest)

    def testMissingOrModifiedSparkleLicenseRejectsRelease(self):
        license_file = self.app / "Contents/Resources/Sparkle-LICENSE.txt"
        license_file.unlink()
        with self.assertRaises((ValueError, OSError)):
            release.verify_plists(self.app, self.manifest)
        license_file.write_text("incomplete or modified notice")
        with self.assertRaises(ValueError):
            release.verify_plists(self.app, self.manifest)

    def testArchiveArgumentsKeepPathsLiteralAndSeparateTargetIdentities(self):
        output = self.root / "release with spaces;$(must-not-run)"
        command = release.archive_command(self.manifest, output)
        self.assertEqual(command[command.index("-archivePath") + 1], str(output / "ClipShelf.xcarchive"))
        self.assertIn("CLIPSHELF_APP_BUNDLE_IDENTIFIER=io.example.clipshelf", command)
        self.assertIn("CLIPSHELF_SHARE_BUNDLE_IDENTIFIER=io.example.clipshelf.share", command)
        self.assertIn("CLIPSHELF_APP_PROFILE=App Profile", command)
        self.assertIn("CLIPSHELF_SHARE_PROFILE=Share Profile", command)
        self.assertIn("CLIPSHELF_APP_INFOPLIST=" + self.manifest["paths"]["appInfoPlist"], command)
        self.assertIn("ARCHS=arm64 x86_64", command)
        self.assertIn("ENABLE_HARDENED_RUNTIME=YES", command)
        self.assertIn("-onlyUsePackageVersionsFromResolvedFile", command)
        self.assertNotIn("-allowProvisioningUpdates", command)
        self.assertFalse(any(argument.startswith("PRODUCT_BUNDLE_IDENTIFIER=") for argument in command))
        self.assertFalse(output.exists())

    def testRunPassesAnArgumentVectorWithoutAShell(self):
        result = subprocess.CompletedProcess([], 0, b"ok", b"")
        command = ["tool", self.root / "spaces;$(must-not-run)"]
        with mock.patch.object(release.subprocess, "run", return_value=result) as call:
            release.run(command, "synthetic command boundary")
        self.assertEqual(call.call_args.args[0], [str(part) for part in command])
        self.assertFalse(call.call_args.kwargs.get("shell", False))

    def testAppcastRequiresOneMatchingBuildAndArchive(self):
        root, item, enclosure = self.appcast()
        self.save_feed(root)
        self.assertEqual(release.verify_appcast_metadata(self.feed, self.archive, self.manifest, self.prefix), enclosure.get(NS + "edSignature"))
        root.find("channel").append(ET.fromstring(ET.tostring(item)))
        self.save_feed(root)
        with self.assertRaises(ValueError):
            release.verify_appcast_metadata(self.feed, self.archive, self.manifest, self.prefix)
        root, item, enclosure = self.appcast()
        item.find(NS + "version").text = "41"
        self.save_feed(root)
        with self.assertRaises(ValueError):
            release.verify_appcast_metadata(self.feed, self.archive, self.manifest, self.prefix)

    def testAppcastRejectsWrongURLLengthOrSignatureShape(self):
        for field, value in [("url", self.prefix + "different.zip"), ("length", "0"),
                             (NS + "edSignature", "!not-base64!"), (NS + "edSignature", base64.b64encode(b"short").decode())]:
            with self.subTest(field=field):
                root, _, enclosure = self.appcast()
                enclosure.set(field, value)
                self.save_feed(root)
                with self.assertRaises(ValueError):
                    release.verify_appcast_metadata(self.feed, self.archive, self.manifest, self.prefix)

    def testAppcastRejectsDTDAndOversizedInput(self):
        for data in [b'<!DOCTYPE rss [<!ENTITY x "value">]><rss/>', b" " * (8 * 1024 * 1024 + 1)]:
            self.feed.write_bytes(data)
            with self.assertRaises(ValueError):
                release.verify_appcast_metadata(self.feed, self.archive, self.manifest, self.prefix)

    def testDownloadPrefixRejectsUnsafeSchemesCredentialsQueriesAndPorts(self):
        self.assertEqual(release.download_prefix(self.prefix[:-1]), self.prefix)
        for value in ["http://example.invalid/", "https://user:password@example.invalid/", "https://example.invalid/?token=a",
                      "https://example.invalid/#fragment", "https://example.invalid:99999/", "https://example.invalid/appcast.xml",
                      "https://example.invalid/a\nb", "https://example.invalid/a b",
                      "https://@example.invalid/releases/", "https://example.invalid/releases/?",
                      "https://example.invalid/releases/#"]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                release.download_prefix(value)

    def testSigningKeyRejectsReadableByOthersSymlinksAndHardlinks(self):
        key = self.root / "public-test-seed"
        write_test_key(key)
        self.assertEqual(release.secure_key_file(key), key.absolute())
        key.chmod(0o644)
        with self.assertRaises(ValueError):
            release.secure_key_file(key)
        key.chmod(0o600)
        link = self.root / "link"
        link.symlink_to(key)
        with self.assertRaises(ValueError):
            release.secure_key_file(link)
        os.link(key, self.root / "hardlink")
        with self.assertRaises(ValueError):
            release.secure_key_file(key)

    def testExportedCloudPermissionsExtensionSandboxAndEachHelperRuntimeAreRequired(self):
        cloud = "iCloud.io.example.clipshelf"
        self.manifest["cloudKitContainerIdentifier"] = cloud
        self.write_plist(self.app / "Contents/Info.plist", dict(self.main_info, ClipShelfCloudKitContainerIdentifier=cloud))
        expected = {
            self.app: {"com.apple.security.application-groups": [self.manifest["appGroupIdentifier"]],
                       "com.apple.developer.icloud-container-identifiers": [cloud],
                       "com.apple.developer.icloud-services": ["CloudKit"],
                       "com.apple.developer.icloud-container-environment": "Production",
                       "com.apple.developer.aps-environment": "production"},
            self.extension: {"com.apple.security.application-groups": [self.manifest["appGroupIdentifier"]],
                             "com.apple.security.app-sandbox": True,
                             "com.apple.security.files.user-selected.read-only": True},
        }
        for bundle, name in [(self.app, "appEntitlements"), (self.extension, "shareEntitlements")]:
            self.write_plist(Path(self.manifest["paths"][name]), expected[bundle])
        helpers = [self.sparkle / "Versions/B/Autoupdate", self.sparkle / "Versions/B/Updater.app",
                   self.sparkle / "Versions/B/XPCServices/Installer.xpc", self.sparkle / "Versions/B/XPCServices/Downloader.xpc"]
        for helper in helpers:
            helper.parent.mkdir(parents=True, exist_ok=True)
            if helper.suffix in [".app", ".xpc"]:
                helper.mkdir()
            else:
                helper.write_bytes(b"fixture, never executed")
        actual = {bundle: dict(values) for bundle, values in expected.items()}
        missing_runtime = None

        def inspect(argv, _label, _log=None):
            stdout, stderr = b"", b""
            if argv[:3] == ["codesign", "-d", "--verbose=4"]:
                text = "TeamIdentifier=ABCDE12345\nAuthority=Developer ID Application: Fixture (ABCDE12345)\n"
                text += "flags=0x0\n" if argv[-1] == missing_runtime else "flags=0x10000(runtime)\n"
                stderr = text.encode()
            elif argv[:3] == ["codesign", "-d", "--entitlements"]:
                stdout = plistlib.dumps(actual[argv[-1]])
            elif argv[:3] == ["codesign", "--verify", "--deep"]:
                pass
            elif argv[:2] == ["lipo", "-archs"]:
                stdout = b"arm64 x86_64\n"
            elif argv[:2] == ["otool", "-L"]:
                stdout = b"fixture:\n\t@rpath/Sparkle.framework/Versions/B/Sparkle (compatibility version 1.6.0)\n"
            elif argv[:2] == ["otool", "-l"]:
                stdout = b"cmd LC_RPATH\npath @executable_path/../Frameworks\n"
            else:
                self.fail("Unexpected verification command: " + str(argv))
            return subprocess.CompletedProcess(argv, 0, stdout, stderr)

        with mock.patch.object(release, "run", side_effect=inspect):
            release.verify_bundle(self.app, self.manifest, self.root / "unused.log")
            rejected = [(self.app, "com.apple.developer.icloud-services", None),
                        (self.app, "com.apple.developer.icloud-container-environment", "Development"),
                        (self.app, "com.apple.developer.aps-environment", "development"),
                        (self.extension, "com.apple.security.app-sandbox", False),
                        (self.extension, "com.apple.security.files.user-selected.read-only", None)]
            for bundle, key, value in rejected:
                with self.subTest(bundle=bundle.name, entitlement=key):
                    if value is None:
                        actual[bundle].pop(key)
                    else:
                        actual[bundle][key] = value
                    with self.assertRaisesRegex(ValueError, "Signed entitlement mismatch"):
                        release.verify_bundle(self.app, self.manifest, self.root / "unused.log")
                    actual[bundle] = dict(expected[bundle])
            for helper in helpers:
                with self.subTest(helper=helper.name):
                    missing_runtime = helper
                    with self.assertRaisesRegex(ValueError, "Hardened runtime is missing"):
                        release.verify_bundle(self.app, self.manifest, self.root / "unused.log")

    def testUntrackedSourceStopsBeforeArchiveOrOutputCreation(self):
        key = self.root / "PUBLIC_TEST_SEED"
        write_test_key(key)
        output = self.root / "never-created-release"
        environment = {"CLIPSHELF_NOTARY_KEYCHAIN_PROFILE": "fixture-must-never-be-accessed",
                       "SPARKLE_SIGNING_KEY_FILE": str(key), "CLIPSHELF_UPDATE_DOWNLOAD_URL_PREFIX": self.prefix}
        status = subprocess.CompletedProcess([], 0, b"?? native/Sources/ClipShelf/Untracked.swift\n", b"")
        with mock.patch.dict(os.environ, environment, clear=True), \
             mock.patch.object(sys, "argv", ["release-macos.py", "--output", str(output)]), \
             mock.patch.object(release, "run", return_value=status) as run:
            with self.assertRaisesRegex(ValueError, "clean checkout"):
                release.main()
        self.assertEqual(run.call_count, 1)
        self.assertEqual(run.call_args.args[0], ["git", "status", "--porcelain", "--untracked-files=all"])
        self.assertFalse(output.exists())

    def testLocalizationGateRunsAfterSignedExportAndStopsNotaryOnFailure(self):
        class StopBeforeNotarization(Exception):
            pass

        key = self.root / "PUBLIC_LOCALIZATION_TEST_SEED"
        write_test_key(key)
        environment = {"CLIPSHELF_NOTARY_KEYCHAIN_PROFILE": "fixture-never-accessed",
                       "SPARKLE_SIGNING_KEY_FILE": str(key), "CLIPSHELF_UPDATE_DOWNLOAD_URL_PREFIX": self.prefix,
                       "CLIPSHELF_UPDATE_FEED_URL": self.manifest["updateFeedURL"]}
        actual_run = release.run
        for failed in (False, True):
            with self.subTest(localization_failure=failed):
                output = self.root / ("release failure" if failed else "release success")
                exported_app = output / "export/ClipShelf.app"
                calls = []

                def simulate_build(argv, label, log=None):
                    calls.append(label)
                    if label == "Prepare release manifests":
                        directory = output / "configuration"
                        directory.mkdir()
                        (directory / "manifest.json").write_text(json.dumps(self.manifest))
                    if label == "Verify delivered app and Share Extension localizations":
                        self.assertEqual(argv, [sys.executable, ROOT / "scripts/verify-localization.py",
                                                "--app", exported_app, "--share-extension", "--runtime"])
                        # Exercise run()'s real nonzero-exit gate with a mocked
                        # subprocess. No app, signing or notarization is run.
                        return actual_run(argv, label, log)
                    if label == "Package notarization submission":
                        raise StopBeforeNotarization()
                    stdout = b"fixture-commit\n" if label == "Record source commit" else b""
                    return subprocess.CompletedProcess(argv, 0, stdout, b"")

                def verify_export(app, manifest, log):
                    self.assertEqual(app, exported_app)
                    self.assertEqual(manifest, self.manifest)
                    calls.append("Verify signed exported bundle")

                child_result = subprocess.CompletedProcess([], 1 if failed else 0,
                                                           b"synthetic localization result", b"fixture validation failure" if failed else b"")
                with mock.patch.dict(os.environ, environment, clear=True), \
                     mock.patch.object(sys, "argv", ["release-macos.py", "--output", str(output)]), \
                     mock.patch.object(release, "run", side_effect=simulate_build), \
                     mock.patch.object(release, "verify_bundle", side_effect=verify_export), \
                     mock.patch.object(release.subprocess, "run", return_value=child_result) as child:
                    if failed:
                        with self.assertRaisesRegex(ValueError, "localizations failed"):
                            release.main()
                    else:
                        with self.assertRaises(StopBeforeNotarization):
                            release.main()
                child.assert_called_once()
                gate = calls.index("Verify delivered app and Share Extension localizations")
                self.assertLess(calls.index("Export Developer ID app"), calls.index("Verify signed exported bundle"))
                self.assertEqual(calls[gate - 1], "Verify signed exported bundle")
                self.assertEqual(calls[gate + 1:], [] if failed else ["Package notarization submission"])
                self.assertFalse((output / "notary-submission.zip").exists())
                self.assertFalse((output / "assets").exists())


@unittest.skipUnless(sys.platform == "darwin", "CryptoKit and the official Sparkle tools require macOS")
class SparkleSignatureInteropTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        artifact = ROOT / "native/.build/artifacts/sparkle/Sparkle/bin"
        cls.sign_update = Path(os.environ.get("CLIPSHELF_TEST_SPARKLE_BIN", artifact)) / "sign_update"
        if not cls.sign_update.is_file():
            raise unittest.SkipTest("Resolve Sparkle first or set CLIPSHELF_TEST_SPARKLE_BIN to its official bin directory")
        cls.temporary = tempfile.TemporaryDirectory(prefix="clipshelf-signature-interop-")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.root = Path(cls.temporary.name)
        cls.key = cls.root / "PUBLIC_TEST_SEED_NOT_FOR_PRODUCTION"
        write_test_key(cls.key)
        cls.verifier = cls.root / "verify-update-signature"
        build = subprocess.run(["xcrun", "swiftc", "-module-cache-path", str(cls.root / "ModuleCache"),
                                str(ROOT / "scripts/verify-update-signature.swift"), "-o", str(cls.verifier)],
                               capture_output=True, text=True, timeout=60)
        if build.returncode:
            raise AssertionError("CryptoKit verifier compilation failed: " + build.stderr)

    def setUp(self):
        self.temporary_case = tempfile.TemporaryDirectory(dir=self.root)
        self.addCleanup(self.temporary_case.cleanup)
        self.directory = Path(self.temporary_case.name)
        self.archive = self.directory / "synthetic.zip"
        self.archive.write_bytes(b"ClipShelf synthetic signing interop\x00\x01\x02")

    def official(self, *arguments):
        # Always pass an explicit temporary test seed. No implicit Keychain path.
        return subprocess.run([str(self.sign_update), "--ed-key-file", str(self.key), *map(str, arguments)],
                              capture_output=True, text=True, timeout=20)

    def verify(self, path, signature, public=TEST_PUBLIC):
        return subprocess.run([str(self.verifier), str(path), base64.b64encode(public).decode(), signature],
                              capture_output=True, text=True, timeout=10)

    def signature(self):
        result = self.official("-p", self.archive)
        self.assertEqual(result.returncode, 0, result.stderr)
        signature = result.stdout.strip()
        self.assertEqual(len(base64.b64decode(signature, validate=True)), 64)
        return signature

    def testOfficialArchiveSignaturePassesIndependentCryptoKitVerification(self):
        signature = self.signature()
        self.assertEqual(self.verify(self.archive, signature).returncode, 0)
        self.assertEqual(self.official("--verify", self.archive, signature).returncode, 0)

    def testTamperedArchiveAndWrongEmbeddedPublicKeyAreRejected(self):
        signature = self.signature()
        self.assertNotEqual(self.verify(self.archive, signature, public=OTHER_PUBLIC).returncode, 0)
        self.archive.write_bytes(self.archive.read_bytes() + b"tampered")
        self.assertNotEqual(self.verify(self.archive, signature).returncode, 0)
        self.assertNotEqual(self.official("--verify", self.archive, signature).returncode, 0)

    def testMalformedSignatureAndPublicKeyAreRejected(self):
        self.assertNotEqual(self.verify(self.archive, "!").returncode, 0)
        self.assertNotEqual(self.verify(self.archive, base64.b64encode(b"short").decode()).returncode, 0)
        self.assertNotEqual(self.verify(self.archive, self.signature(), public=b"short").returncode, 0)

    def testSignedXMLFeedPassesOfficialAndPublicKeyVerificationThenRejectsTampering(self):
        feed = self.directory / "appcast.xml"
        feed.write_text('<?xml version="1.0"?><rss version="2.0"><channel><title>Fixture</title></channel></rss>')
        signed = self.official("-p", feed)
        self.assertEqual(signed.returncode, 0, signed.stderr)
        self.assertEqual(self.official("--verify", feed).returncode, 0)
        data = feed.read_bytes()
        block = re.search(rb"<!-- sparkle-signatures:\nedSignature: ([A-Za-z0-9+/=]+)\nlength: ([0-9]+)\n-->\n$", data)
        self.assertIsNotNone(block)
        length = int(block[2])
        self.assertEqual(block.start(), length)
        content = self.directory / "signed-xml-content"
        content.write_bytes(data[:length])
        self.assertEqual(self.verify(content, block[1].decode()).returncode, 0)
        self.assertNotEqual(self.verify(content, block[1].decode(), public=OTHER_PUBLIC).returncode, 0)
        feed.write_bytes(data.replace(b"Fixture", b"Changed"))
        self.assertNotEqual(self.official("--verify", feed).returncode, 0)


if __name__ == "__main__":
    unittest.main()
