#!/usr/bin/env python3
"""Claude settings ownership comparison, runnable without pytest."""

import json
import os
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib", "python"))

from ihar.render.claude_compare import compare_objects  # noqa: E402


class ClaudeCompareTests(unittest.TestCase):
    def test_equal_settings_have_no_drift(self):
        settings = {"hooks": {"PreToolUse": []}, "sandbox": {"enabled": True}}
        self.assertIsNone(compare_objects(settings, settings))

    def test_added_or_changed_top_level_theme_is_vendor_owned(self):
        desired = {"hooks": {"PreToolUse": []}}
        active = {"hooks": {"PreToolUse": []}, "theme": "dark"}
        self.assertIsNone(compare_objects(desired, active))
        active["theme"] = "light"
        self.assertIsNone(compare_objects(desired, active))
        self.assertEqual(active["theme"], "light")
        self.assertNotIn("theme", desired)

    def test_theme_does_not_hide_hook_tampering(self):
        desired = {"hooks": {"PreToolUse": []}}
        active = {"hooks": {"PreToolUse": ["changed"]}, "theme": "dark"}
        self.assertEqual(compare_objects(desired, active), "hooks.PreToolUse")

    def test_sandbox_change_reports_field_without_value(self):
        desired = {"sandbox": {"filesystem": "read-only"}}
        active = {"sandbox": {"filesystem": "secret-value"}}
        result = compare_objects(desired, active)
        self.assertEqual(result, "sandbox.filesystem")
        self.assertNotIn("secret-value", result)

    def test_gateway_change_reports_field_without_value(self):
        desired = {"_iharGateway": "https://expected.example"}
        active = {"_iharGateway": "https://secret-value.example"}
        result = compare_objects(desired, active)
        self.assertEqual(result, "_iharGateway")
        self.assertNotIn("secret-value", result)

    def test_unknown_extra_key_is_drift(self):
        self.assertEqual(compare_objects({}, {"unknown": "secret-value"}), "unknown")

    def test_non_string_or_nested_theme_is_not_ignored(self):
        self.assertEqual(compare_objects({}, {"theme": {"secret": True}}), "theme")
        self.assertEqual(compare_objects({"hooks": {}}, {"hooks": {"theme": "dark"}}), "hooks.theme")

    def test_managed_list_item_type_change_is_drift(self):
        self.assertEqual(
            compare_objects({"hooks": {"PreToolUse": [1]}}, {"hooks": {"PreToolUse": [True]}}),
            "hooks.PreToolUse",
        )
        self.assertEqual(
            compare_objects({"hooks": {"PreToolUse": [{"timeout": 1}]}},
                            {"hooks": {"PreToolUse": [{"timeout": True}]}}),
            "hooks.PreToolUse",
        )

    def test_cli_compares_files_and_reports_only_path(self):
        with tempfile.TemporaryDirectory() as directory:
            desired = os.path.join(directory, "desired.json")
            active = os.path.join(directory, "active.json")
            with open(desired, "w", encoding="utf-8") as handle:
                json.dump({"hooks": {"PreToolUse": []}}, handle)
            with open(active, "w", encoding="utf-8") as handle:
                json.dump({"hooks": {"PreToolUse": []}, "theme": "dark"}, handle)
            self.assertEqual(self.run_cli(desired, active).returncode, 0)
            with open(active, "w", encoding="utf-8") as handle:
                json.dump({"hooks": {"PreToolUse": ["secret-value"]}, "theme": "dark"}, handle)
            result = self.run_cli(desired, active)
            self.assertEqual(result.returncode, 3)
            self.assertEqual(result.stdout, "hooks.PreToolUse\n")
            self.assertNotIn("secret-value", result.stdout + result.stderr)

    def test_malformed_json_fails_closed_without_echoing_payload(self):
        with tempfile.TemporaryDirectory() as directory:
            desired = os.path.join(directory, "desired.json")
            active = os.path.join(directory, "active.json")
            with open(desired, "w", encoding="utf-8") as handle:
                handle.write("{}")
            with open(active, "w", encoding="utf-8") as handle:
                handle.write('{"secret-value":')
            result = self.run_cli(desired, active)
            self.assertEqual(result.returncode, 3)
            self.assertEqual(result.stdout, "$\n")
            self.assertNotIn("secret-value", result.stdout + result.stderr)

    @staticmethod
    def run_cli(desired, active):
        return subprocess.run(
            [sys.executable, "-m", "ihar.render.claude_compare", desired, active],
            capture_output=True,
            text=True,
            env={**os.environ, "PYTHONPATH": os.path.join(os.path.dirname(__file__), "..", "lib", "python")},
            check=False,
        )


if __name__ == "__main__":
    unittest.main()
