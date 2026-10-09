# ClipShelf

A free, open-source clipboard manager for macOS, with the full feature set and
cross-app workflow of Paste as its product benchmark.

**Status: planning and documentation review.** Implementation is paused while
the product flows, technical design, and acceptance criteria are reviewed.
There is no working application release yet.

## Product goal

Open a panel from the app you are working in, find copied content, paste it back
at the original input position, and continue working without an extra click.

The macOS target includes rich clipboard history, search, previews and editing,
Pinboards, sequential pasting, privacy controls, system integrations, sync,
sharing, intelligent suggestions, and MCP access. Delivery will be staged;
these capabilities are planned, not implemented or verified. The current scope
is confirmed as full macOS parity, including sync between Macs. iPhone and iPad
clients are outside this scope and may be planned separately later.

## Design documents

- [Technical specification · 技术规格](docs/TECHNICAL_SPEC.zh-CN.md)
- [Product flows and acceptance · 产品动线与体验验收](docs/PRODUCT_FLOWS.zh-CN.md)

Both documents are review drafts. They distinguish documented Paste behavior,
ClipShelf proposals, and details that require observation in the actual app.

## Proposed implementation

The current proposal is a native macOS application using Swift and AppKit for
the main panel, SwiftUI for settings, and SQLite for local storage. The technical
specification records the remaining decisions and validation work.

The initial Tauri / React / Rust scaffold remains in this repository as an early
starting point. It is not a working product or the approved implementation of
the proposed native architecture.

## License

[MIT](LICENSE). ClipShelf is intended to provide free source code and complete
application downloads. It is an independent project and is not affiliated with
Paste.
