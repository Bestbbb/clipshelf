# Building and release status

The app is a native Swift executable. `scripts/build-macos.sh` bundles the SwiftPM
development build for the host architecture and macOS 14 or newer; the separate
`scripts/release-macos.py` pipeline archives a universal app with its Share Extension.
The
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

Payload resolution validates the whole selection in one SQLite transaction snapshot
before reading attachments. Retained owned-file output registers its lease under
the writer lock before returning the selected records. The default aggregate raw-content budget is 512 MiB;
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
retains the `e78ef3f` (schema v8) versus `45edfd6` (schema v7) comparison and now
adds an independent refresh of exact commit `08f4998` (schema v12). That refresh
does not cover subsequent updater/release work, selection, payload output,
facet aggregation or input-to-render latency. Its single connection-open timing
increased and needs separate repeat measurement/profiling; query timings alone
cannot establish unchanged startup cost or attribute the difference to GC.

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

The current local Xcode installation has a platform plug-in loading failure, so
local Xcode archive/Share Extension validation is blocked. The dedicated CI job
builds the containing app and extension without signing; its result must be checked
for the exact commit. A SwiftPM build, older CI pass, or unsigned Xcode build does
not establish a working Developer ID release. The real identities, profiles,
update signing key and notarization credentials have not been configured or used
to run the complete release pipeline here.

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
operations. Private synchronization needs two real Macs on the same account;
shared Pinboards additionally need distinct owner/participant accounts. Neither
real-device path has completed acceptance. The current source implements owned-file
transfer through both adapters, but local CKRecord tests do not provision or validate
a development or production container.

Provision the following CloudKit record types and fields, preserving the existing
operation type names for compatibility:

| Record type | Record name | Fields |
| --- | --- | --- |
| `ClipShelfOperationV1` | Operation UUID | `payload` (Asset), `sha256` (String), `account` (String), `formatVersion` (Int); v2 adds `payloadByteCount` (Int) |
| `ClipShelfSharedOperationV1` | Operation UUID | `payload` (Asset), `sha256` (String), `namespace` (String), `formatVersion` (Int); v2 adds `payloadByteCount` (Int) |
| `ClipShelfOwnedFileV1` | `owned-<sha256>` | `sha256` (String), `byteCount` (Int), `chunkCount` (Int), `formatVersion` (Int, currently 1), `container` (String), `namespace` (String), `scopeKind` (String), `zoneName` (String), `chunk0` (Asset), optional `chunk1` (Asset) |

Owned blobs use one or two assets of at most 32 MiB each, retaining the 64 MiB
original-file limit. This chunk size is an implementation budget, not evidence
that production service limits and quota behavior have been accepted. Verify the
record types, field types, zone permissions and schema deployment in the actual
container. Shared owners use their private database; invited members use the
shared database. Cloud records bind a shared board's namespace and zone, never
the uploading participant's actual account. Local transfer caches still bind the
actual account, container, database, zone owner/name and namespace.

Required live cases include same-account private transfer, different-account
read-only/read-write participants, owner aliases, revocation during a request,
offline/restart recovery, account changes, missing assets, quotas, and 64 MiB
multi-asset round trips. See [the owned-file protocol and acceptance gates](SYNC_FILE_ASSETS_PLAN.zh-CN.md).

When a signing identity is supplied, the development script requests the hardened
runtime and a timestamp. It does not perform the complete release pipeline below.
Notarization and stapling have not been completed for this project. A production build must validate entitlements,
cloud schema, update migration, Accessibility authorization, Intel/Apple-silicon
support, and the distribution artifact before publication.

## Application updates and controlled release

The source pins Sparkle **2.10.0**, embeds its framework and required helper/XPC
bundles, and adds Check for Updates plus update settings. Development bundles and
`--demo`/`--validation` runs do not construct or start the updater, including when
settings open; they make no updater network requests. A release run must first
validate its distribution marker, independent bundle ID, HTTPS feed, canonical
32-byte Ed25519 public key, versions and all six update policy values. See the
[configuration generator](../scripts/configure-release.py) and
[runtime validation](../native/Sources/ClipShelf/UpdateConfiguration.swift).

Automatic checks and automatic downloads default to off. Sparkle owns the user's
opt-in preferences, last-check date and update UI; the app does not overwrite those
preferences on each launch. System profiling is disabled. Package verification
before extraction and signed feeds are mandatory, with zero signed-feed failure
grace interval. A finished check is not automatically reported as “up to date.”
The configuration uses Sparkle's documented
[update and signed-feed controls](https://sparkle-project.org/documentation/customization/).

A downloaded update does not bypass normal termination. Active writes/cleanup
and session suspension postpone an installation restart; dirty editors retain
their normal save/discard/cancel flow. The settings window can retry a deferred
restart. Cancelling quit keeps the updater usable; the app calls its `stop()` only
from `applicationWillTerminate`. Turning off automatic downloads does not cancel
an update already downloaded for installation on normal quit. These behaviors
have synthetic coordinator coverage; actual signed update/relaunch and cross-app
focus acceptance remain open.

Public configuration preparation and a verified distribution are separate steps:

| Entry point | Effect and required evidence |
| --- | --- |
| `python3 scripts/configure-release.py --validate` | Validates public release environment only; no signing identity/profile lookup, Keychain or network access |
| `python3 scripts/configure-release.py --plist PATH` | Validates, then atomically updates an existing generated app plist; source templates are rejected |
| `python3 scripts/configure-release.py --prepare DIR` | Requires App Group and profile names, then atomically creates two Info plists, two entitlements, ExportOptions and a public manifest in a new directory; it does not establish provisioning or signatures |
| `./scripts/build-macos.sh` | Development/host-architecture bundle by default; opting into release metadata also requires an explicit Developer ID identity, but still does not add the full archive/export/notarization process or Share Extension |
| `python3 scripts/release-macos.py --output DIR` | Full local release-artifact pipeline; requires a clean checkout and real signing/provisioning/update-key/notary inputs, and stops if a validation step fails |

The full pipeline prepares app/extension configuration, runs Xcode archive/export
for arm64 and x86_64, validates identities, entitlements, App Intents, Sparkle/helper
signatures and linkage, submits notarization, staples and validates the ticket,
and checks Gatekeeper assessment. It then packages the stapled app, generates an
Ed25519-signed archive and signed appcast, independently verifies the archive
against the embedded public key, and records artifact hashes. The output remains
local: the script neither publishes a GitHub release/feed nor installs or launches
the app. Its implemented checks do not constitute a completed real release run.

Use [RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md) for exact configuration inputs,
commands, artifact review and still-open acceptance steps. Do not put illustrative
feed addresses or synthetic keys into a shipping bundle. Developer ID and Sparkle
signatures serve different purposes; Sparkle documents the required archive/feed
signing process in [Publishing an update](https://sparkle-project.org/documentation/publishing/).
The current application strings are largely hardcoded Simplified Chinese;
language selection/localization remains missing within F13, even though the updater
framework has its own localized UI.

## Data and secret handling

The development data directory is `~/Library/Application Support/ClipShelf Development`.
An explicitly marked release with a valid independent bundle identifier uses
`~/Library/Application Support/ClipShelf`; switching distributions does not merge
the development database into that directory. Validation retains its temporary
database and independent preferences in either distribution.
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
an explicit local asset registry introduced in database schema 9. Each asset has a checked
immutable original and a separate file projection for opening in other apps.
Edits made by another app to that projection are not added to the stored
original or its backup. Local file copies and trusted Undo retain asset bindings.

Database schema 10 introduced per-record local mutation tokens for history cleanup.
That migration preserves row IDs, ordering, and owned-file bindings; its tokens do
not alter archive schema 3 or cloud payloads. SQL insert/update triggers rotate
the token, detecting same-ID/revision replacement through restore or a second
connection without reading the clipboard payload during confirmation preparation.
The current database version is 12. Version 11 added the owned-file synchronization
tables described below; version 12 adds local leases, persistent publication roots
and the reclamation journal. Owned-file synchronization still uses wire v2 and
portable backups still use archive schema 3.

Manual clear and retention changes display a frozen metadata summary: deletion,
pinned preservation, private/shared sync subsets, and excluded account/permission
records. Commit revalidates every candidate and both account generations within
the same transaction as the existing outbox. New records do not expand a confirmed
plan; changed candidates cause a whole-operation failure requiring fresh confirmation.
Cancel/close/Escape/session suspension invalidate unsubmitted work. Already dispatched
transactions finish normally, and quit is deferred until their result is known.
Only success updates the retention preference, list, menu checkmark, and OCR cleanup.
Undo tickets depending on affected records are removed; unrelated Undo remains.

Startup/hourly retention uses the same coordinator, coalesces while user mutations
are active, and yields to manual requests. Selecting permanent retention clears
queued automatic work. History retention removes records; the separate, optional
owned-file reclamation pass described below can follow successful cleanup. Neither
action promises immediate free disk space. Automated tests use temporary
databases and unshown native windows; actual confirmation focus/keyboard behavior,
large-library latency, disk-full recovery, and live sync propagation remain gates.

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

Owned originals remain protected while deletion/edit Undo, failed shared drafts or
other live references need them. Schema 12 adds safe local reclamation after those
dependencies end; deleting a history entry is not a secure erasure of those bytes.
Local originals, projections, migration snapshots, and recovery backups are
unencrypted. Owned-file byte synchronization is now a separate implemented protocol,
not an effect of portable backup. Ordinary external references and legacy v1 URL-only
operations still do not contain recoverable file bytes. Paste's file-retention
semantics remain pending baseline validation.

Schema 11 stores immutable operation/manifest proofs, exact transfer scopes,
shared-access generations, verified local asset mappings, durable transfer states,
legacy backfill markers, and explicit local-recovery markers. Upgrade first creates
a database-and-attachments recovery copy. Existing v1 outbox IDs and JSON bytes are
preserved; eligible registered originals receive new causal v2 operations only within
the already-enabled account and writable scope. Read-only sharing and old-account
items are not backfilled as new writes. Archive format remains schema 3 and does not
export cloud authorization, transfer confirmations or account queues.

New owned-file operations use `formatVersion: 2` with a portable manifest and internal
file tokens, followed by receiver-local IDs, paths and registry bindings. Unsupported
versions and outer/inner version disagreements are rejected. The adapters upload and
verify the immutable original's blobs before publishing its operation; edits to a
projection or later revision cannot replace that queued original. Successful responses
and lost-response retries compare complete CloudKit identity, scope, version and hash;
v2 operation metadata also binds its payload length. Legacy v1 encoding stays stable.

Change feeds request metadata without payload/chunk assets, then fetch operation
payloads and needed blobs separately. Auxiliary blob records/deletions are distinguished
from immutable operation-log deletions. Asset bytes are copied immediately from CloudKit
temporary files using bounded regular-file/no-follow reads into independently held
staging. Core revalidates them before caching or publishing a usable local revision.
The inbox and cursor persist before files finish; an old usable revision remains
available while its replacement waits. Per-file failures remain retryable, independent
operations can progress, and transaction failures roll back only newly staged assets.

Limits are 64 MiB per original, 256 MiB of manifest file bytes and at most 64 files/bindings
per operation, and 512 MiB of attempted file transfer per coordinator pass, combining
uploads and downloads. Files move sequentially; budget-deferred work stays pending for
a later pass. These limits are neither process-memory nor total-disk ceilings. The
existing operation JSON limit is separately 256 MiB. Settings expose outstanding
upload/download tasks, failure reasons and explicit retry without enabling synchronization
or looking up an account merely to show status.

Synthetic two-store and CloudKit-codec tests exercise reconstruction, immutable retries,
shared members with different accounts, account/permission changes, migration,
commit rollback, malformed assets, version compatibility and chunked 64 MiB files.
They do not establish real two-Mac convergence, production schema availability,
server quota behavior, live settings focus or signed distribution access. Those remain
release gates; see [the full protocol](SYNC_FILE_ASSETS_PLAN.zh-CN.md) and
[the current implementation evidence](IMPLEMENTATION_STATUS.zh-CN.md).

Storage Management reports the managed owned-file tree: registered originals,
their opening projections, and reclamation quarantine. It does not report or clean
the database, ordinary representation attachments, OCR cache, exported-file cache,
independent backups, or external Finder originals. Logical file lengths and
filesystem allocated bytes are separate measurements; neither is a promise of
space that the volume will release. An incomplete scan reports measured lower
bounds and an incomplete status; an unreadable scan is not displayed as zero.
Unknown, unregistered asset directories are counted and preserved.

Manual reclamation freezes a candidate set for confirmation and rechecks account
generations, references, registry metadata and filesystem identity before mutation.
Automatic owned-file reclamation is a separate preference, **off by default**.
After the user enables it, startup, hourly and successful-history-cleanup requests
reuse the same prepare/commit checks and defer while other mutations are active.
Disabling it prevents new automatic commits; already submitted journaled work
finishes normally. Opening storage settings neither enables sync nor contacts an
account. Capacity admission/reservations and a complete profile-wide storage limit
are not implemented by this feature.

History references, pinned records, Undo, Stack, editing/preview and prepared output,
pending sync operations, verified partial downloads, accepted shared replay and
failed shared drafts retain their required originals. Temporary leases are registered
atomically with resolution and held by process file locks; process exit releases the
lock, without a time-based expiry. Missing or replaced lock identities remain protected.
Completed private operation snapshots can be retired when no durable replay or pending
operation requires them. Backup export and upload staging hold the database writer
lock while copying owned originals into independent data.

Published file URLs have persistent roots, because copy, drag, sharing or open returning
does not prove that another app has finished using a file. Clipboard publications
survive restart and are released only after a stable, completely readable pasteboard
snapshot contains neither their marker nor any published URL; uncertain reads retain
them. External-open, sharing and drag publications have no automatic expiry. Storage
Management lists their purposes and paths for explicit confirmation that external
consumers no longer need them. Releasing that exact reviewed set removes protection
only; it does not immediately delete files or release current clipboard/lease roots.
Migration from before schema 12 conservatively protects every existing registered
asset as a legacy external use, subject to the same explicit review.

Reclamation accepts only the verified owned layout and unchanged original/projection
bytes. Externally modified projections, extra files, unsafe paths and unverifiable
identities remain for inspection. A durable per-asset journal precedes atomic
quarantine; a second writer transaction rechecks every matching intent before any
rename. Metadata rollback or a pre-commit crash uses that identity proof to restore
the quarantined directory; failed safe recovery retains its journal. After metadata
commits, restart recovery continues bounded deletion. Recovery handles
only existing authorized journal entries, even when automatic reclamation is off.
Physical file/byte results count successful unlinks; completed groups are counted
only after their journal completion commits. Pending recovery remains visible.
The process uses no-follow directory/file checks and cannot delete ordinary external
files or independent backups. It is not secure erasure or cloud-blob deletion.

Synthetic regression coverage includes cross-connection/process leases, publication
restart retention, legacy migration, modified/unknown file preservation, concurrent
reclamation intents and failed metadata/journal commits. Historical milestone counts
above apply only to their corresponding revisions, not this schema-12 change. Current
unified test, build and CI evidence belongs in the implementation status document;
live storage-window behavior, large-library responsiveness, actual cross-app file
use and signed release acceptance remain open. Physical copies of a database plus
owned tree may have different inode identities; recovery conservatively retains such
unverifiable locks/journals rather than promising automatic cleanup of a cloned profile.

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
Owned-file retention leases and persistent publication roots prevent this app's GC
from removing referenced assets. Filesystem availability can still change through
external modification, and retention does not grant another app sandbox access.

Image-file output now prepares every image part off the main thread, preserving
other clipboard objects and their order. Option-drag uses native file promises,
with per-provider byte/delegate ownership and writes to the receiver-provided URL.
Copy/paste-as-file uses controlled PNG exports, eligible for cleanup after 24 hours
on a subsequent export. This cache policy is not receiver acknowledgement. PNG
conversion applies orientation and uses the first frame; ordinary image drag keeps
the original representations. A batch is limited to 64 Mi pixels and 512 MiB PNG
data. Stale or failed unpublished batches are discarded without deleting replaced
files. File receiver compatibility and actual focus remain live acceptance gates.

File previews offer system-listed applications and an Other Application picker.
Choosing an application revalidates the file and invokes NSWorkspace explicitly,
without changing default file associations. Tests inject discovery/open callbacks;
passing them does not prove real Launch Services or sandbox access.

Text, link, and RGB editing capture a store-bound snapshot before enabling the
editor. Save revalidates the complete original, revision, account generations, and
write access in one transaction; only successful commits register Undo, and only
successful save replies automatically close the editor. Failures retain the in-memory draft, formatting, selection, and text
Undo state. RTF conversion failure never silently falls back to plain text.
Link text, public.url, and RTF targets are rebuilt consistently; RGB is validated
as six ASCII hexadecimal digits and saved as #RRGGBB. Multiple objects, embedded
attachments, and unknown non-text formats cannot be flattened by this editor.
HTML-only editing explicitly converts to text/RTF. Actual source-app formatting
and native Writing Tools remain acceptance gates.

App switching and session suspension hide content windows while keeping dirty or
save-pending editors in memory. Unmodified editors close, as do hidden editors
whose save succeeds. Explicit reopening restores any still-unsaved draft; it does
not paste or recapture account authorization. Dirty close confirmations must settle before a
subsequent settings/import/backup action runs. Stale confirmations and save replies
cannot affect a later editor. Drafts are not persisted across process exit. Native
discard sheets, app-switch focus, color wells, and quit cancellation still require
desktop acceptance in addition to injected controller tests.

Rename and image rotation now use the same store-bound editing snapshot and
commit/Undo path. Naming changes only the trimmed user title, supports arbitrary
original parts, and reuses the existing draft lifecycle. Image previews remain
read-only until rotation is requested. Failed rotation saves retain the original
preview and retry the same snapshot and converted bytes; dismissed or superseded
pre-submit work cannot write. A submitted transaction can finish after dismissal,
but its UI reply cannot reopen or alter a newer preview.

Rotation applies EXIF orientation then turns the first previewed image part left
90 degrees. Other parts remain byte-for-byte unchanged. Ordinary single-frame output is
PNG; GIF keeps its container even with one frame, and GIF/APNG/TIFF retain every frame, with animation loop/delay verification and
exact APNG rational timing. Unsupported multi-frame formats fail explicitly.
Limits are 1,000 frames, 64 Mi total pixels, and 512 MiB estimated raw working
bytes/retained-plus-encoded content; these are not a process RSS ceiling.
High-bit-depth and HDR color fidelity remain separate acceptance gaps.

Changed-image OCR runs before the final edit transaction and joins its single
revision; OCR failure still permits the image save. Old derived cache cleanup
happens only after a successful commit and finishes before UI completion. Cache
failure cannot convert a committed edit into a retryable failure. This prevents a
second OCR revision from immediately invalidating preview references and Undo.
Synthetic tests cover transaction failure, account changes during recognition,
repeated rotation, preserved frames/pixels, late replies, and actual Core Undo.
Native rename/preview focus, animation playback, and cross-app output still need
desktop acceptance.

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
