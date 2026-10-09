#!/usr/bin/env python3
"""Verify delivered localization resources without reading user data or opening UI."""
import argparse
import json
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile


LANGUAGES = ('en', 'zh-Hans', 'zh-Hant', 'cs', 'da', 'nl', 'fr', 'de', 'he', 'it', 'ja', 'ko', 'pl', 'pt', 'ru', 'es')
RESOURCE_BUNDLE = "ClipShelf_ClipShelfLocalization.bundle"
INTENTS = {"AddClipboardTextIntent", "FindClipboardTextIntent", "GetClipboardTextAtIndexIntent"}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def strings_table(path):
    require(path.is_file(), f"Missing localized table: {path}")
    result = subprocess.run(["/usr/bin/plutil", "-convert", "json", "-o", "-", str(path)],
                            check=True, capture_output=True, text=True)
    value = json.loads(result.stdout)
    require(isinstance(value, dict) and all(isinstance(k, str) and isinstance(v, str) and v
                                           for k, v in value.items()), f"Invalid strings table: {path}")
    for key, translation in value.items():
        require(sorted(re.findall(r"\$\{[^}]+\}", key)) == sorted(re.findall(r"\$\{[^}]+\}", translation)),
                f"Localized placeholder mismatch: {path}: {key}")
    return value


def template_placeholders(value):
    """Match LocalizedMessage's escaped braces and canonical decimal indices."""
    placeholders = []
    index = 0
    while index < len(value):
        if value.startswith("{{", index) or value.startswith("}}", index):
            index += 2
        elif value[index] == "{":
            token = re.match(r"\{(0|[1-9][0-9]*)\}", value[index:])
            require(token is not None, f"Invalid catalog template: {value}")
            placeholders.append(int(token.group(1)))
            index += len(token.group(0))
        else:
            require(value[index] != "}", f"Invalid catalog template: {value}")
            index += 1
    return placeholders


def read_catalog(path):
    value = json.loads(path.read_text())
    require(isinstance(value, dict) and bool(value) and
            all(isinstance(key, str) and isinstance(translation, str) for key, translation in value.items()),
            f"Catalog must be a nonempty string-to-string object: {path}")
    for key, translation in value.items():
        source_parameters = template_placeholders(key)
        require(source_parameters == list(range(len(source_parameters))),
                f"Catalog key parameters must be consecutive from zero: {path}: {key}")
        translated_parameters = template_placeholders(translation)
        # Translation may reorder or repeat parameters, but cannot drop or add one.
        require(set(source_parameters) == set(translated_parameters),
                f"Catalog placeholder mismatch: {path}: {key}")
    return value


def verify_bundle_resources(bundle):
    info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
    require(info.get("CFBundleDevelopmentRegion") == "en", f"Invalid development language: {bundle}")
    require(set(info.get("CFBundleLocalizations", [])) == set(LANGUAGES),
            f"Invalid supported language declaration: {bundle}")
    resources = bundle / "Contents/Resources"
    require({p.name.removesuffix(".lproj") for p in resources.glob("*.lproj")} == set(LANGUAGES),
            f"Localized resource directories do not match declared languages: {bundle}")
    package = resources / RESOURCE_BUNDLE
    require(package.is_dir(), f"Missing shared localization bundle: {package}")
    require(package.resolve().is_relative_to(bundle.resolve()), f"Localization bundle points outside its host: {package}")
    # SwiftPM CLI emits a flat bundle; Xcode can emit a macOS Contents bundle.
    catalogs = package / "Contents/Resources" if (package / "Contents/Resources").is_dir() else package
    translations = {}
    for language in LANGUAGES:
        path = catalogs / f"catalog-{language}.json"
        require(path.is_file(), f"Missing localization catalog: {path}")
        require(path.resolve().is_relative_to(bundle.resolve()), f"Catalog points outside its host: {path}")
        translations[language] = read_catalog(path)
        table = strings_table(resources / f"{language}.lproj/InfoPlist.strings")
        require(table.get("CFBundleDisplayName") == "ClipShelf" and table.get("CFBundleName") == "ClipShelf",
                f"Invalid localized product name: {bundle}: {language}")
    complete_keys = set().union(*(set(catalog) for catalog in translations.values()))
    require(all(set(catalog) == complete_keys for catalog in translations.values()),
            f"Catalog language key sets differ: {bundle}")
    return resources, info, translations


def localized_keys(value):
    keys = set()
    if isinstance(value, dict):
        for key, child in value.items():
            if key in ("key", "formatString") and isinstance(child, str):
                keys.add(child)
            else:
                keys.update(localized_keys(child))
    elif isinstance(value, list):
        for child in value:
            keys.update(localized_keys(child))
    return keys


def verify_app(app, share_extension=False):
    resources, info, catalogs = verify_bundle_resources(app)
    metadata = json.loads((resources / "Metadata.appintents/extract.actionsdata").read_text())
    require(set(metadata.get("actions", {})) == INTENTS, "App Intents actions are missing or unexpected")
    keys = localized_keys(metadata["actions"])
    shortcuts = metadata.get("autoShortcuts", [])
    require(bool(shortcuts), "App Shortcut metadata is missing")
    phrases = set()
    for shortcut in shortcuts:
        keys.update(localized_keys(shortcut.get("shortTitle", {})))
        phrases.update(localized_keys(shortcut.get("phraseTemplates", [])))
    services = {service["NSMenuItem"]["default"] for service in info.get("NSServices", [])}
    require(bool(services), "Services metadata is missing")
    for language in LANGUAGES:
        directory = resources / f"{language}.lproj"
        require(set(strings_table(directory / "Localizable.strings")) == keys,
                f"App Intents localization keys do not match metadata: {language}")
        require(set(strings_table(directory / "AppShortcuts.strings")) == phrases,
                f"App Shortcut localization keys do not match metadata: {language}")
        require(set(strings_table(directory / "ServicesMenu.strings")) == services,
                f"Services localization keys do not match Info.plist: {language}")
    if share_extension:
        _, _, extension_catalogs = verify_bundle_resources(app / "Contents/PlugIns/ClipShelfShare.appex")
        require(extension_catalogs == catalogs, "Share Extension catalogs differ from the containing app")


def verify_relocated_runtime(app):
    with tempfile.TemporaryDirectory(prefix="clipshelf-localization-delivery-") as temporary:
        relocated = Path(temporary) / "ClipShelf.app"
        subprocess.run(["/usr/bin/ditto", str(app), str(relocated)], check=True)
        _, _, catalogs = verify_bundle_resources(relocated)
        for language in LANGUAGES:
            expected = catalogs[language]["取消"]
            result = subprocess.run([str(relocated / "Contents/MacOS/ClipShelf"),
                                     "--localization-diagnostics", language],
                                    check=True, capture_output=True, text=True, timeout=20)
            diagnostics = json.loads(result.stdout)
            require(diagnostics.get("language") == language, "Runtime localization language mismatch")
            require(diagnostics.get("resourceSource") == "hostBundle",
                    "Delivered app fell back to a development resource location")
            directory = diagnostics.get("resourceDirectory")
            require(isinstance(directory, str) and Path(directory).resolve().is_relative_to(relocated.resolve()),
                    "Runtime resource directory escaped the delivered app")
            require(diagnostics.get("issues") == [], f"Runtime localization diagnostics: {diagnostics.get('issues')}")
            require(diagnostics.get("sample") == expected, f"Runtime translation mismatch: {language}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--share-extension", action="store_true")
    parser.add_argument("--runtime", action="store_true", help="Run only the isolated no-UI diagnostic command")
    args = parser.parse_args()
    verify_app(args.app, args.share_extension)
    if args.runtime:
        verify_relocated_runtime(args.app)
    print("Localization resources verified: " + ", ".join(LANGUAGES) + "; 3 App Intents.")


if __name__ == "__main__":
    main()
