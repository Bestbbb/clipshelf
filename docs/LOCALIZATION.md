# Interface localization

ClipShelf currently provides English, Simplified Chinese and Traditional Chinese,
plus a Follow System choice. This covers the existing application controls,
accessibility labels and application-owned status/error messages, with separate
native tables for Services, App Intents and the Share Extension. It does not imply
complete Paste language parity or completed visual acceptance.

The [Paste Mac App Store listing](https://apps.apple.com/us/app/paste-limitless-clipboard/id967805235?platform=mac)
declares 16 languages (checked 2026-10-10). Czech, Danish, Dutch, French, German,
Hebrew, Italian, Japanese, Korean, Polish, Portuguese, Russian and Spanish remain
in the full macOS scope. Hebrew also requires right-to-left layout and interaction
acceptance; the current implementation has no RTL layout support.

## User flow and data boundaries

Open **Language…** from either application menu or the welcome dialog. Language
names retain their native spelling. Saving takes effect on the next launch; it
does not restart the app or rebuild an active editor. The language window preserves
unsaved drafts, and isolated demo/validation profiles cannot save this preference.

The choice and app-scoped `AppleLanguages` override are saved in the current
profile. Follow System removes only that override. A configured, signed App Group
receives the same preference for the Share Extension. No global macOS preference
is written, and merely declaring an App Group in a plist does not authorize access.
Extension host processes and system-indexed Shortcut metadata may require their
own restart/refresh; actual signed integration remains to be checked.

Existing clipboard text, titles, pinboard names, source names and persisted failure
details are data and are not rewritten. New generated labels use the language at
creation. A few legacy image/PDF summary markers retain their stored bytes because
editing and content recognition depend on them; these are explicit source-audit
exceptions. Native/system errors and third-party interfaces can use their own
language. The feature does not promise every visible byte is translated.

## Runtime contract

`ClipShelfLocalization` is a Foundation-only Swift package target shared by the
main app, core and Share Inbox code. Configure `L10n` before creating app controls.
Each process takes one immutable language snapshot. Background App Intents
configure on authorized-store access; the Share Extension supplies its own bundle.

Use `L10n.text("Message \(argument)")` for owned interface text. A
`LocalizedMessage` separates literal segments from arguments, generates sequential
`{0}` keys, and escapes literal braces as `{{` and `}}`. Translations can reorder or
repeat arguments but must retain exactly the same argument set. Rendering never
parses argument content as another template, including braces and percent signs.
Avoid translating protocol values, identifiers, paths or user content. Do not use
localized display strings as new persistent identifiers.

JSON catalogs under `native/Sources/ClipShelfLocalization/Resources` share the same
keys. Missing or invalid translations fall back to English and then the original
message; diagnostics contain codes, not clipboard data. An unconfigured runtime
uses source text without reading preferences or resources, keeping existing tests
isolated. Tests use independent runtime instances rather than reconfiguring the
global singleton. Dates, relative times and file sizes use the interface locale.

App Intents declarations must remain compile-time localized resources. Update the
corresponding `Localizable.strings` and `AppShortcuts.strings`, and keep
`ServicesMenu.strings` aligned with Info.plist. Their keys are checked against the
extracted App Intents metadata, not a duplicate hand-maintained action list alone.

## Delivery and checks

Both `.app` and `.appex` carry `ClipShelf_ClipShelfLocalization.bundle` inside their
own Resources directory. SwiftPM CLI packaging copies it explicitly; Xcode embeds
the package resources. A packaged host never falls back to an absolute development
build path. Bundle/catalog symlinks escaping the host are rejected.

```sh
python3 scripts/localization-audit.py
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/tests -v
swift test --disable-keychain --disable-netrc --package-path native
./scripts/build-macos.sh
python3 scripts/verify-localization.py --app build/ClipShelf.app --runtime
# For an Xcode app containing the extension:
python3 scripts/verify-localization.py --app /path/to/ClipShelf.app --share-extension --runtime
```

The source audit rejects unreviewed Chinese literals, missing keys, malformed
templates and mismatched language catalogs. `scripts/localization-exceptions.json`
records exact file/literal/reason exceptions for synthetic data, static system
metadata, native language names and legacy stored markers. It is read-only; it
does not automatically rewrite source or user content. It cannot discover every
unmarked English sentence, so code review still checks new UI strings.

The delivery verifier checks both hosts, identical catalogs, system tables and
placeholders. `--runtime` copies the app to a temporary unrelated directory and
runs each language in a separate process through `--localization-diagnostics`.
This early CLI path prints resource diagnostics and exits before creating
NSApplication, reading profile preferences or starting capture/background services.
The formal release pipeline runs this gate before notarization. It is a packaging
test, not evidence of a real Share Extension launch or a complete translated UI.

English layout regressions cover Stack actions, date filters and the full upload
consent description using unshown native controls. Real first-launch flows,
screen-reader navigation, all windows at minimum size, cross-app focus behavior,
system language selection and signed extension/Shortcuts behavior remain manual
acceptance tasks. Traditional Chinese has automated script conversion plus
terminology/meaning review; full native-speaker and rendered-screen review remains.
