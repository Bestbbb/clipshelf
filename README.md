# ClipShelf

A free, open-source clipboard manager for macOS. The goal is the full Paste for
Mac feature set and its smooth cross-app workflow.

**Status: native implementation in progress.** A development app can be built
locally. Full Paste parity, cross-app compatibility, cloud deployment, and a
signed public release are still being developed and verified.

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
or from the menu bar. Direct paste requires Accessibility
permission; without it, the app copies the selected content for manual pasting.

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

Quit an existing ClipShelf instance before switching to or from demo mode. The
build script uses an ad-hoc signature unless `CODESIGN_IDENTITY` is provided;
the development bundle is **not notarized**. Native data is kept separately in
`~/Library/Application Support/ClipShelf Development`.

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
