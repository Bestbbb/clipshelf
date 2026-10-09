#!/usr/bin/env python3
"""Build, notarize and sign local release artifacts; never publish or install them."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import sys
from urllib.parse import quote, urlsplit
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
SPARKLE_NS = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def run(argv, label, log=None):
    print(label, flush=True)
    result = subprocess.run([str(arg) for arg in argv], cwd=ROOT, capture_output=True)
    if log:
        with log.open("ab") as stream:
            stream.write(("\n" + label + "\n").encode())
            stream.write(result.stdout)
            stream.write(result.stderr)
    require(result.returncode == 0, label + " failed; inspect the local build log")
    return result


def secure_key_file(path):
    path = Path(path).absolute()
    metadata = path.lstat()
    require(stat.S_ISREG(metadata.st_mode) and metadata.st_nlink == 1,
            "Signing key must be a regular file, not a link")
    require(metadata.st_uid == os.getuid() and metadata.st_mode & 0o077 == 0,
            "Signing key must be owned by this user with no group/other permissions")
    return path


def download_prefix(value):
    require(value and not any(ord(c) < 33 for c in value), "Download prefix contains whitespace or controls")
    url = urlsplit(value)
    require(url.scheme == "https" and url.hostname and url.username is None and url.password is None and
            "?" not in value and "#" not in value and not url.path.endswith(".xml"), "Invalid HTTPS archive download prefix")
    _ = url.port  # Reject invalid ports before any signing work.
    return value.rstrip("/") + "/"


def archive_command(manifest, output):
    paths = manifest["paths"]
    return ["xcodebuild", "-project", str(ROOT / "native/ClipShelf.xcodeproj"), "-scheme", "ClipShelf",
            "-configuration", "Release", "-destination", "generic/platform=macOS", "-archivePath", str(output / "ClipShelf.xcarchive"),
            "-derivedDataPath", str(output / "DerivedData"), "-packageAuthorizationProvider", "netrc",
            "-onlyUsePackageVersionsFromResolvedFile", "ARCHS=arm64 x86_64", "ONLY_ACTIVE_ARCH=NO", "CODE_SIGN_STYLE=Manual",
            "CODE_SIGN_IDENTITY=Developer ID Application", "DEVELOPMENT_TEAM=" + manifest["teamID"],
            "CLIPSHELF_APP_BUNDLE_IDENTIFIER=" + manifest["appBundleIdentifier"],
            "CLIPSHELF_SHARE_BUNDLE_IDENTIFIER=" + manifest["shareBundleIdentifier"],
            "CLIPSHELF_APP_GROUP_IDENTIFIER=" + manifest["appGroupIdentifier"],
            "CLIPSHELF_APP_PROFILE=" + manifest["provisioningProfiles"][manifest["appBundleIdentifier"]],
            "CLIPSHELF_SHARE_PROFILE=" + manifest["provisioningProfiles"][manifest["shareBundleIdentifier"]],
            "CLIPSHELF_APP_INFOPLIST=" + paths["appInfoPlist"], "CLIPSHELF_SHARE_INFOPLIST=" + paths["shareInfoPlist"],
            "CLIPSHELF_APP_ENTITLEMENTS=" + paths["appEntitlements"], "CLIPSHELF_SHARE_ENTITLEMENTS=" + paths["shareEntitlements"],
            "ENABLE_HARDENED_RUNTIME=YES", "archive"]


def verify_plists(app, manifest):
    extension = app / "Contents/PlugIns/ClipShelfShare.appex"
    main_info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    for bundle, identifier in [(app, manifest["appBundleIdentifier"]), (extension, manifest["shareBundleIdentifier"])]:
        info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
        require(info.get("CFBundleIdentifier") == identifier and info.get("CFBundleVersion") == manifest["buildNumber"] and
                info.get("CFBundleShortVersionString") == manifest["version"], "App/extension release identity or version mismatch")
        require(info.get("ClipShelfAppGroupIdentifier") == manifest["appGroupIdentifier"], "App Group metadata mismatch")
    expected = {"ClipShelfDistribution": "release", "SUFeedURL": manifest["updateFeedURL"],
                "SUPublicEDKey": manifest["updatePublicEDKey"], "SUVerifyUpdateBeforeExtraction": True,
                "SURequireSignedFeed": True, "SUSignedFeedFailureExpirationInterval": 0,
                "SUEnableSystemProfiling": False, "SUEnableAutomaticChecks": False, "SUAutomaticallyUpdate": False}
    for key, value in expected.items():
        require(type(main_info.get(key)) is type(value) and main_info[key] == value, "Release updater configuration mismatch: " + key)
    require(main_info.get("ClipShelfCloudKitContainerIdentifier") == manifest.get("cloudKitContainerIdentifier"),
            "Release CloudKit container metadata mismatch")
    require((app / "Contents/Resources/Metadata.appintents").is_dir(), "App Intents metadata is missing")
    require((app / "Contents/Resources/Sparkle-LICENSE.txt").read_bytes() ==
            (ROOT / "native/Sources/ClipShelf/Sparkle-LICENSE.txt").read_bytes(), "Sparkle third-party notices are missing or altered")
    sparkle = app / "Contents/Frameworks/Sparkle.framework"
    sparkle_info = plistlib.loads((sparkle / "Resources/Info.plist").read_bytes())
    require(sparkle_info.get("CFBundleShortVersionString") == "2.10.0", "Unexpected Sparkle version")
    return extension, sparkle


def verify_bundle(app, manifest, log):
    extension, sparkle = verify_plists(app, manifest)
    run(["codesign", "--verify", "--deep", "--strict", app], "Verify complete bundle signatures", log)
    helpers = [sparkle / "Versions/B/Autoupdate", sparkle / "Versions/B/Updater.app",
               sparkle / "Versions/B/XPCServices/Installer.xpc", sparkle / "Versions/B/XPCServices/Downloader.xpc"]
    for bundle in [app, extension, sparkle] + helpers:
        require(bundle.exists(), "A signed update helper is missing")
        report = run(["codesign", "-d", "--verbose=4", bundle], "Verify release signer", log).stderr.decode()
        require("TeamIdentifier=" + manifest["teamID"] in report and "Authority=Developer ID Application:" in report,
                "Bundle/helper was not signed by the configured Developer ID team")
        if bundle != sparkle:
            require("runtime" in report, "Hardened runtime is missing from a release executable")
        if bundle in [app, extension]:
            result = run(["codesign", "-d", "--entitlements", ":-", bundle], "Verify release entitlements", log)
            entitlements = plistlib.loads(result.stdout)
            require(entitlements.get("com.apple.security.application-groups") == [manifest["appGroupIdentifier"]], "Signed App Group mismatch")
            expected_path = manifest["paths"]["appEntitlements" if bundle == app else "shareEntitlements"]
            expected_entitlements = plistlib.loads(Path(expected_path).read_bytes())
            for key, value in expected_entitlements.items():
                require(entitlements.get(key) == value, "Signed entitlement mismatch: " + key)
            for unsafe in ["com.apple.security.get-task-allow", "com.apple.security.cs.disable-library-validation",
                           "com.apple.security.cs.allow-unsigned-executable-memory", "com.apple.security.cs.allow-dyld-environment-variables",
                           "com.apple.security.cs.allow-jit"]:
                require(not entitlements.get(unsafe, False), "Unexpected development entitlement in release")
    for executable in [app / "Contents/MacOS/ClipShelf", extension / "Contents/MacOS/ClipShelfShare"]:
        architectures = run(["lipo", "-archs", executable], "Verify universal executable", log).stdout.decode().split()
        require(set(architectures) == {"arm64", "x86_64"}, "Release executable must include arm64 and x86_64")
    dependencies = run(["otool", "-L", app / "Contents/MacOS/ClipShelf"], "Verify framework linkage", log).stdout.decode()
    require("@rpath/Sparkle.framework/" in dependencies, "Sparkle is not linked through the app framework path")
    for line in dependencies.splitlines()[1:]:
        dependency = line.strip().split(" (", 1)[0]
        require(dependency.startswith(("@rpath/", "@loader_path/", "@executable_path/", "/System/Library/", "/usr/lib/")),
                "Executable references a dependency outside the app or system")
    load_commands = run(["otool", "-l", app / "Contents/MacOS/ClipShelf"], "Verify framework runpath", log).stdout.decode()
    require("@executable_path/../Frameworks" in load_commands or "@loader_path/../Frameworks" in load_commands,
            "App framework runpath is missing")


def verify_appcast_metadata(feed, archive, manifest, prefix):
    data = feed.read_bytes()
    require(len(data) <= 8 * 1024 * 1024 and b"<!DOCTYPE" not in data.upper(), "Appcast is oversized or contains a DTD")
    root = ET.fromstring(data)
    matches = []
    for item in root.findall("./channel/item"):
        enclosure = item.find("enclosure")
        if enclosure is None:
            continue
        version = item.findtext(SPARKLE_NS + "version") or enclosure.get(SPARKLE_NS + "version")
        if version == manifest["buildNumber"]:
            matches.append(enclosure)
    require(len(matches) == 1, "Appcast must contain exactly one enclosure for this build")
    enclosure = matches[0]
    require(enclosure.get("url") == prefix + quote(archive.name) and enclosure.get("length") == str(archive.stat().st_size),
            "Appcast archive URL or byte length mismatch")
    signature = enclosure.get(SPARKLE_NS + "edSignature", "")
    require(len(base64.b64decode(signature, validate=True)) == 64, "Missing or invalid archive signature")
    return signature


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path, help="New local release workspace; must not exist")
    args = parser.parse_args()
    env = os.environ
    require(env.get("CLIPSHELF_NOTARY_KEYCHAIN_PROFILE"), "CLIPSHELF_NOTARY_KEYCHAIN_PROFILE is required")
    require(env.get("SPARKLE_SIGNING_KEY_FILE"), "SPARKLE_SIGNING_KEY_FILE is required")
    key = secure_key_file(env.get("SPARKLE_SIGNING_KEY_FILE", ""))
    prefix = download_prefix(env.get("CLIPSHELF_UPDATE_DOWNLOAD_URL_PREFIX", ""))
    require(not run(["git", "status", "--porcelain", "--untracked-files=all"], "Check source state").stdout.strip(),
            "Use a clean checkout with no uncommitted or untracked files before producing a release")
    commit = run(["git", "rev-parse", "HEAD"], "Record source commit").stdout.decode().strip()
    run([sys.executable, ROOT / "scripts/configure-release.py", "--validate"], "Validate release configuration")
    feed_name = Path(urlsplit(env["CLIPSHELF_UPDATE_FEED_URL"]).path).name
    require(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*\.xml", feed_name), "Feed URL must end in a safe XML filename")
    output = args.output.absolute()
    require(not output.exists() and not output.is_symlink(), "Release output directory must not exist")
    output.mkdir(parents=True, mode=0o700)
    require(not key.is_relative_to(output), "Signing key must be outside the release workspace")
    log = output / "release-build.log"
    configuration = output / "configuration"
    run([sys.executable, ROOT / "scripts/configure-release.py", "--prepare", configuration], "Prepare release manifests", log)
    manifest = json.loads((configuration / "manifest.json").read_text())
    run(archive_command(manifest, output), "Archive universal app and Share Extension", log)
    run(["xcodebuild", "-exportArchive", "-archivePath", output / "ClipShelf.xcarchive", "-exportPath", output / "export",
         "-exportOptionsPlist", manifest["paths"]["exportOptionsPlist"]], "Export Developer ID app", log)
    app = output / "export/ClipShelf.app"
    verify_bundle(app, manifest, log)
    run([sys.executable, ROOT / "scripts/verify-localization.py", "--app", app,
         "--share-extension", "--runtime"], "Verify delivered app and Share Extension localizations", log)
    submission = output / "notary-submission.zip"
    run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, submission], "Package notarization submission", log)
    response = run(["xcrun", "notarytool", "submit", submission, "--keychain-profile", env["CLIPSHELF_NOTARY_KEYCHAIN_PROFILE"],
                    "--wait", "--output-format", "json"], "Notarize signed app", log)
    notarization = json.loads(response.stdout)
    require(notarization.get("status") == "Accepted", "Notarization was not accepted")
    (output / "notarization.json").write_text(json.dumps(notarization, indent=2) + "\n")
    run(["xcrun", "stapler", "staple", app], "Staple notarization ticket", log)
    run(["xcrun", "stapler", "validate", app], "Verify stapled ticket", log)
    run(["spctl", "--assess", "--type", "execute", "--verbose=2", app], "Verify Gatekeeper assessment", log)
    verify_bundle(app, manifest, log)
    assets = output / "assets"
    assets.mkdir(mode=0o700)
    archive = assets / ("ClipShelf-" + manifest["version"] + "-" + manifest["buildNumber"] + ".zip")
    run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, archive], "Package stapled update archive", log)
    tools = list((output / "DerivedData/SourcePackages/artifacts").glob("**/bin/generate_appcast"))
    require(len(tools) == 1, "Expected one pinned Sparkle appcast generator")
    generator = tools[0]
    sign_update = generator.with_name("sign_update")
    feed = assets / feed_name
    run([generator, "--ed-key-file", key, "--download-url-prefix", prefix, "--maximum-deltas", "0", "-o", feed, assets],
        "Generate signed update feed", log)
    signature = verify_appcast_metadata(feed, archive, manifest, prefix)
    run(["swift", ROOT / "scripts/verify-update-signature.swift", archive, manifest["updatePublicEDKey"], signature],
        "Verify archive against embedded Ed25519 public key", log)
    run([sign_update, "--ed-key-file", key, "--verify", feed], "Verify signed appcast", log)
    report = {"sourceCommit": commit, "version": manifest["version"], "buildNumber": manifest["buildNumber"],
              "notarizationID": notarization.get("id"), "appBundleIdentifier": manifest["appBundleIdentifier"],
              "artifacts": {path.name: {"bytes": path.stat().st_size, "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
                            for path in assets.iterdir() if path.is_file()}}
    (assets / "release-verification.json").write_text(json.dumps(report, indent=2) + "\n")
    print("Verified release artifacts saved locally in " + str(assets) + "; nothing was published or installed")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, ET.ParseError, plistlib.InvalidFileException, json.JSONDecodeError) as error:
        print("Release stopped: " + str(error), file=sys.stderr)
        sys.exit(1)
