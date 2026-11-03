#!/usr/bin/env python3
"""Run the actual version-check block with a synthetic executable, never Xcode/CI."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("macos_simulator_test.sh").read_text()
START = SCRIPT.index('onbudget_xcode_version=')
END = SCRIPT.index('mkdir -p ios/CloudResults', START)
VERSION_CHECK = SCRIPT[START:END]


class XcodeVersionCheckTests(unittest.TestCase):
    def run_check(self, first_line="Xcode 16.4", exit_code=0, large=False):
        with tempfile.TemporaryDirectory(prefix="onbudget-version-") as directory:
            root = Path(directory)
            producer = root / "xcodebuild"
            # Multiple flushed writes exceed pipe capacity. An early-closing consumer
            # causes a real BrokenPipeError; full capture must drain through the end.
            producer.write_text(
                f"#!{sys.executable}\n"
                "import pathlib, sys\n"
                "pathlib.Path(__file__).with_name('calls').open('a').write('call\\n')\n"
                "assert sys.argv[1:] == ['-version']\n"
                f"print({first_line!r}, flush=True)\n"
                + ("for _ in range(256): print('x' * 4096, flush=True)\n" if large else "")
                + "print('Build version SYNTHETIC-END', flush=True)\n"
                + f"sys.exit({exit_code})\n"
            )
            producer.chmod(0o700)
            environment = dict(os.environ, PATH=directory + os.pathsep + os.environ.get("PATH", ""))
            result = subprocess.run(
                ["bash", "-c", "set -euo pipefail\n" + VERSION_CHECK],
                env=environment, capture_output=True, text=True, timeout=15,
            )
            calls = (root / "calls").read_text().splitlines()
            self.assertEqual(calls, ["call"], "Xcode must be invoked exactly once")
            return result

    def test_complete_large_output_is_drained_before_version_check(self):
        result = self.run_check(large=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertGreater(len(result.stdout), 1_000_000)
        self.assertTrue(result.stdout.endswith("Build version SYNTHETIC-END\n"))
        self.assertNotIn("BrokenPipe", result.stderr)

    def test_wrong_version_rejected(self):
        result = self.run_check(first_line="Xcode 16.3")
        self.assertEqual(result.returncode, 1)
        self.assertIn("expected Xcode 16.4", result.stderr)

    def test_version_must_match_first_line_exactly(self):
        for value in ["Xcode 16.40", "Xcode 16.4 beta", " Xcode 16.4", ""]:
            with self.subTest(value=value):
                self.assertEqual(self.run_check(first_line=value).returncode, 1)

    def test_producer_error_is_not_hidden_by_valid_version(self):
        result = self.run_check(exit_code=23)
        self.assertEqual(result.returncode, 23)
        self.assertEqual(result.stdout, "", "Do not accept/print a failed version capture")


if __name__ == "__main__":
    unittest.main()
