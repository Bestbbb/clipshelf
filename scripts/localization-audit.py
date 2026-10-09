#!/usr/bin/env python3
"""Read-only localization coverage check; uses only the Python standard library."""
import argparse
import bisect
import json
import re
from dataclasses import dataclass
from pathlib import Path

HAN = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff\U00020000-\U0003134f]")
LANGUAGES = ("en", "zh-Hans", "zh-Hant")
CATALOG_DIRECTORY = Path("native/Sources/ClipShelfLocalization/Resources")
EXCEPTION_FILE = Path("scripts/localization-exceptions.json")


class AuditError(ValueError):
    pass


@dataclass
class Literal:
    start: int
    end: int
    line: int
    literal: str
    segments: list
    interpolation_count: int
    wrapped: bool = False

    @property
    def key(self):
        output = []
        for index, segment in enumerate(self.segments):
            output.append(segment.replace("{", "{{").replace("}", "}}"))
            if index < self.interpolation_count:
                output.append("{" + str(index) + "}")
        return "".join(output)

    @property
    def has_han(self):
        return bool(HAN.search("".join(self.segments)))


def decode_segment(value, hashes=0, multiline=False):
    """Decode Swift escapes, leaving ordinary backslashes in raw strings alone."""
    prefix = "\\" + "#" * hashes
    result, index = [], 0
    simple = {"n": "\n", "r": "\r", "t": "\t", "0": "\0", '"': '"', "'": "'", "\\": "\\"}
    while index < len(value):
        if not value.startswith(prefix, index):
            result.append(value[index]); index += 1; continue
        index += len(prefix)
        if index >= len(value):
            raise AuditError("unterminated string escape")
        if multiline:
            continuation = re.match(r"[ \t]*\r?\n", value[index:])
            if continuation:
                index += continuation.end(); continue
        if value.startswith("u{", index):
            match = re.match(r"u\{([0-9a-fA-F]{1,8})\}", value[index:])
            if not match:
                raise AuditError("invalid Unicode escape")
            scalar = int(match.group(1), 16)
            if scalar > 0x10FFFF or 0xD800 <= scalar <= 0xDFFF:
                raise AuditError("invalid Unicode scalar")
            result.append(chr(scalar)); index += match.end()
        elif value[index] in simple:
            result.append(simple[value[index]]); index += 1
        else:
            raise AuditError("unsupported string escape: " + prefix + value[index])
    return "".join(result)


def decode_segments(segments, hashes, multiline):
    if multiline:
        # Expressions are not string content. Dedent the literal portions around
        # them together, then decode escapes without changing parameter boundaries.
        if any("\0" in part for part in segments):
            raise AuditError("literal NUL in Swift source")
        body = "\0".join(segments).replace("\r\n", "\n")
        opening = re.match(r"[ \t]*\n", body)
        if not opening:
            raise AuditError("multiline string must start on a new line")
        body = body[opening.end():]
        last_newline = body.rfind("\n")
        indent = body[last_newline + 1:]
        if indent.strip(" \t"):
            raise AuditError("multiline closing delimiter must be on its own line")
        body = body[:last_newline] if last_newline >= 0 else ""
        lines = []
        for line in body.split("\n"):
            if line.startswith(indent):
                lines.append(line[len(indent):])
            elif not line.strip(" \t"):
                lines.append("")
            else:
                raise AuditError("multiline content has less indentation than its closing delimiter")
        segments = "\n".join(lines).split("\0")
    return [decode_segment(value, hashes, multiline) for value in segments]


class SwiftScanner:
    """Lex strings/comments and balanced interpolation; never rewrite Swift."""
    def __init__(self, source):
        self.source = source
        self.size = len(source)
        self.literals = []
        self.call_errors = []
        self.newlines = [-1] + [match.start() for match in re.finditer("\n", source)]

    def line(self, offset):
        return bisect.bisect_left(self.newlines, offset)

    def comment(self, index):
        start = index
        if self.source.startswith("//", index):
            end = self.source.find("\n", index)
            return self.size if end < 0 else end
        depth, index = 1, index + 2
        while index < self.size and depth:
            if self.source.startswith("/*", index): depth += 1; index += 2
            elif self.source.startswith("*/", index): depth -= 1; index += 2
            else: index += 1
        if depth:
            raise AuditError("unterminated comment at line " + str(self.line(start)))
        return index

    def string_start(self, index):
        following = index
        while following < self.size and self.source[following] == "#": following += 1
        if following < self.size and self.source[following] == '"':
            return following - index, 3 if self.source.startswith('"""', following) else 1
        return None

    def string(self, start, hashes, quotes):
        index = start + hashes + quotes
        delimiter, escape = '"' * quotes + "#" * hashes, "\\" + "#" * hashes
        chunk, segments, count = index, [], 0
        while index < self.size:
            if self.source.startswith(escape, index):
                if self.source.startswith(escape + "(", index):
                    segments.append(self.source[chunk:index])
                    index = self.code(index + len(escape) + 1, interpolation=True)
                    count += 1; chunk = index
                else:
                    index += len(escape) + 1
                continue
            if self.source.startswith(delimiter, index):
                segments.append(self.source[chunk:index]); index += len(delimiter)
                literal = Literal(start, index, self.line(start), self.source[start:index],
                                  decode_segments(segments, hashes, quotes == 3), count)
                self.literals.append(literal)
                return index, literal
            if quotes == 1 and self.source[index] in "\r\n":
                raise AuditError("newline in single-line string at line " + str(self.line(start)))
            index += 1
        raise AuditError("unterminated string at line " + str(self.line(start)))

    def check_calls(self, tokens):
        for index in range(len(tokens) - 3):
            if [token[0] for token in tokens[index:index + 4]] != ["L10n", ".", "text", "("]:
                continue
            argument = tokens[index + 4] if index + 4 < len(tokens) else None
            closing = tokens[index + 5] if index + 5 < len(tokens) else None
            if argument and isinstance(argument[0], Literal) and closing and closing[0] == ")":
                argument[0].wrapped = True
            else:
                self.call_errors.append({"line": self.line(tokens[index][1]), "kind": "nonliteral_localization_call",
                                         "message": "L10n.text must receive a single auditable string literal"})

    def code(self, index=0, interpolation=False):
        tokens, depth = [], 1
        while index < self.size:
            if self.source.startswith("//", index) or self.source.startswith("/*", index):
                index = self.comment(index); continue
            character = self.source[index]
            if character.isspace(): index += 1; continue
            quote = self.string_start(index)
            if quote:
                start = index; index, literal = self.string(index, *quote)
                tokens.append((literal, start)); continue
            if interpolation and character == ")":
                depth -= 1
                if depth == 0:
                    self.check_calls(tokens); return index + 1
            if interpolation and character == "(": depth += 1
            if character.isalpha() or character == "_":
                end = index + 1
                while end < self.size and (self.source[end].isalnum() or self.source[end] == "_"): end += 1
                tokens.append((self.source[index:end], index)); index = end
            else:
                tokens.append((character, index)); index += 1
        if interpolation:
            raise AuditError("unterminated interpolation")
        self.check_calls(tokens)
        return index

    def run(self):
        self.code()
        return sorted(self.literals, key=lambda entry: entry.start)


def placeholders(template):
    """Mirror LocalizedMessage's escaped braces and numbered arguments."""
    indices, index = [], 0
    while index < len(template):
        character = template[index]
        if template.startswith("{{", index) or template.startswith("}}", index):
            index += 2; continue
        if character == "{":
            match = re.match(r"\{(0|[1-9][0-9]*)\}", template[index:])
            if not match:
                raise AuditError("malformed placeholder")
            number = int(match.group(1))
            if number > 2**63 - 1:
                raise AuditError("placeholder index exceeds Swift Int")
            indices.append(number); index += match.end()
        elif character == "}":
            raise AuditError("unescaped closing brace")
        else: index += 1
    return indices


def load_json(path):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result: raise AuditError("duplicate JSON key: " + key)
            result[key] = value
        return result
    return json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=unique)


def audit(root, exception_path=None):
    root = Path(root)
    errors, sources, covered, used_exceptions = [], [], set(), set()
    exceptions = {}
    try:
        entries = load_json(exception_path or root / EXCEPTION_FILE)
        if not isinstance(entries, list): raise AuditError("exception manifest must be an array")
        for entry in entries:
            if not isinstance(entry, dict) or set(entry) != {"file", "literal", "reason"}:
                raise AuditError("every exception requires exactly file, literal and reason")
            if any(not isinstance(entry[field], str) or not entry[field].strip() for field in entry):
                raise AuditError("exception fields must be nonempty strings")
            path = Path(entry["file"])
            if path.is_absolute() or ".." in path.parts or not entry["file"].startswith("native/Sources/"):
                raise AuditError("exception file must be a repository-relative native/Sources path")
            identity = (entry["file"], entry["literal"])
            if identity in exceptions: raise AuditError("duplicate exception: " + entry["file"] + " " + entry["literal"])
            exceptions[identity] = entry["reason"]
    except (OSError, ValueError) as error:
        errors.append({"kind": "invalid_exceptions", "message": str(error)})
    files = sorted((root / "native/Sources").rglob("*.swift"))
    if not files: errors.append({"kind": "missing_sources", "message": "No Swift sources found under native/Sources"})
    for path in files:
        relative = path.relative_to(root).as_posix()
        try:
            scanner = SwiftScanner(path.read_text(encoding="utf-8"))
            for entry in scanner.run():
                identity = (relative, entry.literal)
                if entry.wrapped:
                    covered.add(entry.key)
                    sources.append({"file": relative, "line": entry.line, "key": entry.key})
                elif identity in exceptions:
                    used_exceptions.add(identity)
                elif entry.has_han:
                    errors.append({"kind": "unwrapped_han", "file": relative, "line": entry.line, "literal": entry.literal})
            errors += [dict(error, file=relative) for error in scanner.call_errors]
        except (OSError, ValueError) as error:
            errors.append({"kind": "source_parse_error", "file": relative, "message": str(error)})
    for file, literal in sorted(set(exceptions) - used_exceptions):
        errors.append({"kind": "stale_exception", "file": file, "literal": literal})
    catalogs = {}
    for language in LANGUAGES:
        path = root / CATALOG_DIRECTORY / ("catalog-" + language + ".json")
        try:
            values = load_json(path)
            if not isinstance(values, dict) or any(not isinstance(value, str) for value in values.values()):
                raise AuditError("catalog must be a JSON object containing only string values")
            catalogs[language] = values
            for key, value in values.items():
                try:
                    expected, actual = placeholders(key), placeholders(value)
                    if expected != list(range(len(expected))): raise AuditError("source key indices must occur once, in order, starting at zero")
                    if set(expected) != set(actual): raise AuditError("translation placeholder set differs from source")
                except ValueError as error:
                    errors.append({"kind": "invalid_catalog_template", "language": language, "key": key, "message": str(error)})
            for key in sorted(covered - values.keys()):
                errors.append({"kind": "missing_key", "language": language, "key": key})
        except (OSError, ValueError) as error:
            errors.append({"kind": "invalid_catalog", "language": language, "message": str(error)})
    union = set().union(*(set(values) for values in catalogs.values()))
    for language, values in catalogs.items():
        if set(values) != union:
            errors.append({"kind": "catalog_key_set_mismatch", "language": language, "missing": sorted(union - values.keys())})
    return {"ok": not errors, "source_file_count": len(files), "wrapped_literal_count": len(sources),
            "source_key_count": len(covered), "catalog_key_counts": {language: len(values) for language, values in catalogs.items()},
            "reviewed_exception_count": len(exceptions), "matched_exception_count": len(used_exceptions),
            "unused_catalog_keys": sorted(union - covered), "errors": errors}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--exceptions", type=Path, help="Explicit exception manifest instead of the repository default")
    parser.add_argument("--json", action="store_true", help="Print a machine-readable report to stdout; never write files")
    args = parser.parse_args(argv)
    result = audit(args.root, args.exceptions)
    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        print("Localization audit: " + ("PASS" if result["ok"] else "FAIL"))
        print("{source_file_count} Swift files; {wrapped_literal_count} wrapped literals; {source_key_count} unique keys; "
              "{matched_exception_count}/{reviewed_exception_count} explicit exceptions matched.".format(**result))
        print("Catalogs: " + ", ".join(language + "=" + str(count) for language, count in result["catalog_key_counts"].items()))
        print("Unused catalog keys (informational): " + str(len(result["unused_catalog_keys"])))
        for error in result["errors"]: print(json.dumps(error, ensure_ascii=False))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
