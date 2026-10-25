import hashlib
import io
import json
from pathlib import Path
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch
from wsgiref.simple_server import make_server, WSGIRequestHandler
import urllib.request
import urllib.error

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from server import App, Collector, APIError, SERVICES, ActionLedger, safe_campus_status
from control import resolve
from export_status import public_fields

VIEWER = "v" * 48
ADMIN = "a" * 48


def config(**extra):
    return dict(viewerTokenSHA256=hashlib.sha256(VIEWER.encode()).hexdigest(),
                adminTokenSHA256=hashlib.sha256(ADMIN.encode()).hexdigest(), **extra)


class FakeCollector:
    def snapshot(self): return {"hostname": "fixture", "cpuPercent": None, "powerWatts": None}
    def services(self): return {"services": []}
    def network(self): return {"campusStatus": "unknown"}
    def logs(self, ident):
        if ident not in SERVICES: raise APIError(404, "unknown_service")
        return {"events": []}


def call(app, path="/v1/status", method="GET", token=VIEWER, body=None, key="12345678-1234-1234-1234-123456789012", **extra):
    encoded = json.dumps(body).encode() if body is not None else b""
    env = {"PATH_INFO": path, "REQUEST_METHOD": method, "QUERY_STRING": "",
           "CONTENT_LENGTH": str(len(encoded)), "CONTENT_TYPE": "application/json",
           "HTTP_IDEMPOTENCY_KEY": key, "wsgi.input": io.BytesIO(encoded)}
    if token is not None: env["HTTP_AUTHORIZATION"] = "Bearer " + token
    env.update(extra)
    result = {}
    def start(status, headers): result.update(code=int(status.split()[0]), headers=dict(headers))
    result["body"] = json.loads(b"".join(app(env, start)))
    return result


class AuthTests(unittest.TestCase):
    def setUp(self): self.app = App(config(), FakeCollector())

    def test_all_get_routes_require_auth(self):
        for path in ["/v1/status", "/v1/services", "/v1/network", "/v1/capabilities", "/v1/services/panel/logs"]:
            self.assertEqual(call(self.app, path, token=None)["code"], 401)

    def test_bad_and_oversized_tokens(self):
        for token in ["wrong", "", "v" * 500, "密码", VIEWER + " "]:
            self.assertEqual(call(self.app, token=token)["code"], 401)

    def test_authenticated_read(self): self.assertEqual(call(self.app)["code"], 200)
    def test_query_rejected(self): self.assertEqual(call(self.app, QUERY_STRING="token=x")["code"], 400)
    def test_documentation_not_public(self): self.assertEqual(call(self.app, "/docs")["code"], 404)
    def test_unsupported_method(self): self.assertEqual(call(self.app, method="DELETE")["code"], 405)
    def test_cache_disabled(self): self.assertEqual(call(self.app)["headers"]["Cache-Control"], "no-store")

    def test_roles_distinct(self):
        cfg = config(); cfg["adminTokenSHA256"] = cfg["viewerTokenSHA256"]
        self.assertRaises(ValueError, App, cfg)

    def test_bad_hash_rejected(self): self.assertRaises(ValueError, App, {"viewerTokenSHA256": "bad"})
    def test_viewer_cannot_mutate(self):
        self.assertEqual(call(self.app, "/v1/services/panel/actions", "POST", body={"action": "restart"})["code"], 403)

    def test_role_capabilities(self):
        app = App(config(serviceControl=True, deviceReboot=True), FakeCollector())
        self.assertFalse(call(app, "/v1/capabilities")["body"]["serviceControl"])
        self.assertTrue(call(app, "/v1/capabilities", token=ADMIN)["body"]["serviceControl"])


class ControlTests(unittest.TestCase):
    def setUp(self):
        self.calls = []
        self.app = App(config(serviceControl=True, deviceReboot=True), FakeCollector(), self.execute)
    def execute(self, value):
        self.calls.append(value)
        return {"accepted": True}
    def post(self, path="/v1/services/panel/actions", body=None, **kwargs):
        return call(self.app, path, "POST", ADMIN, body if body is not None else {"action": "restart"}, **kwargs)

    def test_control_off_by_default(self):
        self.app.config["serviceControl"] = False
        self.assertEqual(self.post()["code"], 403)
        self.assertEqual(self.calls, [])

    def test_valid_control(self):
        self.assertEqual(self.post()["body"], {"accepted": True})
        self.assertEqual(self.calls, [{"service": "panel", "action": "restart"}])

    def test_network_services_protected(self):
        for ident in ["campus", "tunnel", "ssh", "docker", "../ssh", "panel;reboot"]:
            self.assertNotEqual(self.post("/v1/services/" + ident + "/actions")["code"], 200)
        self.assertEqual(self.calls, [])

    def test_action_injection_and_wrong_types(self):
        for action in ["restart;reboot", "reload", "", [], {}, 1, None]:
            self.assertEqual(self.post(body={"action": action})["code"], 400)
        self.assertEqual(self.calls, [])

    def test_extra_fields_rejected(self):
        self.assertEqual(self.post(body={"action": "restart", "unit": "ssh"})["code"], 400)

    def test_idempotency_required(self): self.assertEqual(self.post(key="")["code"], 400)
    def test_idempotency_duplicate(self):
        self.assertEqual(self.post()["code"], 200)
        self.assertEqual(self.post()["code"], 409)
        self.assertEqual(len(self.calls), 1)

    def test_idempotency_conflict(self):
        self.post()
        self.assertEqual(self.post(body={"action": "stop"})["body"]["error"], "idempotency_conflict")

    def test_cooldown(self):
        self.post()
        self.assertEqual(self.post(key="another-request-key-1234")["code"], 429)

    def test_uncertain_result_not_retried(self):
        self.app.controller = lambda _: (_ for _ in ()).throw(OSError("private detail"))
        self.assertEqual(self.post()["code"], 500)
        self.assertEqual(self.post()["code"], 409)

    def test_reboot_confirmation_required(self):
        self.assertEqual(self.post("/v1/device/reboot", body={"confirmation": "yes"})["code"], 400)

    def test_reboot_disabled(self):
        self.app.config["deviceReboot"] = False
        self.assertEqual(self.post("/v1/device/reboot", body={"confirmation": "REBOOT"})["code"], 403)

    def test_reboot_enabled(self):
        self.assertEqual(self.post("/v1/device/reboot", body={"confirmation": "REBOOT"})["code"], 200)

    def test_body_limit(self): self.assertEqual(self.post(CONTENT_LENGTH="2000")["code"], 413)
    def test_invalid_content_length(self): self.assertEqual(self.post(CONTENT_LENGTH="abc")["code"], 400)
    def test_json_content_type_required(self): self.assertEqual(self.post(CONTENT_TYPE="text/plain")["code"], 415)
    def test_non_object_json_rejected(self): self.assertEqual(self.post(body=["restart"])["code"], 400)
    def test_errors_hide_internal_details(self):
        self.app.controller = lambda _: (_ for _ in ()).throw(OSError("secret_password"))
        self.assertNotIn("secret_password", json.dumps(self.post()))

    def test_durable_ledger_survives_restart(self):
        with tempfile.TemporaryDirectory() as folder:
            path = str(Path(folder) / "actions.sqlite3")
            first = ActionLedger(path)
            first.reserve("key", "fingerprint")
            first.connection.close()
            second = ActionLedger(path)
            with self.assertRaises(APIError) as caught: second.reserve("key", "fingerprint")
            self.assertEqual(caught.exception.code, "request_already_seen")
            second.connection.close()

    def test_root_broker_double_checks(self):
        for payload in [{"service": "tunnel", "action": "stop"}, {"action": "reboot"},
                        {"service": "panel", "action": "stop;reboot"}, {"service": [], "action": "stop"}]:
            self.assertRaises(ValueError, resolve, payload, {"serviceControl": True})

    def test_root_broker_exact_argv(self):
        self.assertEqual(resolve({"service": "panel", "action": "restart"}, {"serviceControl": True}),
                         ["/bin/systemctl", "--no-block", "restart", "1panel-core.service"])


class CollectorTests(unittest.TestCase):
    def test_safe_status_exports_only_fixed_fields(self):
        raw = {"status": "online", "checked_at": "2026-10-25T07:23:10+00:00",
               "requires_attention": False, "attempts_last_hour": 2,
               "password": "never-export", "cookies": ["private"], "retry_at": 123}
        self.assertEqual(set(public_fields(raw)), {"status", "checked_at", "requires_attention", "attempts_last_hour"})
        self.assertNotIn("never-export", json.dumps(public_fields(raw)))

    def test_stale_campus_status_is_not_online(self):
        result = safe_campus_status({"status": "online", "checked_at": "2000-01-01T00:00:00Z"})
        self.assertEqual(result["campusStatus"], "stale")

    def test_unknown_status_never_passes_untrusted_text(self):
        result = public_fields({"status": "password=secret", "checked_at": "not a date",
                                "attempts_last_hour": "secret"})
        self.assertNotIn("secret", json.dumps(result))

    def test_service_list_uses_one_systemd_request(self):
        calls = []
        def runner(args):
            calls.append(args)
            return "Id=1panel-core.service\nActiveState=active\n\nId=a7s-cloudflared.service\nActiveState=failed"
        services = Collector(runner=runner).services()["services"]
        self.assertEqual(len(calls), 1)
        self.assertEqual(services[0]["state"], "active")
        self.assertEqual(services[-1]["state"], "failed")

    def test_missing_metrics_are_null(self):
        with tempfile.TemporaryDirectory() as folder:
            r = Collector(folder, folder).snapshot()
            self.assertIsNone(r["cpuPercent"])
            self.assertIsNone(r["powerWatts"])
            self.assertIsNone(r["fanRPM"])
            self.assertEqual(r["temperatures"], [])

    def test_cpu_memory_network_samples(self):
        with tempfile.TemporaryDirectory() as folder:
            p = Path(folder)
            (p / "stat").write_text("cpu 20 0 20 50 10 0 0 0 0 0\n")
            (p / "meminfo").write_text("MemTotal: 1000 kB\nMemAvailable: 400 kB\n")
            (p / "uptime").write_text("100.5 20.0")
            counter = p / "class/net/wlan0/statistics"
            counter.mkdir(parents=True)
            (counter / "rx_bytes").write_text("100")
            (counter / "tx_bytes").write_text("50")
            c = Collector(folder, folder)
            with patch("server.time.monotonic", return_value=10): first = c.snapshot()
            self.assertIsNone(first["cpuPercent"])
            self.assertEqual(first["memoryUsedBytes"], 600 * 1024)
            (p / "stat").write_text("cpu 40 0 40 110 10 0 0 0 0 0\n")
            (counter / "rx_bytes").write_text("500")
            (counter / "tx_bytes").write_text("150")
            with patch("server.time.monotonic", return_value=14): second = c.snapshot()
            self.assertEqual(second["cpuPercent"], 40.0)
            self.assertEqual(second["rxBytesPerSecond"], 100)
            self.assertEqual(second["txBytesPerSecond"], 25)

    def test_logs_never_emit_raw_messages(self):
        entries = [dict(_PID="1", MESSAGE_ID="39f53479d3a045ac8e11786248231fbf",
                        MESSAGE="password=supersecret", __REALTIME_TIMESTAMP="1000000"),
                   dict(_PID="123", MESSAGE="Authorization: Bearer secret", __REALTIME_TIMESTAMP="1000000")]
        c = Collector(runner=lambda _: "\n".join(json.dumps(e) for e in entries))
        logs = c.logs("panel")
        self.assertEqual(len(logs["events"]), 1)
        self.assertNotIn("supersecret", json.dumps(logs))
        self.assertNotIn("Bearer", json.dumps(logs))

    def test_unknown_log_service(self): self.assertRaises(APIError, Collector().logs, "ssh")

    def test_system_service_command_failure_is_unknown(self):
        c = Collector(runner=lambda _: (_ for _ in ()).throw(OSError()))
        self.assertTrue(all(s["state"] == "unknown" for s in c.services()["services"]))


class HTTPIntegrationTests(unittest.TestCase):
    def test_real_loopback_http_and_unauthenticated_denial(self):
        class Quiet(WSGIRequestHandler):
            def log_message(self, *args): pass
        app = App(config(), FakeCollector())
        with make_server("127.0.0.1", 0, app, handler_class=Quiet) as server:
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            url = "http://127.0.0.1:%d/v1/status" % server.server_port
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
            try:
                with self.assertRaises(urllib.error.HTTPError) as caught: opener.open(url, timeout=3)
                self.assertEqual(caught.exception.code, 401)
                caught.exception.close()
                request = urllib.request.Request(url, headers={"Authorization": "Bearer " + VIEWER})
                with opener.open(request, timeout=3) as response:
                    self.assertEqual(json.load(response)["hostname"], "fixture")
            finally:
                server.shutdown()
                thread.join(timeout=3)


if __name__ == "__main__": unittest.main()
