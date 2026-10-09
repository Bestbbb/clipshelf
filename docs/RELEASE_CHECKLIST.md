# Release checklist

This is the procedure implemented by `scripts/release-macos.py`, not evidence that
a production release or real update has completed. Real Developer ID identities,
provisioning profiles, the update signing key and notarization credentials remain
unconfigured for this project. The current local Xcode installation cannot load
required platform plug-ins; the unsigned app/Share Extension build is checked by
CI on a working Xcode host. Check the exact commit's result in
[implementation status](IMPLEMENTATION_STATUS.zh-CN.md).

## 1. Establish an immutable source and release identity

- [ ] Use a clean checkout at the reviewed commit. The release script rejects
  uncommitted changes and untracked files, then records the full SHA. Preserve
  the matching CI evidence and package resolution lockfiles; Sparkle is pinned to
  2.10.0. Do not remove user files merely to satisfy the clean-checkout requirement.
- [ ] Use a working macOS/Xcode host and Python 3.9 or newer. Verify the selected
  toolchain with `xcodebuild -version`, `xcrun swift --version` and `python3 --version`.
- [ ] Provision the containing app, its `.share` extension and their shared App
  Group for the actual developer team. Both targets need the matching installed
  Developer ID provisioning profiles. Optional CloudKit also needs the actual
  production container and schema; configuration generation cannot create these.
- [ ] Select a new monotonically increasing `CFBundleVersion`. The human-readable
  version is separate. Preserve the existing production bundle identity and
  update public key unless a separately verified transition is planned.

## 2. Supply real public configuration

Export the following variables from the release operator's environment. No live
feed address or key is supplied by the repository; use the actual controlled
update endpoint and the public key paired with the intended signing key.

| Variable | Meaning and validation |
| --- | --- |
| `CLIPSHELF_DISTRIBUTION` | Must be `release` |
| `BUNDLE_IDENTIFIER` | Defaults to `io.github.bestbbb.clipshelf`; explicit dotted ID without `dev`, `demo` or `validation` components; extension uses this ID plus `.share` |
| `CLIPSHELF_VERSION` | One to three ASCII numeric components |
| `CLIPSHELF_BUILD_NUMBER` | Positive decimal integer, 1–18 digits, no leading zero; increase from every published build |
| `CLIPSHELF_TEAM_ID` | The actual 10-character uppercase letter/digit developer team identifier |
| `CLIPSHELF_UPDATE_FEED_URL` | Actual HTTPS feed URL without user information or fragment; the full release pipeline requires a safe `.xml` leaf filename |
| `CLIPSHELF_UPDATE_PUBLIC_ED_KEY` | Canonical standard base64 encoding of the actual 32-byte Ed25519 public key; not a private key |
| `CLIPSHELF_APP_GROUP_IDENTIFIER` | Matching app/extension group; `group.` prefix or the configured team prefix, with a valid dotted identifier |
| `CLIPSHELF_APP_PROFILE` | Installed containing-app provisioning profile name or UUID |
| `CLIPSHELF_SHARE_PROFILE` | Installed extension provisioning profile name or UUID |
| `ICLOUD_CONTAINER_IDENTIFIER` | Optional actual `iCloud.` container; omission generates no CloudKit entitlement |

The generator enforces these plist values rather than accepting policy overrides:

```text
ClipShelfDistribution = release
SUEnableAutomaticChecks = false
SUAutomaticallyUpdate = false
SUEnableSystemProfiling = false
SUVerifyUpdateBeforeExtraction = true
SURequireSignedFeed = true
SUSignedFeedFailureExpirationInterval = 0
```

For CloudKit, only the main app receives the configured container, `CloudKit`
service, `Production` container environment and macOS
`com.apple.developer.aps-environment = production`. The extension retains its
sandbox, user-selected read-only access and the same App Group. The macOS APS key
differs from the iOS key; see [Apple's entitlement definition](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.aps-environment).

After exporting the real values, public validation and optional inspection are:

```sh
export CLIPSHELF_DISTRIBUTION=release
python3 scripts/configure-release.py --validate

RELEASE_CONFIG_DIR="$(mktemp -d)/configuration"
python3 scripts/configure-release.py --prepare "$RELEASE_CONFIG_DIR"
plutil -lint "$RELEASE_CONFIG_DIR/"*.plist "$RELEASE_CONFIG_DIR/"*.entitlements
python3 -m json.tool "$RELEASE_CONFIG_DIR/manifest.json"
```

`--validate` needs neither an installed signing identity nor the private signing
key. `--prepare` additionally requires the group/profile inputs, reads the two
resource templates, and publishes a complete new directory atomically. It rejects
an existing output directory, unsafe symlink paths and malformed configuration.
It does not query profiles, Keychain, cloud accounts or network services.

The generated files are `App-Info.plist`, `ShareExtension-Info.plist`,
`App.entitlements`, `ShareExtension.entitlements`, `ExportOptions.plist` and
`manifest.json`. The manifest records public identities, versions, feed/public
key, group/profile mappings and final paths; it never includes private-key bytes.
ExportOptions requests `developer-id`, manual signing and the configured team.
Inspect app/extension versions and group membership together before proceeding.

`--plist PATH` instead atomically updates an existing generated app plist while
preserving unrelated keys. The SwiftPM development bundler uses it only when
explicitly selecting release metadata, and then separately requires a
`CODESIGN_IDENTITY` in Developer ID Application format. That bundler still lacks
the full embedded-extension, archive/export, universal and notarization pipeline;
it is not the command for producing the complete distribution below.

## 3. Prepare signing and notarization outside the repository

| Additional variable | Required resource |
| --- | --- |
| `CLIPSHELF_NOTARY_KEYCHAIN_PROFILE` | Name of an already configured `notarytool` Keychain profile, accessible on the release host |
| `SPARKLE_SIGNING_KEY_FILE` | Existing private signing-key file accepted by Sparkle's `--ed-key-file`; owned by the current user, regular file with no hardlink/symlink and no group/other permissions, outside the release workspace |
| `CLIPSHELF_UPDATE_DOWNLOAD_URL_PREFIX` | Actual HTTPS archive-hosting directory, without user information, query or fragment; it must match where the completed ZIP will later be published |

- [ ] Keep certificates, profiles, private keys and notarization credentials out
  of source, generated manifests and publishable assets. Obtain and safeguard the
  key using the [Sparkle setup procedure](https://sparkle-project.org/documentation/);
  this checklist does not supply key material or a private-key generation example.
- [ ] Confirm the private signing key matches `CLIPSHELF_UPDATE_PUBLIC_ED_KEY`.
  The pipeline verifies the resulting archive against that embedded public key;
  merely possessing a key file or generating a feed is insufficient.
- [ ] Ensure the Xcode archive/export process can use the actual Developer ID
  Application identity for `CLIPSHELF_TEAM_ID`. The full pipeline supplies the
  signing class and team to Xcode and subsequently checks each signer; it does
  not treat a valid-looking environment string as signing evidence.

## 4. Run the full local artifact pipeline

Choose `RELEASE_OUTPUT_DIR` outside the checkout, with a destination that does not
yet exist. This command performs real signing and submits the archive to Apple's
notarization service when credentials are configured:

```sh
: "${RELEASE_OUTPUT_DIR:?Set a new local release workspace path}"
python3 scripts/release-macos.py --output "$RELEASE_OUTPUT_DIR"
```

The script stops on failure. Its stages are:

1. Record the clean source SHA and prepare the public configuration set.
2. Archive the app and Share Extension with manual signing, hardened runtime and
   both `arm64` and `x86_64`; export with the generated Developer ID options.
3. Verify app/extension IDs, matching versions and App Group, signed entitlements,
   App Intents metadata, Sparkle 2.10.0 and all required signed helpers. Check
   universal executables, framework runpaths and absence of external build-path
   linkage or development entitlements.
4. Submit the archive with `notarytool --wait`; require `Accepted`, staple and
   validate the ticket, run `spctl --assess`, then repeat bundle verification.
5. Package the stapled app with `ditto`, preserving framework symlinks. Use the
   pinned Sparkle generator to produce the archive signature and signed appcast;
   delta generation is disabled in this pipeline. Verify the enclosure URL,
   build number, byte length, archive signature against the embedded public key,
   and signed-feed verification. Record SHA-256 and byte counts of local assets.

The release archive/export route follows Sparkle's guidance for its signed helper
bundles; archive/feed signing and symlink preservation are described in
[Sparkle setup](https://sparkle-project.org/documentation/) and
[Publishing an update](https://sparkle-project.org/documentation/publishing/).

Review the generated `configuration/manifest.json`, `release-build.log`,
`notarization.json`, exported app and `assets/release-verification.json`.
The assets directory contains `ClipShelf-<version>-<build>.zip`, the feed filename
derived from the configured URL, and verification data. Preserve the archive and
debug symbols for diagnosis. Intermediate build/notarization logs are local
operational evidence and should be reviewed before sharing.

**Nothing is uploaded to the update host or GitHub, installed, or launched by this
script.** A successful local pipeline is a prerequisite to an independently
authorized publication step, not a completed real update test. Editing the app,
ZIP, feed or release notes after signing requires rebuilding the applicable
signature; do not reformat the signed feed before publication.

## 5. Accept the actual signed update and user experience

These gates remain open until exercised with real signed old/new builds and the
intended hosting endpoint. Synthetic configuration/coordinator tests do not close
them.

- [ ] Confirm manual check, available/current/incompatible versions, offline and
  server errors, cancellation, skipped offers, repeated checks and failure retry.
- [ ] Confirm automatic checks and downloads initially default off; explicit
  opt-ins persist through relaunch. System profiling stays disabled. Development,
  demo and validation runs never construct/start Sparkle, even on opening settings.
- [ ] Reject bad/wrong-key archive signatures and unsigned/tampered feeds; verify
  the signed-feed policy has no failure grace interval. Check actual host/CDN
  bytes, HTTPS URLs, content delivery and cache behavior after authorized publishing.
- [ ] With a downloaded update, verify dirty-editor save/discard/cancel and active
  record/Undo/history-cleanup/asset-GC transactions keep their normal termination
  boundaries. Deferred restart must retry once when eligible. Cancelling quit
  leaves updating usable; `stop()` runs only on `applicationWillTerminate`.
- [ ] Confirm disabling automatic download does not falsely promise to discard an
  already staged update; installation still waits for normal quit. Verify actual
  replacement, relaunch, preserved data, settings, permissions and recovery after
  interrupted downloads/installations on a real disposable test profile.
- [ ] Test both architectures on supported Macs, actual App Group Share Extension
  receipt, Accessibility-based cross-app paste and, if configured, real private and
  shared CloudKit accounts. Unsigned CI cannot validate these privileges.
- [ ] Confirm release data uses `Application Support/ClipShelf`, development uses
  `ClipShelf Development`, and validation remains temporary. No automatic merge of
  the development history into the production profile is promised.
- [ ] Record current localization limitations: application strings are largely
  hardcoded Simplified Chinese; language switching and complete localization are
  still missing F13 work. Sparkle's own translations do not complete this feature.

Do not mark F13, signed distribution, real update/relaunch, or the broader Paste
compatibility scope complete solely because these scripts and synthetic tests exist.
