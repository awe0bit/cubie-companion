import base64
import io
import json
from pathlib import Path
import secrets
import sys
import tempfile
import threading
import time
import unittest
from concurrent.futures import ThreadPoolExecutor
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from pairing import PairingStore, PairingError, digest, endpoint
from pairing_web import PairingWeb
from host_bridge import FileCollector, export_once
from server import App, APIError
from test_server import config, call, FakeCollector


class PairingTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.now = time.time()
        self.store = PairingStore(Path(self.folder.name) / "pair.sqlite3", clock=lambda: self.now)
        self.grant = self.store.create("https://board.example.com")
        self.token = secrets.token_urlsafe(32)
        self.hash = digest(self.token)

    def tearDown(self):
        self.store.db.close()
        self.folder.cleanup()

    def request(self): return self.store.request(self.grant["ticket"], self.hash, "Test iPhone")

    def test_requires_browser_approval_and_codes_match(self):
        pending = self.request()
        self.assertIsNone(self.store.role(self.hash))
        self.assertEqual(self.store.offer(self.grant["manager"])["verificationCode"], pending["verificationCode"])
        self.assertEqual(len(pending["verificationCode"]), 6)
        self.store.decide(self.grant["manager"], True)
        self.assertEqual(self.store.role(self.hash), "viewer")
        self.assertEqual(self.store.result(self.token)["state"], "approved")

    def test_claim_ticket_cannot_approve(self):
        self.request()
        with self.assertRaises(PairingError): self.store.decide(self.grant["ticket"], True)
        self.assertIsNone(self.store.role(self.hash))

    def test_manager_cannot_claim(self):
        with self.assertRaises(PairingError): self.store.request(self.grant["manager"], self.hash, "Phone")

    def test_qr_single_use_concurrent_claim(self):
        def register(_):
            try: self.store.request(self.grant["ticket"], digest(secrets.token_urlsafe(32)), "Phone"); return 200
            except PairingError as error: return error.status
        with ThreadPoolExecutor(max_workers=8) as executor: codes = list(executor.map(register, range(8)))
        self.assertEqual(codes.count(200), 1)
        self.assertEqual(codes.count(409), 7)

    def test_expired_cannot_claim_or_approve(self):
        self.now += 301
        with self.assertRaises(PairingError) as caught: self.request()
        self.assertEqual(caught.exception.status, 410)

    def test_pending_expires(self):
        self.request(); self.now += 301
        self.assertEqual(self.store.result(self.token)["state"], "expired")
        with self.assertRaises(PairingError): self.store.decide(self.grant["manager"], True)
        self.assertIsNone(self.store.role(self.hash))

    def test_rejection_never_issues_credential(self):
        self.request(); self.store.decide(self.grant["manager"], False)
        self.assertEqual(self.store.result(self.token)["state"], "rejected")
        self.assertIsNone(self.store.role(self.hash))

    def test_revoke_immediate_and_other_device_preserved(self):
        self.request(); self.store.decide(self.grant["manager"], True)
        ident = self.store.result(self.token)["deviceId"]
        self.assertTrue(self.store.revoke(ident))
        self.assertIsNone(self.store.role(self.hash))
        self.assertEqual(self.store.result(self.token)["state"], "revoked")

    def test_secrets_not_persisted_or_listed(self):
        self.request(); self.store.decide(self.grant["manager"], True)
        stored = (Path(self.folder.name) / "pair.sqlite3").read_bytes()
        for secret in (self.token, self.grant["ticket"].split(".")[1], self.grant["manager"].split(".")[1]):
            self.assertNotIn(secret.encode(), stored)
        self.assertNotIn(self.hash, json.dumps(self.store.devices()))

    def test_restart_retains_device_and_revocation(self):
        self.request(); self.store.decide(self.grant["manager"], True)
        self.store.db.close()
        self.store = PairingStore(Path(self.folder.name) / "pair.sqlite3")
        self.assertEqual(self.store.role(self.hash), "viewer")
        self.store.revoke(self.store.result(self.token)["deviceId"])
        other = PairingStore(Path(self.folder.name) / "pair.sqlite3")
        try: self.assertIsNone(other.role(self.hash))
        finally: other.db.close()

    def test_fresh_qr_invalidates_old_pending_not_existing_device(self):
        self.request(); self.store.decide(self.grant["manager"], True)
        other = self.store.create("https://other.example.com")
        self.store.create("https://third.example.com")
        with self.assertRaises(PairingError): self.store.offer(other["manager"])
        self.assertEqual(self.store.role(self.hash), "viewer")

    def test_request_validation(self):
        for name, hashed in [("", self.hash), ("a" * 61, self.hash), ("a\nb", self.hash), ("Phone", "bad")]:
            with self.assertRaises(PairingError): self.store.request(self.grant["ticket"], hashed, name)

    def test_bad_credentials_bounded(self):
        for secret in (None, [], "", "x" * 50000, "a" * 24 + "." + "b" * 43):
            with self.assertRaises(PairingError): self.store.offer(secret)

    def test_registration_rate_limit(self):
        for _ in range(30):
            try: self.store.request("invalid", self.hash, "Phone")
            except PairingError: pass
        with self.assertRaises(PairingError) as error: self.request()
        self.assertEqual(error.exception.status, 429)
        self.now += 60
        self.assertEqual(self.request()["state"], "pending")

    def test_approved_token_authorizes_api_and_revoke_denies(self):
        app = App(config(), FakeCollector(), pairing=self.store)
        self.assertEqual(call(app, token=self.token)["code"], 401)
        self.request(); self.store.decide(self.grant["manager"], True)
        self.assertEqual(call(app, token=self.token)["code"], 200)
        self.assertEqual(call(app, "/v1/device/reboot", "POST", self.token, {"confirmation": "REBOOT"})["code"], 403)
        self.store.revoke(self.store.result(self.token)["deviceId"])
        self.assertEqual(call(app, token=self.token)["code"], 401)

    def test_https_origins_only(self):
        self.assertEqual(endpoint("https://BOARD.example.com/"), "https://board.example.com")
        for origin in ("http://example.com", "https://u:p@example.com", "https://example.com:443", "https://example.com/a", "https://example.com?q=a"):
            with self.assertRaises(ValueError): endpoint(origin)

    def web(self, path, data=None, manager=None, method="POST", **extra):
        raw = json.dumps(data).encode() if data is not None else b""
        env = {"PATH_INFO": path, "REQUEST_METHOD": method, "CONTENT_TYPE": "application/json",
               "CONTENT_LENGTH": str(len(raw)), "wsgi.input": io.BytesIO(raw), "QUERY_STRING": "",
               "HTTP_AUTHORIZATION": "Pairing " + (manager or self.grant["manager"])}
        env.update(extra)
        result = {}
        def start(status, headers): result.update(code=int(status[:3]), headers=dict(headers))
        result["raw"] = b"".join(PairingWeb(self.store)(env, start))
        return result

    def test_pair_page_csp_no_secrets_no_cdn(self):
        result = self.web("/pair", method="GET")
        self.assertEqual(result["code"], 200)
        self.assertEqual(result["headers"]["Referrer-Policy"], "no-referrer")
        self.assertIn("frame-ancestors 'none'", result["headers"]["Content-Security-Policy"])
        self.assertNotIn(self.grant["ticket"].encode(), result["raw"])

    def test_qr_rendered_locally_as_real_png(self):
        result = self.web("/pairing/offer", {"payload": "test-qr-offer"})
        self.assertEqual(result["code"], 200)
        qr = json.loads(result["raw"])["qr"]
        self.assertTrue(base64.b64decode(qr.split(",")[1]).startswith(b"\x89PNG\r\n\x1a\n"))

    def test_web_rejects_query_and_wrong_content_type(self):
        self.assertEqual(self.web("/pairing/offer", {}, QUERY_STRING="token=a")["code"], 400)
        self.assertEqual(self.web("/pairing/offer", {}, CONTENT_TYPE="text/plain")["code"], 415)
        self.assertEqual(self.web("/pairing/decision", {"approve": "true"})["code"], 404)


class HostBridgeTests(unittest.TestCase):
    def test_never_falls_back_to_container_on_missing_stale_or_broken_host(self):
        with tempfile.TemporaryDirectory() as folder:
            collector = FileCollector(folder)
            for value in (None, "{}", json.dumps({"exportedAt": 1, "status": {"hostname": "old"}})):
                if value is not None: (Path(folder) / "telemetry.json").write_text(value)
                with self.assertRaises(APIError) as error: collector.snapshot()
                self.assertEqual(error.exception.status, 503)

    def test_reads_actual_export_and_journal_is_not_mounted(self):
        with tempfile.TemporaryDirectory() as folder:
            export_once(FakeCollector(), folder)
            collector = FileCollector(folder)
            self.assertEqual(collector.snapshot()["hostname"], "fixture")
            self.assertEqual(collector.services(), {"services": []})
            with self.assertRaises(APIError): collector.logs("panel")


if __name__ == "__main__": unittest.main()
