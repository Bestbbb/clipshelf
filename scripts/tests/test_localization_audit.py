import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "localization-audit.py"
SPEC = importlib.util.spec_from_file_location("clipshelf_localization_audit", SCRIPT)
AUDIT = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = AUDIT
SPEC.loader.exec_module(AUDIT)


class SwiftScannerTests(unittest.TestCase):
    def scan(self, source):
        scanner = AUDIT.SwiftScanner(source)
        entries = scanner.run()
        self.assertEqual(scanner.call_errors, [])
        return entries

    def test_comments_are_ignored_and_nested_comments_are_balanced(self):
        source = '''// L10n.text("中文假文案")
        /* nested /* "中文" */ L10n.text("隐藏") */
        let value = L10n /* comment */ . text ( /* comment */ "保存" /* comment */ )
        '''
        entries = self.scan(source)
        self.assertEqual([entry.key for entry in entries], ["保存"])
        self.assertTrue(entries[0].wrapped)

    def test_nested_interpolation_calls_and_parentheses_are_independent(self):
        source = r'''L10n.text("结果 \(f(1, (2 + 3), L10n.text("内部"))) / \(yes ? "未包装" : "")")'''
        entries = self.scan(source)
        self.assertEqual([(entry.key, entry.wrapped) for entry in entries], [
            ("结果 {0} / {1}", True), ("内部", True), ("未包装", False), ("", False),
        ])

    def test_escaped_quotes_unicode_backslash_and_literal_braces(self):
        source = r'''L10n.text("\u{4E2D}\"%\n{literal} \\ \(value)")'''
        entry = self.scan(source)[0]
        self.assertEqual(entry.key, '中"%\n{{literal}} \\ {0}')
        self.assertTrue(entry.has_han)
        self.assertEqual(entry.interpolation_count, 1)

    def test_raw_string_only_interprets_escapes_with_matching_hashes(self):
        source = r'''L10n.text(#"原样 \n；换行 \#n；参数 \#(number)"#)'''
        entry = self.scan(source)[0]
        self.assertEqual(entry.key, "原样 \\n；换行 \n；参数 {0}")
        source = r'''L10n.text(##"原样 \#n 和 "#；参数 \##(number)"##)'''
        entry = self.scan(source)[0]
        self.assertEqual(entry.key, '原样 \\#n 和 "#；参数 {0}')

    def test_multiline_indentation_and_interpolation(self):
        source = 'L10n.text("""\n    第一行\n      {括号} \\(number)\n    末尾\n    """)'
        entry = self.scan(source)[0]
        self.assertEqual(entry.key, '第一行\n  {{括号}} {0}\n末尾')
        self.assertEqual(entry.line, 1)

    def test_multiline_escaped_newline_and_raw_multiline(self):
        source = 'L10n.text("""\n    续行\\\n    结尾\n    """)'
        self.assertEqual(self.scan(source)[0].key, '续行结尾')
        raw = 'L10n.text(#"""\n    原样\\n \\#(value)\n    """#)'
        self.assertEqual(self.scan(raw)[0].key, '原样\\n {0}')

    def test_unicode_parameter_expressions_do_not_become_literal_content(self):
        entry = self.scan(r'''L10n.text("\(中文变量)")''')[0]
        self.assertFalse(entry.has_han)
        self.assertEqual(entry.key, '{0}')

    def test_static_appintent_interpolation_is_preserved_without_wrapper(self):
        entry = self.scan(r'''Summary("保存 \(\.$text) 到 ClipShelf")''')[0]
        self.assertFalse(entry.wrapped)
        self.assertEqual(entry.key, '保存 {0} 到 ClipShelf')
        self.assertEqual(entry.literal, r'''"保存 \(\.$text) 到 ClipShelf"''')

    def test_invalid_or_unterminated_lexical_input_fails_closed(self):
        values = ['/* unfinished', '"unfinished', '"newline\nin single string"',
                  r'''"\u{D800}"''', r'''"\u{110000}"''', r'''"\u{badg}"''', r'''"\q"''',
                  r'''"value \(unclosed"''', '"""same line"""',
                  '"""\n  not indented enough\n    """']
        for value in values:
            with self.subTest(value=value), self.assertRaises(AUDIT.AuditError):
                AUDIT.SwiftScanner(value).run()

    def test_nonliteral_or_concatenated_calls_are_reported(self):
        for source in ['L10n.text(variable)', 'L10n.text("中文" + suffix)', 'L10n.text(makeMessage())']:
            scanner = AUDIT.SwiftScanner(source)
            scanner.run()
            self.assertEqual(len(scanner.call_errors), 1, source)


class CoverageTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="clipshelf-localization-audit-")
        self.root = Path(self.temporary.name)
        self.source = self.root / 'native/Sources/App/Controller.swift'
        self.source.parent.mkdir(parents=True)
        (self.root / 'scripts').mkdir()
        (self.root / AUDIT.CATALOG_DIRECTORY).mkdir(parents=True)
        self.source.write_text('let title = L10n.text("保存")', encoding='utf-8')
        self.exceptions([])
        self.catalogs({'保存': 'Save'})

    def tearDown(self):
        self.temporary.cleanup()

    def exceptions(self, entries):
        (self.root / AUDIT.EXCEPTION_FILE).write_text(json.dumps(entries, ensure_ascii=False), encoding='utf-8')

    def catalogs(self, values):
        for language in AUDIT.LANGUAGES:
            self.catalog(language, values)

    def catalog(self, language, values):
        path = self.root / AUDIT.CATALOG_DIRECTORY / ('catalog-' + language + '.json')
        path.write_text(json.dumps(values, ensure_ascii=False), encoding='utf-8')
        return path

    def kinds(self):
        return {error['kind'] for error in AUDIT.audit(self.root)['errors']}

    def test_complete_coverage_and_unused_keys_are_informational(self):
        self.catalogs({'保存': 'Save', '额外': 'Extra'})
        result = AUDIT.audit(self.root)
        self.assertTrue(result['ok'])
        self.assertEqual(result['source_key_count'], 1)
        self.assertEqual(result['unused_catalog_keys'], ['额外'])

    def test_missing_translation_and_key_set_mismatch_are_errors(self):
        self.catalog('zh-Hant', {})
        self.assertEqual(self.kinds(), {'missing_key', 'catalog_key_set_mismatch'})

    def test_unwrapped_han_including_unicode_escape_is_not_silently_skipped(self):
        self.source.write_text(r'''let one = "界面"; let two = "\u{4e2d}"''', encoding='utf-8')
        result = AUDIT.audit(self.root)
        self.assertEqual([error['kind'] for error in result['errors']], ['unwrapped_han', 'unwrapped_han'])

    def test_exception_matches_exact_file_and_literal_without_line_numbers(self):
        self.source.write_text('let data = "旧数据"', encoding='utf-8')
        self.exceptions([{'file': self.source.relative_to(self.root).as_posix(), 'literal': '"旧数据"', 'reason': 'Persisted content identity; keep original bytes'}])
        self.assertTrue(AUDIT.audit(self.root)['ok'])
        self.source.write_text('\n\n\nlet data = "旧数据"', encoding='utf-8')
        self.assertTrue(AUDIT.audit(self.root)['ok'])
        self.source.write_text('let data = "新界面"', encoding='utf-8')
        self.assertEqual(self.kinds(), {'unwrapped_han', 'stale_exception'})

    def test_exception_does_not_exempt_another_file_or_nested_literal(self):
        self.source.write_text(r'''let data = "旧数据 \(flag ? "新界面" : "")"''', encoding='utf-8')
        self.exceptions([{'file': self.source.relative_to(self.root).as_posix(), 'literal': r'''"旧数据 \(flag ? "新界面" : "")"''', 'reason': 'Reviewed fixture'}])
        self.assertEqual(self.kinds(), {'unwrapped_han'})
        other = self.source.parent / 'Other.swift'
        other.write_text(r'''let data = "旧数据 \(flag ? "新界面" : "")"''', encoding='utf-8')
        errors = AUDIT.audit(self.root)['errors']
        self.assertEqual(len([error for error in errors if error['kind'] == 'unwrapped_han']), 3)

    def test_native_language_self_names_are_explicit_exceptions(self):
        self.source.write_text('let names = ["English", "简体中文", "繁體中文"]', encoding='utf-8')
        self.exceptions([{'file': self.source.relative_to(self.root).as_posix(), 'literal': json.dumps(value, ensure_ascii=False), 'reason': 'Native language self-name'}
                         for value in ['English', '简体中文', '繁體中文']])
        result = AUDIT.audit(self.root)
        self.assertTrue(result['ok'])
        self.assertEqual(result['matched_exception_count'], 3)

    def test_malformed_exception_manifest_is_an_error(self):
        cases = [{'file': 'native/Sources/App/Controller.swift', 'literal': '"保存"', 'reason': ''},
                 {'file': '../elsewhere.swift', 'literal': '"保存"', 'reason': 'No path traversal'},
                 {'file': 'native/Sources/App/Controller.swift', 'literal': '"保存"', 'reason': 'No line matching', 'line': 1}]
        for entry in cases:
            self.exceptions([entry])
            self.assertIn('invalid_exceptions', self.kinds())
        valid = {'file': 'native/Sources/App/Controller.swift', 'literal': '"保存"', 'reason': 'Fixture'}
        self.exceptions([valid, valid])
        self.assertIn('invalid_exceptions', self.kinds())

    def test_catalog_rejects_duplicate_json_keys_and_nonstring_values(self):
        path = self.catalog('en', {'保存': 'Save'})
        path.write_text('{"保存":"One", "保存":"Two"}', encoding='utf-8')
        self.assertIn('invalid_catalog', self.kinds())
        self.catalog('en', {'保存': 42})
        self.assertIn('invalid_catalog', self.kinds())

    def test_catalog_placeholders_allow_reordering_repetition_and_escaped_braces(self):
        self.source.write_text(r'''L10n.text("保存 \(one) 到 \(two) {字面} %")''', encoding='utf-8')
        self.catalogs({'保存 {0} 到 {1} {{字面}} %': '{1}: {0}, again {0} {{literal}} %'})
        self.assertTrue(AUDIT.audit(self.root)['ok'])
        for bad in ['Only {1}', '{0} {1} {2}', '{00} {1}', '{0} {1} {', '{0} {1} }']:
            self.catalog('en', {'保存 {0} 到 {1} {{字面}} %': bad})
            self.assertIn('invalid_catalog_template', self.kinds(), bad)

    def test_source_key_placeholder_order_must_match_runtime(self):
        for key in ['{1}', '{0} {0}', '{1} {0}', '{999999999999999999999999}']:
            self.catalog('en', {key: key, '保存': 'Save'})
            self.assertIn('invalid_catalog_template', self.kinds(), key)

    def test_cli_reports_json_and_does_not_write_any_file(self):
        def digests():
            return {path.relative_to(self.root).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
                    for path in self.root.rglob('*') if path.is_file()}
        before = digests()
        process = subprocess.run([sys.executable, str(SCRIPT), '--root', str(self.root), '--json'], capture_output=True, text=True)
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertTrue(json.loads(process.stdout)['ok'])
        self.assertEqual(before, digests())
        self.source.write_text('let title = "遗漏文案"', encoding='utf-8')
        failed = subprocess.run([sys.executable, str(SCRIPT), '--root', str(self.root)], capture_output=True, text=True)
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn('unwrapped_han', failed.stdout)
        forbidden = subprocess.run([sys.executable, str(SCRIPT), '--root', str(self.root), '--write'], capture_output=True, text=True)
        self.assertNotEqual(forbidden.returncode, 0)
        self.assertIn('unrecognized arguments', forbidden.stderr)

    def test_parse_error_is_reported_instead_of_partial_success(self):
        self.source.write_text('L10n.text("unclosed)', encoding='utf-8')
        self.assertIn('source_parse_error', self.kinds())


if __name__ == '__main__':
    unittest.main()
