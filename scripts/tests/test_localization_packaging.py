import importlib.util
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "verify-localization.py"
SPEC = importlib.util.spec_from_file_location("verify_localization", SCRIPT)
verify = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(verify)


class LocalizationPackagingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.app = self.root / "ClipShelf.app"
        self.extension = self.app / "Contents/PlugIns/ClipShelfShare.appex"
        self.catalogs = {
            "en": {"": "", "取消": "Cancel", "保存 {0}": "Save {0}"},
            "zh-Hans": {"": "", "取消": "取消", "保存 {0}": "保存 {0}"},
            "zh-Hant": {"": "", "取消": "取消", "保存 {0}": "儲存 {0}"},
        }
        for bundle in (self.app, self.extension):
            resources = bundle / "Contents/Resources"
            resources.mkdir(parents=True)
            (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({
                "CFBundleDevelopmentRegion": "en", "CFBundleLocalizations": list(verify.LANGUAGES),
                "NSServices": [{"NSMenuItem": {"default": "Save to ClipShelf"}}],
            }))
            package = resources / verify.RESOURCE_BUNDLE
            package.mkdir()
            for language in verify.LANGUAGES:
                (package / f"catalog-{language}.json").write_text(json.dumps(self.catalogs[language]))
                directory = resources / f"{language}.lproj"
                directory.mkdir()
                self.write_table(directory / "InfoPlist.strings", {"CFBundleName": "ClipShelf", "CFBundleDisplayName": "ClipShelf"})
        self.resources = self.app / "Contents/Resources"
        self.metadata = {
            "actions": {name: {"title": {"key": name}, "actionSummary": {"formatString": "Save ${text}"}}
                        for name in verify.INTENTS},
            "autoShortcuts": [{"shortTitle": {"key": "Find Text"},
                               "phraseTemplates": [{"key": "Find text in ${applicationName}"}]}],
        }
        metadata_dir = self.resources / "Metadata.appintents"
        metadata_dir.mkdir()
        self.metadata_path = metadata_dir / "extract.actionsdata"
        self.metadata_path.write_text(json.dumps(self.metadata))
        self.translations = {name: name for name in verify.INTENTS}
        self.translations.update({"Save ${text}": "Save ${text}", "Find Text": "Find Text"})
        for language in verify.LANGUAGES:
            directory = self.resources / f"{language}.lproj"
            self.write_table(directory / "Localizable.strings", self.translations)
            self.write_table(directory / "AppShortcuts.strings", {"Find text in ${applicationName}": "Find text in ${applicationName}"})
            self.write_table(directory / "ServicesMenu.strings", {"Save to ClipShelf": "Save to ClipShelf"})

    def write_table(self, path, values):
        path.write_bytes(plistlib.dumps(values, fmt=plistlib.FMT_BINARY))

    def test_relocated_app_and_extension_resources_are_self_contained(self):
        relocated = self.root / "delivered/ClipShelf.app"
        shutil.copytree(self.app, relocated)
        shutil.rmtree(self.app)
        verify.verify_app(relocated, share_extension=True)

    def test_xcode_style_resource_bundle_is_supported(self):
        for bundle in (self.app, self.extension):
            package = bundle / "Contents/Resources" / verify.RESOURCE_BUNDLE
            contents = package / "Contents/Resources"
            contents.mkdir(parents=True)
            for catalog in package.glob("*.json"):
                catalog.rename(contents / catalog.name)
        verify.verify_app(self.app, share_extension=True)

    def test_missing_extension_catalog_is_rejected(self):
        (self.extension / "Contents/Resources" / verify.RESOURCE_BUNDLE / "catalog-zh-Hant.json").unlink()
        with self.assertRaisesRegex(ValueError, "Missing localization catalog"):
            verify.verify_app(self.app, share_extension=True)

    def test_empty_or_non_string_catalogs_are_rejected_in_either_host(self):
        for bundle in (self.app, self.extension):
            path = bundle / "Contents/Resources" / verify.RESOURCE_BUNDLE / "catalog-en.json"
            for invalid in ({}, [], {"取消": 123}, {"取消": None}, {"取消": {"text": "Cancel"}}):
                with self.subTest(host=bundle.name, catalog=invalid):
                    path.write_text(json.dumps(invalid))
                    with self.assertRaisesRegex(ValueError, "nonempty string-to-string"):
                        verify.verify_app(self.app, share_extension=True)
            path.write_text(json.dumps(self.catalogs["en"]))

    def test_each_host_requires_equal_keys_in_all_three_languages(self):
        for bundle in (self.app, self.extension):
            with self.subTest(host=bundle.name):
                path = bundle / "Contents/Resources" / verify.RESOURCE_BUNDLE / "catalog-zh-Hant.json"
                incomplete = dict(self.catalogs["zh-Hant"])
                incomplete.pop("保存 {0}")
                path.write_text(json.dumps(incomplete))
                with self.assertRaisesRegex(ValueError, "language key sets differ"):
                    verify.verify_app(self.app, share_extension=True)
                path.write_text(json.dumps(self.catalogs["zh-Hant"]))

    def test_catalog_templates_reject_missing_added_and_invalid_parameters(self):
        for bundle in (self.app, self.extension):
            path = bundle / "Contents/Resources" / verify.RESOURCE_BUNDLE / "catalog-en.json"
            for key, translation, message in (
                ("保存 {0}", "Save", "placeholder mismatch"),
                ("保存 {0}", "Save {0} {1}", "placeholder mismatch"),
                ("保存 {0}", "Save {01}", "Invalid catalog template"),
                ("保存 {0}", "Save {name}", "Invalid catalog template"),
                ("保存 {0}", "Save {0} }", "Invalid catalog template"),
                ("保存 {0}", "Save {0", "Invalid catalog template"),
                ("保存 {1}", "Save {1}", "consecutive from zero"),
                ("保存 {0} {0}", "Save {0}", "consecutive from zero"),
                ("保存 {1} {0}", "Save {0} {1}", "consecutive from zero"),
                ("保存 {00}", "Save {0}", "Invalid catalog template"),
            ):
                with self.subTest(host=bundle.name, key=key, translation=translation):
                    path.write_text(json.dumps({key: translation}))
                    with self.assertRaisesRegex(ValueError, message):
                        verify.verify_app(self.app, share_extension=True)
            path.write_text(json.dumps(self.catalogs["en"]))

    def test_reordered_repeated_parameters_and_escaped_braces_are_valid(self):
        for bundle in (self.app, self.extension):
            package = bundle / "Contents/Resources" / verify.RESOURCE_BUNDLE
            for language in verify.LANGUAGES:
                catalog = dict(self.catalogs[language])
                catalog["{{literal}} {0} / {1} 100%"] = "{1}: {0}; repeat {0} {{literal}} 100%"
                (package / f"catalog-{language}.json").write_text(json.dumps(catalog))
        verify.verify_app(self.app, share_extension=True)

    def test_extension_catalog_cannot_silently_differ_from_main_app(self):
        path = self.extension / "Contents/Resources" / verify.RESOURCE_BUNDLE / "catalog-en.json"
        different = dict(self.catalogs["en"], **{"取消": "Abort"})
        path.write_text(json.dumps(different))
        with self.assertRaisesRegex(ValueError, "catalogs differ from the containing app"):
            verify.verify_app(self.app, share_extension=True)

    def test_external_catalog_symlink_is_rejected(self):
        external = self.root / "development-catalog.json"
        external.write_text('{}')
        path = self.resources / verify.RESOURCE_BUNDLE / "catalog-en.json"
        path.unlink()
        path.symlink_to(external)
        with self.assertRaisesRegex(ValueError, "outside its host"):
            verify.verify_app(self.app)

    def test_missing_intent_and_untranslated_metadata_key_are_rejected(self):
        for mutation, message in ((lambda metadata: metadata["actions"].pop("AddClipboardTextIntent"), "actions are missing"),
                                  (lambda metadata: metadata["actions"]["AddClipboardTextIntent"].update(title={"key": "New title"}), "keys do not match")):
            with self.subTest(message=message):
                metadata = json.loads(json.dumps(self.metadata))
                mutation(metadata)
                self.metadata_path.write_text(json.dumps(metadata))
                with self.assertRaisesRegex(ValueError, message):
                    verify.verify_app(self.app)

    def test_translated_placeholder_cannot_be_lost(self):
        translations = dict(self.translations, **{"Save ${text}": "Save text"})
        self.write_table(self.resources / "zh-Hant.lproj/Localizable.strings", translations)
        with self.assertRaisesRegex(ValueError, "placeholder mismatch"):
            verify.verify_app(self.app)

    def test_declared_but_unshipped_language_is_rejected(self):
        info_path = self.app / "Contents/Info.plist"
        info = plistlib.loads(info_path.read_bytes())
        info["CFBundleLocalizations"].append("de")
        info_path.write_bytes(plistlib.dumps(info))
        with self.assertRaisesRegex(ValueError, "supported language declaration"):
            verify.verify_app(self.app)

    def test_runtime_probe_rejects_development_fallback(self):
        def fake_run(arguments, **kwargs):
            if arguments[0] == "/usr/bin/ditto":
                shutil.copytree(arguments[1], arguments[2])
                return subprocess.CompletedProcess(arguments, 0)
            return subprocess.CompletedProcess(arguments, 0, stdout=json.dumps({
                "language": arguments[-1], "resourceSource": "swiftPackage", "resourceDirectory": "/development/.build",
                "issues": [], "sample": "Cancel",
            }))
        with patch.object(verify.subprocess, "run", side_effect=fake_run):
            with self.assertRaisesRegex(ValueError, "development resource location"):
                verify.verify_relocated_runtime(self.app)


if __name__ == "__main__":
    unittest.main()
