"""Loopback-only WSGI management API. No shell, Docker socket or credential proxy.

Python 3.9+, Waitress in production. Importing this module performs no I/O.
"""
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import shutil
import socket
import sqlite3
import subprocess
import threading
import time
import urllib.request
from datetime import datetime, timezone

SERVICES = {
    "panel": ("1panel-core.service", "1Panel", True),
    "panel-agent": ("1panel-agent.service", "1Panel Agent", True),
    "monitor": ("beszel.service", "Beszel", True),
    "monitor-agent": ("beszel-agent.service", "Beszel Agent", True),
    "campus": ("a7s-campus-agent.timer", "校园网守护", False),
    "tunnel": ("a7s-cloudflared.service", "Cloudflare Tunnel", False),
}
ACTIONS = {"start", "stop", "restart"}
CONTROL_SOCKET = "/run/a7s-companion-control.sock"


class APIError(Exception):
    def __init__(self, status, code):
        self.status, self.code = status, code


class ActionLedger:
    """Persist before dispatch; network timeouts never make a request unseen."""
    def __init__(self, path=":memory:"):
        self.connection = sqlite3.connect(path, check_same_thread=False, isolation_level=None)
        self.connection.execute("CREATE TABLE IF NOT EXISTS requests (key TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, timestamp REAL NOT NULL)")
        self.lock = threading.Lock()

    def reserve(self, key, fingerprint):
        now = time.time()
        with self.lock:
            self.connection.execute("BEGIN IMMEDIATE")
            try:
                self.connection.execute("DELETE FROM requests WHERE timestamp < ?", (now - 600,))
                old = self.connection.execute("SELECT fingerprint FROM requests WHERE key = ?", (key,)).fetchone()
                if old:
                    raise APIError(409, "request_already_seen" if old[0] == fingerprint else "idempotency_conflict")
                latest = self.connection.execute("SELECT MAX(timestamp) FROM requests").fetchone()[0]
                if latest is not None and now - latest < 10:
                    raise APIError(429, "control_cooldown")
                self.connection.execute("INSERT INTO requests VALUES (?, ?, ?)", (key, fingerprint, now))
                self.connection.execute("COMMIT")
            except Exception:
                self.connection.execute("ROLLBACK")
                raise


def read(path):
    return Path(path).read_text(encoding="utf-8").strip()


def command(args):
    result = subprocess.run(args, capture_output=True, text=True, timeout=4,
                            env={"PATH": "/usr/sbin:/usr/bin:/sbin:/bin", "LC_ALL": "C"})
    if result.returncode:
        raise OSError("command_unavailable")
    return result.stdout.strip()


def utc():
    return datetime.now(timezone.utc).isoformat()


def safe_campus_status(status):
    r = {"campusStatus": "unknown", "campusCheckedAt": None,
         "requiresAttention": None, "attemptsLastHour": None}
    allowed = {"online", "off_network", "confirming_outage", "backoff", "paused",
               "captcha_required", "authenticated_no_internet", "service_unavailable",
               "authentication_disabled", "auth_rejected", "manual_required", "frequency_limited",
               "configuration_required", "credentials_required", "credentials_permissions",
               "network_binding_failed", "stale"}
    if not isinstance(status, dict):
        return r
    state = status.get("status")
    r["campusStatus"] = state if isinstance(state, str) and state in allowed else "unknown"
    try:
        stamp = datetime.fromisoformat(status.get("checked_at", "").replace("Z", "+00:00"))
        if stamp.tzinfo is None:
            raise ValueError("timezone_required")
        age = time.time() - stamp.timestamp()
        r["campusCheckedAt"] = stamp.isoformat()
        if age < -30 or age > 180:
            r["campusStatus"] = "stale"
    except (ValueError, TypeError, AttributeError, OverflowError):
        r["campusStatus"] = "stale"
    attention = status.get("requires_attention")
    if isinstance(attention, bool):
        r["requiresAttention"] = attention
    count = status.get("attempts_last_hour")
    if type(count) is int and 0 <= count <= 100:
        r["attemptsLastHour"] = count
    return r


class Collector:
    def __init__(self, proc="/proc", sys="/sys", runner=command):
        self.proc, self.sys, self.runner = Path(proc), Path(sys), runner
        self.lock = threading.Lock()
        self.previous = None
        self.cached = None
        self.cached_at = 0

    def snapshot(self):
        with self.lock:
            now = time.monotonic()
            if self.cached is not None and now - self.cached_at < 3:
                return self.cached
            data = {"sampledAt": utc(), "hostname": socket.gethostname(),
                    "cpuPercent": None, "memoryUsedBytes": None,
                    "memoryTotalBytes": None, "diskUsedBytes": None,
                    "diskTotalBytes": None, "uptimeSeconds": None,
                    "rxBytesPerSecond": None, "txBytesPerSecond": None,
                    "temperatures": [], "powerWatts": None, "fanRPM": None}
            cpu = rx = tx = None
            try:
                values = [int(x) for x in read(self.proc / "stat").splitlines()[0].split()[1:9]]
                cpu = (sum(values), values[3] + values[4])
            except (OSError, ValueError, IndexError):
                pass
            try:
                mem = {line.split(":")[0]: int(line.split()[1]) * 1024
                       for line in read(self.proc / "meminfo").splitlines() if ":" in line}
                data["memoryTotalBytes"] = mem["MemTotal"]
                data["memoryUsedBytes"] = mem["MemTotal"] - mem["MemAvailable"]
            except (OSError, ValueError, KeyError, IndexError):
                pass
            try:
                data["uptimeSeconds"] = float(read(self.proc / "uptime").split()[0])
                disk = shutil.disk_usage("/")
                data["diskTotalBytes"], data["diskUsedBytes"] = disk.total, disk.used
            except (OSError, ValueError, IndexError):
                pass
            try:
                rx = int(read(self.sys / "class/net/wlan0/statistics/rx_bytes"))
                tx = int(read(self.sys / "class/net/wlan0/statistics/tx_bytes"))
            except (OSError, ValueError):
                pass
            for zone in sorted((self.sys / "class/thermal").glob("thermal_zone*")):
                try:
                    value = int(read(zone / "temp")) / 1000
                    if -20 <= value <= 150:
                        data["temperatures"].append({"name": read(zone / "type"), "celsius": value})
                except (OSError, ValueError):
                    pass
            if self.previous:
                when, old_cpu, old_rx, old_tx = self.previous
                elapsed = now - when
                if cpu and old_cpu and cpu[0] > old_cpu[0]:
                    usage = 100 * (1 - (cpu[1] - old_cpu[1]) / (cpu[0] - old_cpu[0]))
                    data["cpuPercent"] = round(max(0, min(100, usage)), 1)
                if rx is not None and old_rx is not None and rx >= old_rx and elapsed > 0:
                    data["rxBytesPerSecond"] = round((rx - old_rx) / elapsed, 1)
                if tx is not None and old_tx is not None and tx >= old_tx and elapsed > 0:
                    data["txBytesPerSecond"] = round((tx - old_tx) / elapsed, 1)
            self.previous = (now, cpu, rx, tx)
            self.cached, self.cached_at = data, now
            return data

    def services(self):
        states = {}
        try:
            raw = self.runner(["/bin/systemctl", "show", "--property=Id,ActiveState"] +
                              [item[0] for item in SERVICES.values()])
            for block in raw.split("\n\n"):
                fields = dict(line.split("=", 1) for line in block.splitlines() if "=" in line)
                state = fields.get("ActiveState")
                if state in {"active", "inactive", "failed", "activating", "deactivating", "reloading"}:
                    states[fields.get("Id")] = state
        except (OSError, subprocess.SubprocessError):
            pass
        result = []
        for ident, (unit, name, controllable) in SERVICES.items():
            state = states.get(unit, "unknown")
            result.append({"id": ident, "unit": unit, "name": name, "state": state,
                           "controllable": controllable})
        return {"sampledAt": utc(), "services": result}

    def network(self):
        r = {"sampledAt": utc(), "profile": None, "interface": "wlan0",
             "campusStatus": "unknown", "campusCheckedAt": None,
             "requiresAttention": None, "attemptsLastHour": None,
             "tunnelReady": False}
        try:
            r["profile"] = self.runner(["/usr/bin/nmcli", "-g", "GENERAL.CONNECTION",
                                        "device", "show", "wlan0"])[:100]
        except (OSError, subprocess.SubprocessError):
            pass
        try:
            status = json.loads(read("/run/a7s-companion-public/campus.json"))
            r.update(safe_campus_status(status))
        except (OSError, ValueError, TypeError):
            pass
        try:
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
            with opener.open("http://127.0.0.1:20243/ready", timeout=1) as response:
                r["tunnelReady"] = response.status == 200
        except (OSError, ValueError):
            pass
        return r

    def logs(self, ident):
        """Only systemd lifecycle metadata; raw MESSAGE may contain credentials."""
        if ident not in SERVICES:
            raise APIError(404, "unknown_service")
        messages = {"39f53479d3a045ac8e11786248231fbf": "服务已启动",
                    "7d4958e842da4a758f6c1cdc7b36dcc5": "服务正在启动",
                    "9d1aaa27d60140bd96365438aad20286": "服务已停止",
                    "de5b426a63be47a7b6ac3eaac82e2f6f": "服务正在停止",
                    "be02cf6855d2428ba40df7e9d022f03d": "服务启动失败"}
        try:
            raw = self.runner(["/bin/journalctl", "--unit", SERVICES[ident][0],
                               "--boot", "--lines", "100", "--output", "json", "--no-pager"])
            events = []
            for line in raw.splitlines():
                try:
                    item = json.loads(line)
                    message = messages.get(item.get("MESSAGE_ID"))
                    if item.get("_PID") != "1" or not message:
                        continue
                    timestamp = int(item["__REALTIME_TIMESTAMP"]) / 1_000_000
                    events.append({"timestamp": datetime.fromtimestamp(timestamp, timezone.utc).isoformat(),
                                   "message": message})
                except (ValueError, KeyError, TypeError, OverflowError):
                    continue
            return {"serviceId": ident, "scope": "systemd_lifecycle_only", "events": events[-50:]}
        except (OSError, subprocess.SubprocessError):
            raise APIError(503, "journal_unavailable")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def control(payload):
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as channel:
            channel.settimeout(8)
            channel.connect(CONTROL_SOCKET)
            channel.sendall(json.dumps(payload).encode() + b"\n")
            data = b""
            while b"\n" not in data and len(data) < 2048:
                block = channel.recv(2048)
                if not block:
                    break
                data += block
            result = json.loads(data)
            if result != {"accepted": True}:
                raise APIError(403, "control_not_enabled")
    except APIError:
        raise
    except (OSError, ValueError, AttributeError):
        raise APIError(503, "control_unavailable")
    return {"accepted": True}


class App:
    def __init__(self, config, collector=None, controller=control, ledger=None, pairing=None):
        self.config, self.collector, self.controller = config, collector or Collector(), controller
        self.pairing = pairing
        for key in ("viewerTokenSHA256", "adminTokenSHA256"):
            if not re.fullmatch(r"[0-9a-f]{64}", config.get(key, "")):
                raise ValueError("invalid_auth_configuration")
        if config["viewerTokenSHA256"] == config["adminTokenSHA256"]:
            raise ValueError("roles_require_distinct_tokens")
        self.ledger = ledger or ActionLedger()

    def role(self, environ):
        value = environ.get("HTTP_AUTHORIZATION", "")
        if len(value) > 256 or not value.startswith("Bearer "):
            raise APIError(401, "unauthorized")
        digest = hashlib.sha256(value[7:].encode()).hexdigest()
        if hmac.compare_digest(digest, self.config["adminTokenSHA256"]):
            return "admin"
        if hmac.compare_digest(digest, self.config["viewerTokenSHA256"]):
            return "viewer"
        if self.pairing:
            role = self.pairing.role(digest)
            if role:
                return role
        raise APIError(401, "unauthorized")

    def dispatch(self, env):
        role = self.role(env)
        method, path = env.get("REQUEST_METHOD"), env.get("PATH_INFO", "")
        if env.get("QUERY_STRING"):
            raise APIError(400, "query_not_supported")
        if method == "GET":
            if path == "/v1/status":
                return self.collector.snapshot()
            if path == "/v1/services":
                return self.collector.services()
            if path == "/v1/network":
                return self.collector.network()
            if path == "/v1/capabilities":
                return {"apiVersion": 1, "role": role,
                        "serviceControl": self.config.get("serviceControl", False) is True and role == "admin",
                        "deviceReboot": self.config.get("deviceReboot", False) is True and role == "admin",
                        "rawLogs": False, "dockerControl": False, "ledControl": False,
                        "powerMeasurement": False, "fanRPM": False}
            match = re.fullmatch(r"/v1/services/([a-z-]+)/logs", path)
            if match:
                return self.collector.logs(match[1])
        elif method == "POST":
            if role != "admin":
                raise APIError(403, "admin_required")
            try:
                length = int(env.get("CONTENT_LENGTH", "0"))
            except ValueError:
                raise APIError(400, "invalid_length")
            if not 0 < length <= 1024:
                raise APIError(413, "invalid_body_size")
            if env.get("CONTENT_TYPE", "").split(";")[0] != "application/json":
                raise APIError(415, "json_required")
            try:
                body = json.loads(env["wsgi.input"].read(length))
            except (ValueError, UnicodeError):
                raise APIError(400, "invalid_json")
            if not isinstance(body, dict):
                raise APIError(400, "invalid_json")
            match = re.fullmatch(r"/v1/services/([a-z-]+)/actions", path)
            if match:
                ident = match[1]
                if ident not in SERVICES or not SERVICES[ident][2]:
                    raise APIError(403, "service_protected")
                if self.config.get("serviceControl") is not True:
                    raise APIError(403, "control_not_enabled")
                if (set(body) != {"action"} or not isinstance(body["action"], str)
                        or body["action"] not in ACTIONS):
                    raise APIError(400, "invalid_action")
                payload = {"service": ident, "action": body["action"]}
            elif path == "/v1/device/reboot":
                if self.config.get("deviceReboot") is not True:
                    raise APIError(403, "control_not_enabled")
                if body != {"confirmation": "REBOOT"}:
                    raise APIError(400, "confirmation_required")
                payload = {"action": "reboot"}
            else:
                raise APIError(404, "not_found")
            key = env.get("HTTP_IDEMPOTENCY_KEY", "")
            if not re.fullmatch(r"[A-Za-z0-9-]{16,64}", key):
                raise APIError(400, "idempotency_key_required")
            fingerprint = path + ":" + json.dumps(payload, sort_keys=True)
            self.ledger.reserve(key, fingerprint)
            # Record before dispatch. Never automatically retry an uncertain mutation.
            return self.controller(payload)
        raise APIError(404 if method in {"GET", "POST"} else 405, "not_found")

    def __call__(self, env, start_response):
        path = env.get("PATH_INFO", "")
        if self.pairing and (path in {"/pair", "/pair.js", "/pair.css", "/pairing/offer", "/pairing/decision"}
                             or path in {"/v1/pairing/request", "/v1/pairing/result"}):
            from pairing_web import PairingWeb
            return PairingWeb(self.pairing)(env, start_response)
        try:
            result, code = self.dispatch(env), 200
        except APIError as error:
            result, code = {"error": error.code}, error.status
        except Exception:
            result, code = {"error": "internal_error"}, 500
        body = json.dumps(result, ensure_ascii=False, allow_nan=False).encode("utf-8")
        labels = {200: "OK", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
                  404: "Not Found", 405: "Method Not Allowed", 409: "Conflict",
                  413: "Payload Too Large", 415: "Unsupported Media Type", 429: "Too Many Requests",
                  500: "Internal Server Error", 503: "Service Unavailable"}
        headers = [("Content-Type", "application/json; charset=utf-8"),
                   ("Content-Length", str(len(body))), ("Cache-Control", "no-store"),
                   ("X-Content-Type-Options", "nosniff")]
        if code == 401:
            headers.append(("WWW-Authenticate", "Bearer"))
        start_response(str(code) + " " + labels[code], headers)
        return [body]


