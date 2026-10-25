import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("source_privacy", Path(__file__).resolve().parents[2] / "tools/privacy_check.py")
privacy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(privacy)


class PrivacyTests(unittest.TestCase):
    def test_private_files_are_rejected_even_if_force_added(self):
        for name in (".env", "keys/device.pem", "device.credentials.json", "verification-private.json", "cloud-build-private.json"):
            self.assertIn("private_file_type", privacy.violations(name, b"{}"))

    def test_runtime_values_are_not_printed_in_findings(self):
        value = b"synthetic-private-value-123456789"
        result = privacy.violations("sample.py", value, [value])
        self.assertEqual(result, ["private_exact_match"])
        self.assertNotIn(value.decode(), str(result))

    def test_personal_paths_and_networks_blocked(self):
        path = "/" + "/".join(("home", "private-user", "config.json"))
        self.assertIn("personal_home_path", privacy.violations("sample.md", path.encode()))
        address = ".".join(("10", "23", "45", "67"))
        self.assertIn("non_example_network_address", privacy.violations("sample.md", address.encode()))

    def test_safe_examples_and_loopback_are_accepted(self):
        self.assertEqual(privacy.violations("sample.md", b"https://board.example.com 127.0.0.1 192.0.2.1"), [])

    def test_private_domain_blocked_without_echoing_it(self):
        value = ("https://" + "private-user-service.invalid").encode()
        self.assertIn("non_example_service_domain", privacy.violations("sample.md", value))


if __name__ == "__main__": unittest.main()
