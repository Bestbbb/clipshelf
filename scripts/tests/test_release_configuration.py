"""Synthetic CLI and atomicity coverage; no signing, Keychain or network calls."""
import base64
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "configure-release.py"
spec = importlib.util.spec_from_file_location("release_configuration", SCRIPT)
release = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = release
spec.loader.exec_module(release)


class ReleaseConfigurationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="clipshelf-release-config-")
        self.root = Path(self.temporary.name).resolve()
        self.addCleanup(self.temporary.cleanup)
        self.env = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "CLIPSHELF_DISTRIBUTION": "release",
            "CLIPSHELF_VERSION": "1.2.3",
            "CLIPSHELF_BUILD_NUMBER": "42",
            "CLIPSHELF_TEAM_ID": "ABCDE12345",
            "CLIPSHELF_UPDATE_FEED_URL": "https://updates.example.invalid/stable/appcast.xml",
            "CLIPSHELF_UPDATE_PUBLIC_ED_KEY": base64.b64encode(bytes(range(32))).decode("ascii"),
        }

    def cli(self, *args, env=None):
        return subprocess.run([sys.executable, str(SCRIPT), *map(str, args)],
                              env=self.env if env is None else env,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

    def prepare_env(self):
        return dict(self.env, CLIPSHELF_APP_GROUP_IDENTIFIER="group.io.github.bestbbb.clipshelf",
                    CLIPSHELF_APP_PROFILE="ClipShelf Developer ID Profile",
                    CLIPSHELF_SHARE_PROFILE="ClipShelf Share Developer ID Profile")

    def plist(self, path, value=None):
        if value is not None:
            path.write_bytes(plistlib.dumps(value))
        return plistlib.loads(path.read_bytes())

    def test_validate_needs_no_signing_identity_network_or_output(self):
        result = self.cli("--validate")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "Release configuration validated.\n")
        self.assertEqual(list(self.root.iterdir()), [])

    def test_required_environment_fails_without_echoing_values(self):
        for name in ["CLIPSHELF_DISTRIBUTION", "CLIPSHELF_VERSION", "CLIPSHELF_BUILD_NUMBER",
                     "CLIPSHELF_TEAM_ID", "CLIPSHELF_UPDATE_FEED_URL", "CLIPSHELF_UPDATE_PUBLIC_ED_KEY"]:
            with self.subTest(field=name):
                env = dict(self.env); env.pop(name)
                result = self.cli("--validate", env=env)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(name, result.stderr)
                self.assertEqual(result.stdout, "")

    def test_invalid_distribution_bundle_version_build_and_team(self):
        values = {
            "CLIPSHELF_DISTRIBUTION": ["development", "Release", "validation", "release\n"],
            "BUNDLE_IDENTIFIER": ["", "io.example.app.dev", "io.dev.example.app", "io.validation.app", "io.VALIDATION.app", "io.demo.app", "io.DeMo.app",
                                  "io..app", "io.example.*", "$(PRODUCT_BUNDLE_IDENTIFIER)", "single", "io.example.bad_id", "io.-bad.app", "io.app."],
            "CLIPSHELF_VERSION": ["1.2.3.4", "1.2-beta", "1..2", "+1", "1. 2", "1\n", "１.２"],
            "CLIPSHELF_BUILD_NUMBER": ["0", "-1", "+1", "01", "1.0", "1\n", "１", "9" * 19],
            "CLIPSHELF_TEAM_ID": ["abcde12345", "ABCDE1234", "ABCDE123456", "ABCDE1234!", "ABCDEFGHI\n"],
        }
        for field, invalids in values.items():
            for value in invalids:
                with self.subTest(field=field, value=value):
                    result = self.cli("--validate", env=dict(self.env, **{field: value}))
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(field, result.stderr)

    def test_supported_numeric_versions_and_positive_builds(self):
        for value in ["1", "1.2", "0.0.1", "1.20.300"]:
            with self.subTest(version=value):
                self.assertEqual(self.cli("--validate", env=dict(self.env, CLIPSHELF_VERSION=value)).returncode, 0)

    def test_malformed_feed_urls_fail_closed(self):
        for url in ["http://example.invalid/feed", "https:///feed", "https://", "https://user@example.invalid/feed",
                    "https://u:p@example.invalid/feed", "https://example.invalid/feed#fragment", "https://example.invalid/#",
                    " https://example.invalid", "https://example.invalid/\nfeed", "https://example.invalid\\@evil.invalid/",
                    "https://example.invalid:0/feed", "https://example.invalid:65536/feed", "https://example.invalid:abc/feed",
                    "https://example.invalid:/feed", "https://example.invalid../feed", "https://bad_host/feed",
                    "https://%65xample.invalid/feed", "https://[::1]evil.invalid/feed", "https://[::1/feed",
                    "https://example.invalid/%0aheader", "https://example.invalid/%", "https://例子.invalid/feed"]:
            with self.subTest(url=url):
                result = self.cli("--validate", env=dict(self.env, CLIPSHELF_UPDATE_FEED_URL=url))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("CLIPSHELF_UPDATE_FEED_URL", result.stderr)
                self.assertNotIn(url, result.stderr)

    def test_valid_https_authorities_and_encoded_path(self):
        for url in ["https://updates.example.invalid/feed.xml", "https://EXAMPLE.invalid:443/f%20name.xml?a=1",
                    "https://127.0.0.1:8443/feed", "https://[::1]:8443/feed"]:
            with self.subTest(url=url):
                self.assertEqual(self.cli("--validate", env=dict(self.env, CLIPSHELF_UPDATE_FEED_URL=url)).returncode, 0)

    def test_invalid_and_noncanonical_public_keys_fail_without_leaking(self):
        valid = self.env["CLIPSHELF_UPDATE_PUBLIC_ED_KEY"]
        for key in ["NOT_A_PRIVATE_OR_PUBLIC_KEY_SENTINEL", valid.rstrip("="), valid + "=", valid + "\n", " " + valid,
                    base64.b64encode(bytes(31)).decode(), base64.b64encode(bytes(33)).decode(),
                    base64.urlsafe_b64encode(bytes([255]) * 32).decode(), "A" * 42 + "B=", "私钥"]:
            with self.subTest(key=key):
                result = self.cli("--validate", env=dict(self.env, CLIPSHELF_UPDATE_PUBLIC_ED_KEY=key))
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn(key, result.stderr)
                self.assertEqual(result.stdout, "")

    def test_plist_preserves_unrelated_fields_and_enforces_all_update_policy(self):
        path = self.root / "Info.plist"
        initial = {"CFBundleExecutable": "ClipShelf", "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
                   "ClipShelfDistribution": "development", "NSServices": [{"NSMessage": "preserved"}],
                   "NSAppTransportSecurity": {"NSAllowsArbitraryLoadsInWebContent": True}, "Custom": [42, "keep"],
                   "SUEnableAutomaticChecks": True, "SUAutomaticallyUpdate": True, "SUEnableSystemProfiling": True,
                   "SUVerifyUpdateBeforeExtraction": False, "SURequireSignedFeed": False,
                   "SUSignedFeedFailureExpirationInterval": 900}
        self.plist(path, initial)
        result = self.cli("--plist", path)
        self.assertEqual(result.returncode, 0, result.stderr)
        result = self.plist(path)
        self.assertEqual(result["CFBundleIdentifier"], "io.github.bestbbb.clipshelf")
        self.assertEqual(result["CFBundleShortVersionString"], "1.2.3")
        self.assertEqual(result["CFBundleVersion"], "42")
        self.assertEqual(result["ClipShelfDistribution"], "release")
        self.assertEqual(result["SUFeedURL"], self.env["CLIPSHELF_UPDATE_FEED_URL"])
        self.assertEqual(result["SUPublicEDKey"], self.env["CLIPSHELF_UPDATE_PUBLIC_ED_KEY"])
        for key, value in release.UPDATE_POLICY.items():
            self.assertEqual(result[key], value)
            self.assertIs(type(result[key]), type(value))
        for key in ["NSServices", "NSAppTransportSecurity", "Custom", "CFBundleExecutable"]:
            self.assertEqual(result[key], initial[key])

    def test_invalid_config_and_malformed_plist_leave_existing_bytes_unchanged(self):
        for original in [plistlib.dumps({"keep": "original"}), b"not a plist", plistlib.dumps(["not a dictionary"])]:
            path = self.root / "Info.plist"; path.write_bytes(original)
            bad = dict(self.env, CLIPSHELF_UPDATE_PUBLIC_ED_KEY="PRIVATE_SENTINEL")
            self.assertNotEqual(self.cli("--plist", path, env=bad).returncode, 0)
            self.assertEqual(path.read_bytes(), original)
            if original.startswith(b"not") or plistlib.loads(original) == ["not a dictionary"]:
                self.assertNotEqual(self.cli("--plist", path).returncode, 0)
                self.assertEqual(path.read_bytes(), original)
        self.assertFalse(list(self.root.glob(".clipshelf-*")))

    def test_plist_optional_capabilities_do_not_carry_over_from_old_configuration(self):
        path = self.root / "Info.plist"
        self.plist(path, {"ClipShelfCloudKitContainerIdentifier": "iCloud.old.example", "ClipShelfAppGroupIdentifier": "group.old.example"})
        self.assertEqual(self.cli("--plist", path).returncode, 0)
        self.assertNotIn("ClipShelfCloudKitContainerIdentifier", self.plist(path))
        self.assertNotIn("ClipShelfAppGroupIdentifier", self.plist(path))

    def test_prepare_requires_additional_public_signing_configuration(self):
        for missing in ["CLIPSHELF_APP_GROUP_IDENTIFIER", "CLIPSHELF_APP_PROFILE", "CLIPSHELF_SHARE_PROFILE"]:
            env = self.prepare_env(); env.pop(missing)
            result = self.cli("--prepare", self.root / "out", env=env)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(missing, result.stderr)
            self.assertEqual(list(self.root.iterdir()), [])

    def test_group_profile_and_cloud_identifier_validation(self):
        invalid = {"CLIPSHELF_APP_GROUP_IDENTIFIER": ["group", "group..example", "OTHER12345.io.example", "group.io.dev.example", "$(GROUP)"],
                   "CLIPSHELF_APP_PROFILE": ["", " leading", "trailing ", "secret\nprofile", "$(PROFILE)"],
                   "CLIPSHELF_SHARE_PROFILE": ["", "bad\tprofile"],
                   "ICLOUD_CONTAINER_IDENTIFIER": ["", "icloud.io.example", "iCloud.*", "iCloud.io.dev.example", "iCloud.io..example"]}
        for field, values in invalid.items():
            for value in values:
                with self.subTest(field=field, value=value):
                    env = dict(self.prepare_env(), **{field:value})
                    self.assertNotEqual(self.cli("--prepare", self.root / "out", env=env).returncode, 0)
                    self.assertFalse((self.root / "out").exists())

    @unittest.skipUnless(sys.platform == "darwin", "Release directory publication uses macOS renameatx_np")
    def test_prepare_app_extension_entitlements_and_manifest_agree(self):
        env = self.prepare_env()
        env.update(BUNDLE_IDENTIFIER="com.example.clipshelf", ICLOUD_CONTAINER_IDENTIFIER="iCloud.com.example.clipshelf",
                   CLIPSHELF_PRIVATE_KEY="PRIVATE_KEY_SENTINEL", APPLE_ID_PASSWORD="PASSWORD_SENTINEL")
        destination = self.root / "release"
        result = self.cli("--prepare", destination, env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual({p.name for p in destination.iterdir()}, set(release.FILENAMES.values()) | {"manifest.json"})
        app = self.plist(destination / "App-Info.plist")
        share = self.plist(destination / "ShareExtension-Info.plist")
        for name in ["CFBundleShortVersionString", "CFBundleVersion", "ClipShelfDistribution", "ClipShelfAppGroupIdentifier"]:
            self.assertEqual(app[name], share[name])
        self.assertEqual(app["CFBundleIdentifier"], "com.example.clipshelf")
        self.assertEqual(share["CFBundleIdentifier"], "com.example.clipshelf.share")
        self.assertEqual(share["CFBundleExecutable"], "ClipShelfShare")
        self.assertEqual(share["NSExtension"]["NSExtensionPrincipalClass"], "ClipShelfShare.ShareViewController")
        self.assertEqual(app["ClipShelfCloudKitContainerIdentifier"], env["ICLOUD_CONTAINER_IDENTIFIER"])
        app_entitlements = self.plist(destination / "App.entitlements")
        self.assertEqual(set(app_entitlements), {"com.apple.security.application-groups", "com.apple.developer.icloud-container-identifiers",
                                               "com.apple.developer.icloud-services", "com.apple.developer.icloud-container-environment",
                                               "com.apple.developer.aps-environment"})
        self.assertEqual(app_entitlements["com.apple.developer.aps-environment"], "production")
        self.assertEqual(app_entitlements["com.apple.developer.icloud-container-environment"], "Production")
        share_entitlements = self.plist(destination / "ShareExtension.entitlements")
        self.assertEqual(share_entitlements, {"com.apple.security.app-sandbox": True,
                                           "com.apple.security.files.user-selected.read-only": True,
                                           "com.apple.security.application-groups": [env["CLIPSHELF_APP_GROUP_IDENTIFIER"]]})
        self.assertEqual(app_entitlements["com.apple.security.application-groups"], share_entitlements["com.apple.security.application-groups"])
        export = self.plist(destination / "ExportOptions.plist")
        self.assertEqual(export["method"], "developer-id"); self.assertEqual(export["signingStyle"], "manual")
        self.assertEqual(export["teamID"], env["CLIPSHELF_TEAM_ID"])
        self.assertEqual(export["provisioningProfiles"], {app["CFBundleIdentifier"]:env["CLIPSHELF_APP_PROFILE"],
                                                        share["CFBundleIdentifier"]:env["CLIPSHELF_SHARE_PROFILE"]})
        manifest = json.loads((destination / "manifest.json").read_text())
        self.assertEqual(manifest["appBundleIdentifier"], app["CFBundleIdentifier"])
        self.assertEqual(manifest["shareBundleIdentifier"], share["CFBundleIdentifier"])
        self.assertEqual(manifest["provisioningProfiles"], export["provisioningProfiles"])
        self.assertEqual(manifest["paths"], {key:str(destination / name) for key,name in release.FILENAMES.items()})
        for path in destination.iterdir():
            self.assertNotIn(b"PRIVATE_KEY_SENTINEL", path.read_bytes())
            self.assertNotIn(b"PASSWORD_SENTINEL", path.read_bytes())
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    @unittest.skipUnless(sys.platform == "darwin", "Release directory publication uses macOS renameatx_np")
    def test_prepare_without_cloud_uses_only_app_group_and_accepts_team_group(self):
        destination = self.root / "release"
        env = dict(self.prepare_env(), CLIPSHELF_APP_GROUP_IDENTIFIER="ABCDE12345.io.example.clipshelf")
        result = self.cli("--prepare", destination, env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.plist(destination / "App.entitlements"), {"com.apple.security.application-groups":[env["CLIPSHELF_APP_GROUP_IDENTIFIER"]]})
        self.assertNotIn("ClipShelfCloudKitContainerIdentifier", self.plist(destination / "App-Info.plist"))
        self.assertNotIn("cloudKitContainerIdentifier", json.loads((destination / "manifest.json").read_text()))

    def test_existing_prepare_destination_and_source_templates_are_preserved(self):
        for kind in ["file", "directory"]:
            destination = self.root / kind
            if kind == "directory":
                destination.mkdir(); marker = destination / "sentinel"
            else:
                marker = destination
            marker.write_bytes(b"preserved")
            self.assertNotEqual(self.cli("--prepare", destination, env=self.prepare_env()).returncode, 0)
            self.assertEqual(marker.read_bytes(), b"preserved")
        template = SCRIPT.parent.parent / "native/Resources/Info.plist"
        before = template.read_bytes()
        self.assertNotEqual(self.cli("--plist", template).returncode, 0)
        self.assertEqual(template.read_bytes(), before)

    def test_symlink_file_and_parent_are_rejected_without_touching_targets(self):
        original = self.root / "real.plist"; original.write_bytes(plistlib.dumps({"keep":True}))
        before = original.read_bytes()
        link = self.root / "link.plist"; link.symlink_to(original)
        self.assertNotEqual(self.cli("--plist", link).returncode, 0)
        self.assertEqual(original.read_bytes(), before)
        real = self.root / "real"; real.mkdir()
        alias = self.root / "alias"; alias.symlink_to(real, target_is_directory=True)
        (real / "Info.plist").write_bytes(before)
        self.assertNotEqual(self.cli("--plist", alias / "Info.plist").returncode, 0)
        self.assertNotEqual(self.cli("--prepare", alias / "release", env=self.prepare_env()).returncode, 0)
        output_alias = self.root / "output"; output_alias.symlink_to(real, target_is_directory=True)
        self.assertNotEqual(self.cli("--prepare", output_alias, env=self.prepare_env()).returncode, 0)
        self.assertEqual(list(real.iterdir()), [real / "Info.plist"])
        self.assertEqual((real / "Info.plist").read_bytes(), before)

    def test_hardlink_plist_is_rejected(self):
        path = self.root / "Info.plist"; path.write_bytes(plistlib.dumps({"keep":True}))
        alias = self.root / "alias.plist"; os.link(path, alias)
        before = path.read_bytes()
        self.assertNotEqual(self.cli("--plist", path).returncode, 0)
        self.assertEqual(path.read_bytes(), before); self.assertEqual(alias.read_bytes(), before)

    def test_plist_write_failure_is_atomic(self):
        path = self.root / "Info.plist"; path.write_bytes(plistlib.dumps({"keep":True}))
        before = path.read_bytes()
        config = release.ReleaseConfiguration.from_environment(self.env)
        with mock.patch.object(release.os, "replace", side_effect=OSError("synthetic failure")):
            with self.assertRaises(OSError):
                release.update_plist(path, config)
        self.assertEqual(path.read_bytes(), before)
        self.assertEqual(list(self.root.iterdir()), [path])

    def test_symlink_swap_during_plist_staging_never_writes_victim(self):
        path = self.root / "Info.plist"; path.write_bytes(plistlib.dumps({"keep":True}))
        victim = self.root / "victim.plist"; victim.write_bytes(b"must remain unchanged")
        config = release.ReleaseConfiguration.from_environment(self.env)
        write = release.write_new
        def swap(*args, **kwargs):
            write(*args, **kwargs)
            path.unlink(); path.symlink_to(victim)
        with mock.patch.object(release, "write_new", side_effect=swap):
            with self.assertRaises(release.ConfigurationError):
                release.update_plist(path, config)
        self.assertEqual(victim.read_bytes(), b"must remain unchanged")
        self.assertTrue(path.is_symlink())
        self.assertFalse(list(self.root.glob(".clipshelf-*")))

    @unittest.skipUnless(sys.platform == "darwin", "Checks the macOS root-owned /tmp alias")
    def test_prepare_supports_system_tmp_alias_without_following_user_aliases(self):
        with tempfile.TemporaryDirectory(prefix="clipshelf-release-alias-", dir="/tmp") as temporary:
            destination = Path(temporary) / "release"
            result = self.cli("--prepare", destination, env=self.prepare_env())
            self.assertEqual(result.returncode, 0, result.stderr)
            manifest = json.loads((destination / "manifest.json").read_text())
            self.assertEqual(Path(manifest["paths"]["appInfoPlist"]), destination.resolve() / "App-Info.plist")

    def test_prepare_mid_write_failure_never_publishes_partial_directory(self):
        config = release.ReleaseConfiguration.from_environment(self.prepare_env(), prepare=True)
        write = release.write_new
        calls = 0
        def fail_second(*args, **kwargs):
            nonlocal calls
            calls += 1
            if calls == 2:
                raise OSError("synthetic write failure")
            return write(*args, **kwargs)
        with mock.patch.object(release, "write_new", side_effect=fail_second):
            with self.assertRaises(OSError):
                release.prepare_directory(self.root / "release", config)
        self.assertEqual(list(self.root.iterdir()), [])

    @unittest.skipUnless(sys.platform == "darwin", "Release directory publication uses macOS renameatx_np")
    def test_destination_created_just_before_publish_is_never_replaced(self):
        config = release.ReleaseConfiguration.from_environment(self.prepare_env(), prepare=True)
        publish = release.rename_new_directory
        destination = self.root / "release"
        def race(parent, source, name):
            destination.mkdir()
            return publish(parent, source, name)
        with mock.patch.object(release, "rename_new_directory", side_effect=race):
            with self.assertRaises(OSError):
                release.prepare_directory(destination, config)
        self.assertTrue(destination.is_dir()); self.assertEqual(list(destination.iterdir()), [])
        self.assertEqual(list(self.root.iterdir()), [destination])

    def test_real_parser_requires_exactly_one_operation(self):
        for args in [[], ["--validate", "--plist", str(self.root / "Info.plist")], ["--unknown"]]:
            self.assertNotEqual(self.cli(*args).returncode, 0)


if __name__ == "__main__":
    unittest.main()
