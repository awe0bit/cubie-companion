import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('change_scope', Path(__file__).resolve().parents[2] / 'tools/change_scope.py')
scope = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scope)


class ChangeScopeTests(unittest.TestCase):
    def test_page_only_goes_to_ota_without_native_or_docker(self):
        result = scope.classify(['runtime/src/App.tsx', 'runtime/src/DeveloperTools.tsx'])
        self.assertEqual(result, dict(native=False, server=False, runtime=True, ota=True))

    def test_native_changes_require_binary_but_not_server_image(self):
        result = scope.classify(['ios/Cubie/CubieApp.swift', 'runtime/src/DeveloperTools.tsx'])
        self.assertTrue(result['native'])
        self.assertFalse(result['server'])
        self.assertFalse(result['ota'])

    def test_dependencies_and_runtime_must_never_slip_into_ota(self):
        for path in scope.NATIVE_FILES:
            self.assertTrue(scope.classify([path])['native'], path)
            self.assertFalse(scope.classify([path])['ota'], path)

    def test_server_changes_and_mixed_api_ui_require_explicit_release(self):
        result = scope.classify(['backend/server.py', 'runtime/src/App.tsx'])
        self.assertTrue(result['server'])
        self.assertFalse(result['native'])
        self.assertFalse(result['ota'])

    def test_tests_docs_and_ci_do_not_generate_installers(self):
        self.assertEqual(scope.classify(['docs/IOS_OTA.md', 'backend/tests/test_brand.py', '.github/workflows/build-ios.yml']),
                         dict(native=False, server=False, runtime=False, ota=False))
        self.assertEqual(scope.classify(['runtime/tests/lifecycle.test.cjs']),
                         dict(native=False, server=False, runtime=True, ota=False))

    def test_unknown_diff_fails_closed_and_manual_build_still_builds_native(self):
        self.assertEqual(scope.classify([], unknown=True), dict(native=True, server=True, runtime=True, ota=False))
        self.assertTrue(scope.classify([], manual=True)['native'])


if __name__ == '__main__': unittest.main()
