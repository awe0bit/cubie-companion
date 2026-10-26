"""Runtime isolation and finite boot checks, without needing a local Mac."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import call, patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('simulator_selector', ROOT/'tools/select_simulator.py')
SELECTOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SELECTOR)
DEVICES = {'devices': {
    'com.apple.CoreSimulator.SimRuntime.iOS-26-2': [
        {'name': 'iPhone 17 Pro', 'udid': 'modern-device', 'state': 'Shutdown'}],
    'com.apple.CoreSimulator.SimRuntime.iOS-18-6': [
        {'name': 'iPhone 16 Pro', 'udid': 'legacy-device', 'state': 'Shutdown'}]
}}


class SimulatorTests(unittest.TestCase):
    def invoke(self, arguments, expected, failure=None):
        with tempfile.TemporaryDirectory() as folder:
            environment = Path(folder)/'ci-environment'
            with patch.dict(os.environ, {'GITHUB_ENV': str(environment)}, clear=True), \
                 patch('sys.argv', ['select_simulator.py'] + arguments), \
                 patch.object(SELECTOR.subprocess, 'check_output', return_value=json.dumps(DEVICES).encode()), \
                 patch.object(SELECTOR.subprocess, 'run', side_effect=failure) as runner, \
                 contextlib.redirect_stdout(io.StringIO()):
                if failure:
                    with self.assertRaises(subprocess.TimeoutExpired):
                        SELECTOR.main()
                else:
                    SELECTOR.main()
            self.assertIn('TEST_DEVICE_ID='+expected, environment.read_text())
            return runner

    def test_modern_and_legacy_are_selected_explicitly(self):
        self.invoke([], 'modern-device').assert_not_called()
        self.invoke(['--legacy'], 'legacy-device').assert_not_called()

    def test_prepared_runtime_has_bounded_boot(self):
        runner = self.invoke(['--legacy', '--prepare'], 'legacy-device')
        self.assertEqual(runner.call_args_list, [
            call(['xcrun', 'simctl', 'boot', 'legacy-device'], check=True, timeout=45),
            call(['xcrun', 'simctl', 'bootstatus', 'legacy-device', '-b'], check=True, timeout=270)
        ])

    def test_stalled_boot_fails_instead_of_starting_tests(self):
        self.invoke(['--prepare'], 'modern-device', subprocess.TimeoutExpired('simctl', 45))


if __name__ == '__main__':
    unittest.main()
