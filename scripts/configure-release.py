#!/usr/bin/env python3
"""Validate public release inputs and generate deterministic macOS configuration.

No signing, profile lookup, Keychain access, private key handling or networking.
--plist updates an existing generated app plist, never a source template.
--prepare atomically publishes a new directory; an existing destination is rejected.
"""
from __future__ import annotations

import argparse
import base64
import binascii
import ctypes
import ipaddress
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import sys
import uuid
from dataclasses import dataclass
from urllib.parse import unquote_to_bytes, urlsplit


ROOT = Path(__file__).resolve().parent.parent
MAX_PLIST_BYTES = 4 * 1024 * 1024
UPDATE_POLICY = {
    "SUEnableAutomaticChecks": False,
    "SUAutomaticallyUpdate": False,
    "SUEnableSystemProfiling": False,
    "SUVerifyUpdateBeforeExtraction": True,
    "SURequireSignedFeed": True,
    "SUSignedFeedFailureExpirationInterval": 0,
}
FILENAMES = {
    "appInfoPlist": "App-Info.plist",
    "shareInfoPlist": "ShareExtension-Info.plist",
    "appEntitlements": "App.entitlements",
    "shareEntitlements": "ShareExtension.entitlements",
    "exportOptionsPlist": "ExportOptions.plist",
}


class ConfigurationError(Exception):
    """Messages describe fields, never their supplied contents."""


def required(env, name):
    value = env.get(name)
    if not value:
        raise ConfigurationError(name + " is required.")
    return value


def identifier(value, field, reject_development=False):
    # Explicit, dotted identifiers; no wildcard, Xcode expansion or empty component.
    if (len(value) > 249 or not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", value)
            or any(part.startswith("-") or part.endswith("-") for part in value.split("."))):
        raise ConfigurationError(field + " must be a valid explicit dotted identifier.")
    if reject_development and {"dev", "demo", "validation"}.intersection(value.lower().split(".")):
        raise ConfigurationError(field + " cannot use a dev, demo or validation component.")
    return value


def feed_url(value):
    error = "CLIPSHELF_UPDATE_FEED_URL must be an HTTPS URL without credentials or a fragment."
    if (not value.isascii() or any(ord(c) <= 32 or ord(c) == 127 for c in value)
            or "\\" in value or "#" in value or re.search(r"%(?![0-9A-Fa-f]{2})", value)):
        raise ConfigurationError(error)
    try:
        parts = urlsplit(value)
        host = parts.hostname
        port = parts.port
        if (parts.scheme != "https" or not parts.netloc or not host
                or "@" in parts.netloc or parts.username is not None or parts.password is not None
                or "%" in parts.netloc or parts.netloc.endswith(":")
                or (port is not None and not 1 <= port <= 65535)
                or any(byte < 32 or byte == 127 for byte in unquote_to_bytes(value))):
            raise ValueError()
        if parts.netloc.startswith("["):
            if not re.fullmatch(r"\[[0-9A-Fa-f:.]+\](?::[0-9]+)?", parts.netloc):
                raise ValueError()
        elif not re.fullmatch(r"[A-Za-z0-9.-]+(?::[0-9]+)?", parts.netloc):
            raise ValueError()
        try:
            ipaddress.ip_address(host)
        except ValueError:
            labels = (host[:-1] if host.endswith(".") else host).split(".")
            if (len(host) > 253 or any(not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?", label)
                                       for label in labels)):
                raise ValueError()
    except (ValueError, UnicodeError):
        raise ConfigurationError(error) from None
    return value


def public_key(value):
    try:
        raw = base64.b64decode(value, validate=True)
        if len(raw) != 32 or base64.b64encode(raw).decode("ascii") != value:
            raise ValueError()
    except (ValueError, binascii.Error):
        raise ConfigurationError("CLIPSHELF_UPDATE_PUBLIC_ED_KEY must be canonical standard base64 encoding exactly 32 bytes.") from None
    return value


def profile(value, field):
    if (len(value.encode("utf-8")) > 256 or value != value.strip()
            or any(ord(c) < 32 or ord(c) == 127 for c in value) or "$(" in value):
        raise ConfigurationError(field + " must be a profile name or UUID without control characters or build expansions.")
    return value


@dataclass(frozen=True)
class ReleaseConfiguration:
    app_bundle: str
    version: str
    build: str
    team: str
    feed: str
    key: str
    group: str | None
    app_profile: str | None
    share_profile: str | None
    cloud: str | None

    @property
    def share_bundle(self):
        return self.app_bundle + ".share"

    @classmethod
    def from_environment(cls, env, prepare=False):
        if env.get("CLIPSHELF_DISTRIBUTION") != "release":
            raise ConfigurationError("CLIPSHELF_DISTRIBUTION must be release.")
        bundle = identifier(env.get("BUNDLE_IDENTIFIER", "io.github.bestbbb.clipshelf"), "BUNDLE_IDENTIFIER", True)
        version = required(env, "CLIPSHELF_VERSION")
        if len(version) > 64 or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", version):
            raise ConfigurationError("CLIPSHELF_VERSION must contain one to three numeric components.")
        build = required(env, "CLIPSHELF_BUILD_NUMBER")
        if not re.fullmatch(r"[1-9][0-9]{0,17}", build):
            raise ConfigurationError("CLIPSHELF_BUILD_NUMBER must be a positive decimal integer of at most 18 digits.")
        team = required(env, "CLIPSHELF_TEAM_ID")
        if not re.fullmatch(r"[A-Z0-9]{10}", team):
            raise ConfigurationError("CLIPSHELF_TEAM_ID must contain ten uppercase ASCII letters or digits.")
        feed = feed_url(required(env, "CLIPSHELF_UPDATE_FEED_URL"))
        key = public_key(required(env, "CLIPSHELF_UPDATE_PUBLIC_ED_KEY"))
        group = env.get("CLIPSHELF_APP_GROUP_IDENTIFIER")
        if prepare:
            group = required(env, "CLIPSHELF_APP_GROUP_IDENTIFIER")
        if group is not None:
            identifier(group, "CLIPSHELF_APP_GROUP_IDENTIFIER", True)
            if not (group.startswith("group.") or group.startswith(team + ".")):
                raise ConfigurationError("CLIPSHELF_APP_GROUP_IDENTIFIER must start with group. or the configured team identifier.")
        profiles = []
        for name in ["CLIPSHELF_APP_PROFILE", "CLIPSHELF_SHARE_PROFILE"]:
            value = required(env, name) if prepare else env.get(name)
            if value is not None:
                if not value:
                    raise ConfigurationError(name + " cannot be empty when supplied.")
                value = profile(value, name)
            profiles.append(value)
        cloud = env.get("ICLOUD_CONTAINER_IDENTIFIER")
        if cloud is not None:
            identifier(cloud, "ICLOUD_CONTAINER_IDENTIFIER", True)
            if not cloud.startswith("iCloud."):
                raise ConfigurationError("ICLOUD_CONTAINER_IDENTIFIER must start with iCloud.")
        return cls(bundle, version, build, team, feed, key, group, profiles[0], profiles[1], cloud)

    def app_plist(self, template):
        result = dict(template)
        result.update(UPDATE_POLICY)
        result.update({"CFBundleIdentifier": self.app_bundle, "CFBundleShortVersionString": self.version,
                       "CFBundleVersion": self.build, "ClipShelfDistribution": "release",
                       "SUFeedURL": self.feed, "SUPublicEDKey": self.key})
        for name, value in [("ClipShelfAppGroupIdentifier", self.group), ("ClipShelfCloudKitContainerIdentifier", self.cloud)]:
            if value is None:
                result.pop(name, None)
            else:
                result[name] = value
        return expand_template(result, self, "ClipShelf", self.app_bundle)

    def share_plist(self, template):
        result = expand_template(template, self, "ClipShelfShare", self.share_bundle)
        result.update({"CFBundleIdentifier": self.share_bundle, "CFBundleShortVersionString": self.version,
                       "CFBundleVersion": self.build, "ClipShelfDistribution": "release",
                       "ClipShelfAppGroupIdentifier": self.group})
        return result


def expand_template(value, config, executable, bundle):
    replacements = {"$(PRODUCT_BUNDLE_IDENTIFIER)": bundle, "$(EXECUTABLE_NAME)": executable,
                    "$(PRODUCT_MODULE_NAME)": executable, "$(CLIPSHELF_APP_GROUP_IDENTIFIER)": config.group or "",
                    "$(MARKETING_VERSION)": config.version, "$(CURRENT_PROJECT_VERSION)": config.build}
    if isinstance(value, str):
        for key, replacement in replacements.items():
            value = value.replace(key, replacement)
    elif isinstance(value, dict):
        value = {key: expand_template(item, config, executable, bundle) for key, item in value.items()}
    elif isinstance(value, list):
        value = [expand_template(item, config, executable, bundle) for item in value]
    return value


def safe_path(path):
    raw = os.fspath(path)
    if not raw or "\x00" in raw or ".." in Path(raw).parts:
        raise ConfigurationError("Output path is invalid.")
    absolute = Path(os.path.abspath(raw))
    # macOS ships these root-owned aliases. All remaining components are opened
    # with O_NOFOLLOW, including user-created aliases below the system prefix.
    for alias in ["tmp", "var", "etc"]:
        prefix = Path("/") / alias
        if absolute == prefix or prefix in absolute.parents:
            try:
                info = os.lstat(prefix)
                if stat.S_ISLNK(info.st_mode) and info.st_uid == 0 and os.readlink(prefix) == "private/" + alias:
                    absolute = Path("/private") / alias / absolute.relative_to(prefix)
            except OSError:
                pass
    return absolute


def open_directory(path):
    path = safe_path(path)
    descriptor = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        for component in path.parts[1:]:
            next_descriptor = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = next_descriptor
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def identity(info):
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns)


def require_parent_identity(path, descriptor):
    check = open_directory(path)
    try:
        old, current = os.fstat(descriptor), os.fstat(check)
        if (old.st_dev, old.st_ino) != (current.st_dev, current.st_ino):
            raise ConfigurationError("Output directory changed during preparation.")
    finally:
        os.close(check)


def read_plist_at(parent, name):
    descriptor = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK, dir_fd=parent)
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or before.st_size > MAX_PLIST_BYTES:
            raise ConfigurationError("Plist input must be a bounded regular file with no aliases.")
        with os.fdopen(os.dup(descriptor), "rb") as stream:
            data = stream.read(MAX_PLIST_BYTES + 1)
        if identity(before) != identity(os.fstat(descriptor)) or len(data) != before.st_size:
            raise ConfigurationError("Plist input changed while reading.")
        try:
            result = plistlib.loads(data)
        except Exception:
            raise ConfigurationError("Plist input is malformed.") from None
        if not isinstance(result, dict):
            raise ConfigurationError("Plist input must contain a dictionary.")
        return result, before
    finally:
        os.close(descriptor)


def read_template(name):
    parent = open_directory(ROOT / "native" / "Resources")
    try:
        return read_plist_at(parent, name)[0]
    finally:
        os.close(parent)


def encode_plist(value):
    return plistlib.dumps(value, fmt=plistlib.FMT_XML, sort_keys=True)


def write_new(parent, name, data, mode=0o600):
    descriptor = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, mode, dir_fd=parent)
    with os.fdopen(descriptor, "wb") as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())


def update_plist(path, config):
    path = safe_path(path)
    if path in {(ROOT / "native/Resources/Info.plist"), (ROOT / "native/Resources/ShareExtension-Info.plist")}:
        raise ConfigurationError("--plist accepts a generated app plist, not a source template.")
    parent = open_directory(path.parent)
    temporary = ".clipshelf-info-" + uuid.uuid4().hex
    try:
        original, before = read_plist_at(parent, path.name)
        data = encode_plist(config.app_plist(original))
        write_new(parent, temporary, data, stat.S_IMODE(before.st_mode) & 0o777)
        require_parent_identity(path.parent, parent)
        current = os.stat(path.name, dir_fd=parent, follow_symlinks=False)
        if not stat.S_ISREG(current.st_mode) or identity(current) != identity(before):
            raise ConfigurationError("Plist destination changed before publication.")
        os.replace(temporary, path.name, src_dir_fd=parent, dst_dir_fd=parent)
        os.fsync(parent)
    finally:
        try:
            os.unlink(temporary, dir_fd=parent)
        except FileNotFoundError:
            pass
        os.close(parent)


def rename_new_directory(parent, source, destination):
    # renameatx_np RENAME_EXCL atomically rejects an existing destination, including
    # an empty directory or symlink created between validation and publication.
    if sys.platform != "darwin":
        raise ConfigurationError("Atomic release-directory preparation requires macOS.")
    library = ctypes.CDLL(None, use_errno=True)
    rename = library.renameatx_np
    rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(parent, os.fsencode(source), parent, os.fsencode(destination), 0x00000004) != 0:
        raise OSError(ctypes.get_errno(), "Cannot publish release configuration directory")


def prepare_directory(path, config):
    path = safe_path(path)
    # Validate and encode the complete set before creating any output directory.
    app = config.app_plist(read_template("Info.plist"))
    share = config.share_plist(read_template("ShareExtension-Info.plist"))
    app_entitlements = {"com.apple.security.application-groups": [config.group]}
    if config.cloud:
        # Apple's macOS CloudKit template and entitlement documentation use this
        # macOS-specific APS key, not iOS's aps-environment.
        # https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.aps-environment
        app_entitlements.update({"com.apple.developer.icloud-container-identifiers": [config.cloud],
                                 "com.apple.developer.icloud-services": ["CloudKit"],
                                 "com.apple.developer.icloud-container-environment": "Production",
                                 "com.apple.developer.aps-environment": "production"})
    share_entitlements = {"com.apple.security.app-sandbox": True,
                          "com.apple.security.files.user-selected.read-only": True,
                          "com.apple.security.application-groups": [config.group]}
    profiles = {config.app_bundle: config.app_profile, config.share_bundle: config.share_profile}
    options = {"method": "developer-id", "signingStyle": "manual", "teamID": config.team,
               "signingCertificate": "Developer ID Application", "provisioningProfiles": profiles}
    manifest = {"schemaVersion": 1, "distribution": "release", "appBundleIdentifier": config.app_bundle,
                "shareBundleIdentifier": config.share_bundle, "version": config.version, "buildNumber": config.build,
                "teamID": config.team, "appGroupIdentifier": config.group, "updateFeedURL": config.feed,
                "updatePublicEDKey": config.key, "provisioningProfiles": profiles,
                "paths": {key: str(path / filename) for key, filename in FILENAMES.items()}}
    if config.cloud:
        manifest["cloudKitContainerIdentifier"] = config.cloud
    values = {"appInfoPlist": app, "shareInfoPlist": share, "appEntitlements": app_entitlements,
              "shareEntitlements": share_entitlements, "exportOptionsPlist": options}
    files = {FILENAMES[key]: encode_plist(value) for key, value in values.items()}
    files["manifest.json"] = (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode("utf-8")
    parent = open_directory(path.parent)
    staging = ".clipshelf-release-" + uuid.uuid4().hex
    directory = None
    created = False
    published = False
    try:
        try:
            os.stat(path.name, dir_fd=parent, follow_symlinks=False)
        except FileNotFoundError:
            pass
        else:
            raise ConfigurationError("--prepare requires a destination that does not exist.")
        os.mkdir(staging, mode=0o700, dir_fd=parent)
        created = True
        directory = os.open(staging, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=parent)
        for name, data in files.items():
            write_new(directory, name, data)
        os.fsync(directory)
        require_parent_identity(path.parent, parent)
        current = os.stat(staging, dir_fd=parent, follow_symlinks=False)
        if (current.st_dev, current.st_ino) != (os.fstat(directory).st_dev, os.fstat(directory).st_ino):
            raise ConfigurationError("Staging directory changed before publication.")
        rename_new_directory(parent, staging, path.name)
        published = True
        os.fsync(parent)
    finally:
        if created and not published and directory is not None:
            # Only remove our known leaves; never recursively delete foreign content.
            for name in files:
                try:
                    os.unlink(name, dir_fd=directory)
                except OSError:
                    pass
            try:
                current = os.stat(staging, dir_fd=parent, follow_symlinks=False)
                held = os.fstat(directory)
                if (current.st_dev, current.st_ino) == (held.st_dev, held.st_ino):
                    os.rmdir(staging, dir_fd=parent)
            except OSError:
                pass
        if directory is not None:
            os.close(directory)
        os.close(parent)


def main(argv=None, environ=None):
    parser = argparse.ArgumentParser(description=__doc__)
    operation = parser.add_mutually_exclusive_group(required=True)
    operation.add_argument("--validate", action="store_true", help="validate public release environment without writing")
    operation.add_argument("--plist", type=Path, help="atomically update an existing generated app Info.plist")
    operation.add_argument("--prepare", type=Path, help="atomically create a new directory with all release configuration")
    args = parser.parse_args(argv)
    try:
        config = ReleaseConfiguration.from_environment(os.environ if environ is None else environ, prepare=args.prepare is not None)
        if args.plist is not None:
            update_plist(args.plist, config)
        elif args.prepare is not None:
            prepare_directory(args.prepare, config)
    except ConfigurationError as error:
        print("Release configuration error: " + str(error), file=sys.stderr)
        return 2
    except (OSError, ValueError, TypeError, OverflowError):
        # Do not echo paths, environment values, profile names or plist contents.
        print("Release configuration error: configuration files could not be read or published safely.", file=sys.stderr)
        return 2
    print("Release configuration validated." if args.validate else "Release configuration written.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
