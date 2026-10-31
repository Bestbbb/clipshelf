# ClipShelf

A free, open-source clipboard manager for macOS. The goal is the full Paste for
Mac feature set and its smooth cross-app workflow.

> **Early preview.** Copying, searching and pasting back into the original app
> work in TextEdit, Safari, Chrome and Cursor. ClipShelf is not yet a complete
> replacement for Paste: expect rough edges, and please
> [open an issue](https://github.com/Bestbbb/clipshelf/issues) when something breaks.

## Download

Get the latest build from the [Releases page](https://github.com/Bestbbb/clipshelf/releases).

- Requires macOS 14 or later on an Apple silicon Mac (M1 or later).
- Preview builds are signed with a fixed self-signed ClipShelf certificate, but
  **not with an Apple Developer ID and not notarized**. macOS blocks the first
  launch: right-click `ClipShelf.app` and choose **Open**, or click **Open Anyway**
  in **System Settings → Privacy & Security**. If macOS reports the app as damaged:

  ```sh
  xattr -dr com.apple.quarantine /Applications/ClipShelf.app
  ```

- Grant **Accessibility** permission when asked so ClipShelf can paste back into
  the app you were using. Without it, items are copied and you press ⌘V yourself.
  From 0.2.0-preview on, the same certificate signs every preview, so replacing
  the app with a newer preview keeps this permission. Coming from 0.1.0-preview,
  remove the old ClipShelf entry under Accessibility and grant it once more.

## Use

- Press **⇧⌘V** anywhere to open the shelf at the bottom of the screen.
- Type to search, then click a card or press Return to paste it at your cursor.
  Shift-Return pastes plain text, ⌘1–9 pastes the matching card, Esc closes.
- Start or pause recording, and find settings, from the menu bar icon.

## Build and run

Requires macOS 14 or later and Xcode with its Swift toolchain. Development is
currently tested on Apple silicon with Xcode 26.5. SwiftPM downloads the pinned
Sparkle update framework; its license is included in the app bundle.

```sh
swift test --disable-keychain --disable-netrc --package-path native
./scripts/build-macos.sh
open build/ClipShelf.app
```

Launch adds the menu bar item. The first time you open history or start recording,
the welcome flow lets you start or postpone capture. Open the panel with **⌘⇧V**,
or from the menu bar. Find an item and **click once to paste into the original
input**. ⌘/Shift-click selects multiple items; dragging keeps its existing
behavior. Direct paste requires Accessibility
permission; without it, the app copies the selected content for manual pasting.

**Settings… → Automatic paste mode** defaults to Compatible, which attempts to
restore the original input without rejecting a changed AX object identity.
Strict retains window/field/selection checks; Copy only never sends a paste.
The most recently captured target app can have its own override. Each attempt
keeps its original mode even if settings change while it is waiting.
Mouse activation keeps the shelf visible for the remaining system double-click
interval before returning to the target. Keyboard activation skips that wait.

**Diagnostics…** shows Accessibility permission, actual registered shortcuts,
registration failures, paste modes, physical footprint and the last 20 attempts
in the current session. It excludes clipboard contents and does not treat command
dispatch as proof of insertion. If the opening shortcut is occupied at startup,
ClipShelf tries ⌃⇧V, ⌥⇧V and ⇧⌘Space and saves the first available binding.
The menu warning reports the actual binding; notifications use existing permission.

The shelf enters with a short upward motion and fade, while search and keyboard
selection are available immediately. Reduce Motion skips the entrance animation.
Escape dismisses the main shelf in one press, including while searching.
Dismissal remains immediate, including during an unfinished animation; reopening
cannot revive an earlier transition or lose a preserved editing draft.

Space previews every object in a mixed clipboard record through an object
selector, including rich text, embedded attachments, images, PDFs and file
locations. Unsupported formats remain listed with their sizes; HTML is shown as
source. Previews preserve the original bytes, and switching objects cancels
stale decoding. Editing and file/image tools retain the complete source record.

The interface supports 16 languages, including English, Simplified/Traditional
Chinese, Japanese, Korean and Hebrew with right-to-left navigation.
Choose **Language…** from the menu or welcome dialog; saving takes effect on the
next launch and preserves current work. Native-speaker and live interface review
remain pending; see [localization details](docs/LOCALIZATION.md).

To inspect the interface using synthetic samples without clipboard recording:

```sh
open build/ClipShelf.app --args --demo
```

For isolated paste acceptance, `--validation` creates synthetic records in a
temporary library and disables clipboard recording. Adding `--validation-trace`
prints structured focus/paste events to stderr without clipboard contents,
window titles, file paths or credentials. These diagnostics are off by default;
selecting Copy or Paste in validation mode still writes the system clipboard.

`--diagnostic-trace` enables the same metadata-only trace for normal runs.
Summarize stderr, including native warning lines, with:

```sh
python3 scripts/summarize-trace.py /path/to/trace.jsonl --output /path/to/summary.md
```

Quit an existing ClipShelf instance before switching to or from demo mode. The
build script uses an ad-hoc signature unless `CODESIGN_IDENTITY` is provided;
the development bundle is **not notarized**. Native data is kept separately in
`~/Library/Application Support/ClipShelf Development`.

## Development status

**Status (2026-10-13): the installed candidate has verified receiver results in
TextEdit, Safari, Chrome, and Cursor; physical-hotkey acceptance remains pending.** Earlier user feedback
reported usable basic functionality, while the workflow still fell short of Paste.
Cards support one-click paste. Earlier automated observations of insertion and
continued typing in Cursor's chat input and code editor are recorded in the
[single-click workflow record](docs/SINGLE_CLICK_WORKFLOW.zh-CN.md).
The latest input-selection restoration changes and their verified scope are
recorded in the [generic paste workflow record](docs/GENERIC_PASTE_WORKFLOW.zh-CN.md).
Full Paste for Mac parity and broad daily-use acceptance remain incomplete.
Earlier failed acceptance and its retrospective are preserved as history.
The [2026-10-12 implementation record](docs/IMPROVEMENT_IMPLEMENTATION.zh-CN.md)
tracks the first stage of the colleague's [improvement specification](docs/IMPROVEMENT_SPEC.zh-CN.md).
It adds compatible/strict/copy-only modes, bounded AX queries, click handoff and
session diagnostics. Its original acceptance and storage failures are historical
checkpoints; the current candidate results are recorded below.
The [2026-10-13 follow-up](docs/IMPROVEMENT_FOLLOWUP.zh-CN.md) fixes those storage
issues, image-promise completion ordering and the remaining compatible-mode
AX-window requirement. Its 1,411-test result is a historical checkpoint;
the subsequent full CI run exposed a remaining cold-initialization race and an
incorrect scroll-layout assertion.
The [latest receiver acceptance record](docs/PASTE_ACCEPTANCE_2026-10-13.zh-CN.md)
records the installed candidate's ten valid rounds each in TextEdit, Safari,
Cursor chat, and Cursor's editor, plus four Chrome rounds. It also records real
clipboard capture followed by one-click insertion and continued typing in
standard mode in TextEdit, Chrome, and both Cursor inputs. These use application
reopen, not a verified physical hotkey; interrupted rounds and explicit target
setup are identified, so they do not satisfy the full P1 gate.
The candidate fixes explicit-destination handoff and avoids rewriting an
already-correct AX caret. Source commit `8d1240f` passed the local and
[remote full suite](https://github.com/Bestbbb/clipshelf/actions/runs/38367552283)
(1,418 tests, zero failures, one unavailable-model skip), with no added or
deleted ClipShelf preference files.
An additional local diagnostic run is recorded in the
[core-flow rerun](docs/CORE_FLOW_RERUN.zh-CN.md). A later user trace showed app
launches capturing Finder as the paste destination. The focused local fixes and
their limited verification are recorded in the
[launcher diagnosis](docs/LAUNCHER_FLOW_DIAGNOSIS.zh-CN.md).

Some automated text and Pinboard workflows produced passing observations, but
those results did not establish usability through the user's normal entry points.
See the [failure retrospective](docs/REPLICATION_FAILURE_RETROSPECTIVE.zh-CN.md)
and the [historical test record](docs/LOCAL_USABILITY_QA.zh-CN.md).

## Implementation

Swift and AppKit power the panel and system integration; SQLite and separate
content-addressed files hold local history and attachments. The app includes
work in progress on rich clipboard content, search, Pinboards, editing,
previews, OCR, sequential pasting, privacy controls, backups, and MCP access.
CloudKit sync/sharing, on-device model suggestions, native system services and
Shortcuts have their own configuration and permission gates.

Clipboard representations are read into a frozen snapshot, then decoded and
saved in order off the main actor. A failed save pauses recording and retains
pending items in memory for explicit retry or discard. Pausing or locking cancels
waiting saves; a write already in progress may still finish. Polling cannot
recover copies overwritten between observations.

Mixed clipboard records can edit one supported text, link or color object at a
time. An object selector keeps the remaining objects intact; switching away from
an unsaved draft asks whether to keep editing or discard it. Unsupported embedded
attachments stay read-only, and original-format output preserves the other objects.
Edit Undo also checks the saved content, so a backup that reuses the same record
ID and revision cannot be overwritten by a stale Undo action.

Deleting and undoing a synced item restores its content as a new item while
retaining the old deletion marker. Local history position, board position and
owned files are preserved, and earlier edits and moves remain undoable when
their captured state still matches. Temporary storage failures retain the Undo
action for retry. Older clients can read restored items but may order equal-rank
board items differently until upgraded.

Multi-selection merges only complete ordinary text objects, preserving supported
RTF formatting. A selection containing other formats keeps every original object
and representation in order. Explicit plain-text conversion reads actual text or
link addresses from each object; it does not paste display summaries as content.
Receiving applications still decide which offered representations they accept.

Storage Management reports library files, shared caches and the share inbox
separately, including unavailable scopes. Core writes and backups check volume
capacity before growing data. OCR caches, PNG exports and file promises, the
share inbox, import receipts, and application-owned cloud staging use the same
capacity checks on their destination volumes. These are cooperative estimates,
not physical disk reservations; CloudKit and item-provider temporary files remain
outside application control. A separate saved-data limit is unlimited by default
and can be configured per library. It counts saved record data, deduplicated
attachments, registered managed originals and persisted sync payloads. Reaching
the limit preserves existing data and pending captures for explicit retry after
cleanup or a limit change. This is not a physical-directory quota: database
overhead, caches, backups and temporary/output files are outside its accounting.
Automatic managed-file reclamation is off until enabled; a complete physical
storage quota remains in progress.

See the [implementation status](docs/IMPLEMENTATION_STATUS.zh-CN.md) for what is
implemented, tested, and still missing. Individual feature availability does not
mean the full product has passed acceptance. The earlier Tauri scaffold remains
for project history; `native/` is the active implementation.

MCP and cloud access are opt-in. Do not put real clipboard data, credentials,
private screenshots, or signing material into issues or test fixtures.

## Design and acceptance

- [Technical specification · 技术规格](docs/TECHNICAL_SPEC.zh-CN.md)
- [Product flows and acceptance · 产品动线与体验验收](docs/PRODUCT_FLOWS.zh-CN.md)
- [Baseline checklist · 对标记录清单](docs/BASELINE_CHECKLIST.zh-CN.md)
- [Implementation status · 实现与验证状态](docs/IMPLEMENTATION_STATUS.zh-CN.md)
- [Build, cloud configuration and release status](docs/BUILD_AND_RELEASE.md)
- [Local MCP and OAuth integration](docs/MCP.md)
- [System Share Extension setup](docs/SHARE_EXTENSION.md)
- [Interface languages and localization checks](docs/LOCALIZATION.md)
- [Reproducible local-history performance measurements](native/Benchmarks/README.md)

The current scope is full macOS parity, including sync between Macs. iPhone and
iPad clients are outside this scope and may be planned separately later.
Development proceeds from public documentation and independent tests; an
eligible Paste trial can later refine the real-app comparison baseline.

## License

[MIT](LICENSE). Source code and complete application downloads are intended to
be free. ClipShelf is independent and is not affiliated with Paste.
