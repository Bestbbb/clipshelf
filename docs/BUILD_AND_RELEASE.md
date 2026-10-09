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

For isolated acceptance work, use the separate validation mode after building:

```sh
open build/ClipShelf.app --args --validation
```

Validation uses synthetic records, a temporary database, separate preferences,
and a separate OCR cache. Clipboard capture and background integrations are
disabled. It exercises normal queries and the real paste path: choosing an item
to paste **does write to the system clipboard**, and direct insertion still
requires Accessibility authorization and a valid target. It is not the same as
the demo, which never writes to the system clipboard. Use a blank temporary
target document and quit the existing instance before switching modes.

For deep-page and device-filter acceptance, add `--validation-search` alongside
`--validation`. This creates 908 synthetic records, including a 450-item board,
known local/remote installation IDs and unknown legacy sources. Search for
`TARGET-DEEP-HISTORY` or `TARGET-DEEP-BOARD` and use Cmd-G to locate the record.
The extra flag alone never populates a normal database.

Multi-Pinboard checkbox filtering, combined type/source/date conditions, manual
item-order controls, and the OCR preview/cache are implemented in the current
source. Schema-v8 adds a literal-substring candidate index and installation-origin
metadata; migration and ordering synchronization pass automated tests,
including simulated concurrent edits; real-device synchronization still needs acceptance. Normal/compact
layouts and single-item keyboard/mouse reordering have been checked with synthetic data.
Multi-item dragging, browser targets, and Accessibility-based direct paste still need
live validation. Deep-page Cmd-G now requests a bounded window around the exact
item. Device filtering, previous/next pages and 300-item windows are implemented;
the new layout and full search-to-render latency still need live acceptance.
Legacy records remain unknown rather than being assigned to this Mac. The
installation ID is not the device that originally created a file or text, and
Universal Clipboard does not provide enough evidence to label an iPhone source.

The 300-item limit applies to the displayed metadata window, not selection.
With result-list focus, Cmd-A selects the full filtered query; Shift/Cmd expansion
uses a frozen ordered set of item IDs and revisions across pages. New captures
do not silently join that set. Edited or deleted selected items invalidate the
batch. Text-field focus keeps the normal text-selection shortcuts.

Payload resolution validates the whole selection in one SQLite read snapshot
before reading attachments. The default aggregate raw-content budget is 512 MiB;
missing content, stale revisions, corrupt attachments or a budget overflow fail
the whole batch without truncation. This budget is not a process-memory ceiling.
Move/reorder operations use metadata; purely local operations and their placement
undo do not load attachments. Synced records still serialize their existing
immutable outbox payloads individually.

Edit and batch-selection undo retain at most 10 actions and 512 MiB of original
content retained for deletions and edits in total. Oldest actions are evicted to stay within those limits; a deletion that
alone exceeds the budget is rejected. Undo checks versions, board positions,
permissions and both account-configuration generations. Trusted receipts support
consecutive edit/move undos without accepting intervening changes. Deleted-content
restore is atomic and its capability can succeed only once. Existing cloud
tombstones prevent restoring the old ID; restored history preserves the batch's
relative order, not its original row positions in the complete history. Successful
backup restoration clears the undo history.

The current Mac was locked during the selection iteration. New cross-page
selection, batch actions and undo have not completed live desktop acceptance;
Accessibility-authorized direct paste and real CloudKit synchronization are also
still unverified. For commit `e55453c`, on 2026-10-10 at 00:03 (Asia/Taipei), the unified suite ran
280 tests with zero failures and one skip for unavailable Apple Intelligence.
The release build, App Intents extraction, local ad-hoc signature verification,
and Node bridge syntax check passed. Its [CI run 37956500803](https://github.com/Bestbbb/clipshelf/actions/runs/37956500803)
also passed, including the independent app and Share Extension build. Those
results precede the shortcut changes described below. The saved [search benchmark](../native/Benchmarks/README.md)
measured commit is `e78ef3f` (schema v8), against `45edfd6` (schema v7); it was not
rerun for the selection, shortcut or boundary/filter changes and does not measure selection, payload output,
facet aggregation or input-to-render latency.

In one Pinboard's manual-order view, drag a card to reorder it. Hold Option while
dragging to export its original content to another app. Ordinary history view
continues to drag original content directly. Internal sorting markers are never
offered as external clipboard content.

Acceptance evidence and remaining browser/Accessibility checks are recorded in
[IMPLEMENTATION_STATUS.zh-CN.md](IMPLEMENTATION_STATUS.zh-CN.md).

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

## Configurable shortcuts

The source supports four chords (panel, Stack, previous Pinboard and next
Pinboard) plus separate single modifiers for Quick Paste and plain text. Other
app commands remain fixed. Resetting shortcuts restores those six fields without
changing the independent always-plain-text preference; a reset is still a draft
until Save. Only panel and Stack are global; Pinboard keys apply to result-list
focus, and text editing keeps its native shortcuts.

Draft changes validate immediately and probe new system registrations without
replacing existing handles. A probe is a point-in-time check, not a reservation
or proof of hardware key delivery. Save validates and encodes again, stages all
new registrations, and only then replaces the action mapping and preferences.
A failed replacement releases only staged handles. Swapping the two global
chords reuses existing handles. Startup reports each registration separately.
An already registered Carbon chord is forwarded to the recorder only while the
settings window is key and actively recording; losing focus cancels recording.

Labels and fixed-character conflict checks use the current keyboard layout with
the chord's actual modifiers, including Command-specific mappings such as
Dvorak–Qwerty Command. Fixed event routing uses the actual command character,
which may differ from the character ignoring modifiers.
Input-source changes refresh labels, cancel recording and revalidate each global
binding; newly conflicting bindings are released while valid bindings remain.
When the layout becomes compatible again, registration is retried and any system
conflict is reported. An ANSI fallback label does not make an unavailable layout
safe for Command-character registration. Legacy `shortcutPreset` values 0/1/2
migrate in memory. Damaged or unknown-schema data, or configuration invalid under
the current layout, is preserved with a warning and temporary defaults; only a
successful save replaces it.

Model tests, a fake registration backend and unshown controller tests cover this
logic. A read-only check also uses installed Dvorak–Qwerty Command layout data
without selecting that input source. These tests do not establish real Carbon
key delivery, Secure Input behavior,
IME compatibility, or live non-US layout changes. Full-query first/last navigation
and the repeat-Cmd-F all-filters entry point are being integrated in the next
iteration described below; they are not covered by this shortcut commit's results.

**For commit `6a73011`, on 2026-10-10 at 00:31:24 (Asia/Taipei), the unified suite
ran 331 tests with zero failures and one skip for unavailable Apple Intelligence.
At 00:31:54 the native release build, App Intents metadata extraction and local
ad-hoc signature verification passed; the development ZIP passed its integrity
check.** Its CI evidence is [run 37959910860](https://github.com/Bestbbb/clipshelf/actions/runs/37959910860).
The Mac was still
locked on the latest desktop observation; live keyboard and cross-app acceptance
remain open.

## Full-query boundaries and all filters

The current iteration adds explicit first/last boundary navigation. Ordinary
Cmd-Up/Down finds the complete query's endpoint and returns at most 300 metadata
rows from one SQLite read snapshot; the last-page count and window cannot observe
different commits. It does not load all selection references or attachments.
An empty result has no focused item. Existing strict anchor navigation is retained.

Shift-Cmd-Up/Down targets the endpoints of the frozen selection universe. New
captures do not join an existing universe. The extended selection is staged;
its target window and all selected revisions must validate before the UI commits
both the window and selection. Stale targets or changed items fail explicitly.
New queries, sessions, focus changes and subsequent actions invalidate late replies.

Pressing Cmd-F with search already focused, or choosing All Filters, opens a
query draft for type, source app, device, date bounds, Pinboards and sort order.
Editing, cancellation and dismissal do not submit a query. Apply validates the
whole draft and submits it once. Keywords are preserved; Clear Filters also
preserves sorting, so manual order still requires exactly one existing board.
Unavailable source/device conditions remain visible and selected; unavailable
boards must be explicitly deselected before Apply. Invalid or reversed dates
are rejected without broadening the query.

**On 2026-10-10 at 00:49:30 (Asia/Taipei), this iteration ran 366 native tests with
zero failures and one skip for unavailable Apple Intelligence. At 00:50:09 the
native release build, App Intents metadata and local ad-hoc signature verification
passed; the development ZIP passed its integrity check.** See
[GitHub Actions](https://github.com/Bestbbb/clipshelf/actions/workflows/macos.yml)
for the corresponding commit's CI result. Regressions cover pending-navigation
output protection, stale callbacks, retained background refresh, native search
editing and filter checkbox focus after option refresh. Core and unshown-controller
tests remain separate from live desktop acceptance; the Mac is still locked and
real keyboard, IME, cross-app and filter-popover acceptance remain open.

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

Image and rich-text representations include their original bytes. Ordinary
Finder records remain external file-URL references. New Share Inbox files use
an explicit local asset registry in database schema 9. Each asset has a checked
immutable original and a separate file projection for opening in other apps.
Edits made by another app to that projection are not added to the stored
original or its backup. Local file copies and trusted Undo retain asset bindings.

Archive schema 3 embeds registered originals, SHA-256 metadata, and record/slot
bindings. Restore validates the whole manifest, creates fresh asset IDs and
paths in the destination profile, and never reads old paths from the archive.
Schema 2 remains readable but cannot recover file bytes that were never stored.
Encrypted export wraps the same schema 3 archive. Export checks a conservative
metadata-based size budget before loading attachments, then enforces the final
512 MiB envelope limit, including both layers of base64. This is not an RSS limit.

Backup and restore actions first adopt legacy ShareImports files using local
completed receipts, exact record/slot paths, and bounded regular-file reads.
This does not require an App Group. Adoption preserves a migration-time snapshot;
the old receipt cannot verify the original share bytes. Uncertain or missing
files stop the action with a report, and deleted entries are not resurrected.
For restore, password authentication and complete archive validation precede
adoption. A prepared archive is bound to the current store and both account
configuration generations. A portable recovery backup precedes database changes;
SQL/outbox/commit failure removes only newly created owned assets.

Unreferenced owned originals are currently retained so deletion/edit Undo and
failed shared drafts keep their dependencies. There is no automatic asset garbage
collection yet; deleting a history entry is not a secure erasure of those bytes.
Local originals, projections, migration snapshots, and recovery backups are
unencrypted. Cloud operations still carry file URLs; portable backup does not
implement owned-file byte synchronization. Paste's file-retention semantics remain
pending baseline validation.

File records now open a complete file/location list, including unavailable slots.
Explicit external-file relocation uses a native one-item file/folder picker and
stores a reference only. The affected part is rebuilt with file-URL representations
so old opaque/preview formats cannot keep pointing at the previous file; other
parts are preserved. Strict edit Undo restores the original representations and
never moves or deletes the user's files. A repair snapshot is bound to the store,
record revision, slot bytes, and both account generations. Read-only shared items
cannot be relocated.

Missing owned projections can be rebuilt from the checked immutable original.
The operation publishes a complete file without overwriting existing projections,
including externally edited ones. This local maintenance does not change record
revisions, Undo, or cloud operations; revoked or stale accounts cannot invoke it.
Preview/open is explicit, checks current availability, and cannot establish that
another receiving app will retain access. Native picker/Quick Look focus, real
cross-app transfers, and sandboxed distribution access remain acceptance gates.
History copy, paste, payload drag, and system sharing validate owned projections
through the store before output. Stack keeps captured occurrences across history
coalescing and separately checks references to registered projections. Ordinary
external symlinks remain external references; unsafe owned projections are rejected.
Filesystem availability can still change after validation or after another app
receives a URL; this is not a file-access lease.

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
