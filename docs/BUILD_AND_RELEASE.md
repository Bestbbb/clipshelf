# Building and release status

The app is a native SwiftPM executable bundled by `scripts/build-macos.sh`.
The build currently targets the host architecture and macOS 14 or newer. The
tested toolchain is Xcode 26.5. `build-app-intents.sh` extracts the three native
Shortcuts actions into `Contents/Resources/Metadata.appintents`; a Swift executable
without that metadata is not a complete app bundle for Shortcuts.

## Local development

```sh
swift test --package-path native
./scripts/build-macos.sh
open build/ClipShelf.app --args --demo
```

Demo uses synthetic records and does not start clipboard recording, global
shortcuts, MCP, cloud requests, or screen context collection. Quit an existing
instance before changing launch modes.

The default output has an ad-hoc signature. It is useful for development but is
not a notarized public release. GitHub Actions builds the same development bundle
and uploads a ZIP artifact; it does not publish a release or use signing secrets.

The SwiftPM bundle does not embed the inbound Share Extension. The separate
`native/ClipShelf.xcodeproj` builds the containing app and extension together;
see [Share Extension setup and validation](SHARE_EXTENSION.md). CI checks that
project separately without signing. A valid shared App Group and matching team
signatures are still required to exercise the real system share sheet.

Link previews create a temporary WebKit session only after an explicit preview
action. The app permits HTTP as well as HTTPS in web content through Apple's
[web-content-specific ATS key](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowsarbitraryloadsinwebcontent).
This does not disable App Transport Security for the app's other network clients.

## Optional signed CloudKit build

Local features build without an Apple Developer account. CloudKit requires the
developer's own provisioned app identifier, container, signing identity and
matching entitlements. The app refuses to instantiate a CloudKit container when
its identifier or entitlement is missing. Merely opening settings makes no
account or network request.

Copy `native/Resources/ClipShelf.entitlements.example.plist` to a private local
file and replace the placeholder with the container provisioned for your team.
Keep certificates, private keys and provisioning profiles outside the repository.

```sh
BUNDLE_IDENTIFIER='your.bundle.identifier' \
ICLOUD_CONTAINER_IDENTIFIER='iCloud.your.bundle.identifier' \
CODESIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
ENTITLEMENTS_PATH='/absolute/private/path/entitlements.plist' \
PROVISIONING_PROFILE_PATH='/absolute/private/path/profile.provisionprofile' \
./scripts/build-macos.sh
```

Use your actual identifiers and signing material. Specifying these environment
variables does not create a container, grant access, initialize its schema, or
deploy the development schema to production. Those are separate Apple developer
operations. Private synchronization and shared Pinboards need two real accounts
and devices for the acceptance cases in the specification.

When a signing identity is supplied, the script requests the hardened runtime
and a timestamp. Notarization and stapling are separate release steps; they have
not been completed for this project. A production build must validate entitlements,
cloud schema, update migration, Accessibility authorization, Intel/Apple-silicon
support, and the distribution artifact before publication.

## Data and secret handling

The development data directory is `~/Library/Application Support/ClipShelf Development`.
Private named pasteboards and temporary databases are used by automated tests.
Tests do not require the user's clipboard, iCloud, Keychain, or screen content.

Encrypted exports use AES-256-GCM with a fresh 16-byte salt, a random GCM nonce,
and PBKDF2-HMAC-SHA256 with 600,000 iterations. The version and salt are
authenticated. Passwords are not stored. Plaintext export is an explicit option.
Local databases, temporary restore data and pre-restore recovery copies remain
unencrypted; password-protected export is not a claim of encrypted local storage
or end-to-end encrypted iCloud synchronization.

MCP access and refresh credentials are held in the local Keychain. Developer
signing material and runtime history must never be included in a release archive.

## Screen-sharing limitation

Do not assume `NSWindow.sharingType = .none` makes content invisible to every
screen recorder. Apple describes `NSWindow.SharingType.none` as a legacy constant
that macOS no longer uses. The project has not verified hiding with contemporary
ScreenCaptureKit capture or meeting applications. This is still an explicit
acceptance gap; there is no “protected from all screenshots” claim.

Sources: [Apple window sharing](https://developer.apple.com/documentation/appkit/nswindow/sharingtype-swift.enum/none),
[Continuity Camera](https://developer.apple.com/documentation/appkit/supporting-continuity-camera-in-your-mac-app),
[Writing Tools](https://developer.apple.com/documentation/appkit/supporting-writing-tools-via-the-pasteboard),
[CryptoKit AES-GCM](https://developer.apple.com/documentation/cryptokit/aes/gcm).
