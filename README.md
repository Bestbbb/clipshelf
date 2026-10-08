# ClipShelf

A quiet home for everything you copy. An open-source, local-first clipboard
manager for macOS, Windows, and Linux, inspired by the workflow of Paste.

**Status: under active development.** This initial commit contains the project
scaffold. The first working desktop build is being implemented; platform support
is a target, not a claim of completed testing.

## First version

- Text, link, color, code, and image clipboard history
- Search, favorites, and custom collections
- Global keyboard shortcut and system tray
- Pause recording and manage local retention
- Local SQLite storage, without accounts or cloud uploads

## Stack

Tauri 2 · Rust · React · TypeScript · Vite · SQLite

## Development

Install Node.js 22+, Rust 1.90+, and the
[Tauri prerequisites](https://v2.tauri.app/start/prerequisites/) for your OS.

```sh
npm install
npm run desktop
```

For a browser-only UI preview, run `npm run dev`. A browser preview does not
monitor the system clipboard. Native features require the desktop app.

```sh
npm run build
npm test
cargo test --manifest-path src-tauri/Cargo.toml
npm run tauri build
```

## License

[MIT](LICENSE). ClipShelf is an independent project and is not affiliated with Paste.
