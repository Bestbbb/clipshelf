import importlib.util
import json
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("trace_summary", Path(__file__).resolve().parents[1] / "summarize-trace.py")
trace = importlib.util.module_from_spec(spec)
spec.loader.exec_module(trace)


class TraceSummaryTests(unittest.TestCase):
    def report(self, *events):
        return trace.summarize(json.dumps(event) for event in events)

    def test_interleaved_old_attempt_completion_keeps_its_original_invocation(self):
        report = self.report(
            dict(event="hotkey_received", timestamp=1, shortcut="activation"),
            dict(event="invocation", timestamp=1.01),
            dict(event="panel_shown", timestamp=1.05),
            dict(event="paste_prepared", timestamp=1.1, attemptID="old", bundleID="synthetic.editor", strictness="strict"),
            dict(event="reopen", timestamp=2), dict(event="invocation", timestamp=2.01),
            dict(event="paste_prepared", timestamp=2.02, attemptID="new", bundleID="synthetic.browser", strictness="compatible"),
            dict(event="paste_completed", timestamp=2.03, attemptID="old", state="cancelled", failure="changed_foreground", elapsedMS=930),
            dict(event="paste_dispatch", timestamp=2.1, attemptID="new", method="keyboard"),
            dict(event="paste_completed", timestamp=2.11, attemptID="new", state="dispatched", elapsedMS=90))
        rows = [line for line in report.splitlines() if line.startswith("| 1970")]
        self.assertEqual(len(rows), 2)
        self.assertIn("hotkey:activation | synthetic.editor | 40.0 | 930.0 | strict | cancelled", rows[0])
        self.assertIn("reopen | synthetic.browser", rows[1])
        self.assertIn("keyboard", rows[1])
        self.assertIn("not confirmed insertion", report)

    def test_legacy_traces_and_incomplete_invocations_are_retained(self):
        report = self.report(dict(event="invocation", timestamp=1),
            dict(event="target_captured", timestamp=1.1, bundleID="synthetic.editor"),
            dict(event="ax_timeout", timestamp=1.2),
            dict(event="paste_prepared", timestamp=1.3),
            dict(event="paste_completed", timestamp=1.4, state="copied_only", failure="deadline"),
            dict(event="invocation", timestamp=2))
        self.assertIn("100.0", report)
        self.assertIn("copied_only | deadline", report)
        self.assertIn("no paste attempt", report)

    def test_native_warnings_invalid_json_and_sensitive_unknown_fields_are_not_emitted(self):
        report = trace.summarize(["native stderr warning", "[]", '{"event": "invocation", "timestamp": NaN}',
            json.dumps(dict(event="invocation", timestamp=1, clipboardText="NEVER_EXPORT_THIS")),
            json.dumps(dict(event="target_captured", timestamp=2, bundleID="synthetic|app\nline"))])
        self.assertIn("Ignored non-trace or malformed lines: 3", report)
        self.assertNotIn("NEVER_EXPORT_THIS", report)
        self.assertIn("synthetic\\|app line", report)


if __name__ == "__main__":
    unittest.main()
