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
CONTROL_SOCKET = os.environ.get('CORENEST_CONTROL_SOCKET', "/run/a7s-companion-control.sock")


class APIError(Exception):
    def __init__(self, status, code):
        self.status, self.code = status, code


class ActionLedger:
    """Persist before dispatch; network timeouts never make a request unseen."""
    def __init__(self, path=":memory:"):
        self.connection = sqlite3.connect(path, check_same_thread=False, isolation_level=None)
        self.connection.execute("CREATE TABLE IF NOT EXISTS requests (key TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, timestamp REAL NOT NULL)")
        if 'bucket' not in {row[1] for row in self.connection.execute('PRAGMA table_info(requests)')}:
            self.connection.execute("ALTER TABLE requests ADD COLUMN bucket TEXT NOT NULL DEFAULT 'control'")
        self.lock = threading.Lock()

    def reserve(self, key, fingerprint, bucket='control', cooldown=10):
        now = time.time()
        with self.lock:
            self.connection.execute("BEGIN IMMEDIATE")
            try:
                self.connection.execute("DELETE FROM requests WHERE timestamp < ?", (now - 600,))
                old = self.connection.execute("SELECT fingerprint FROM requests WHERE key = ?", (key,)).fetchone()
                if old:
                    raise APIError(409, "request_already_seen" if old[0] == fingerprint else "idempotency_conflict")
                latest = self.connection.execute("SELECT MAX(timestamp) FROM requests WHERE bucket = ?", (bucket,)).fetchone()[0]
                if latest is not None and now - latest < cooldown:
                    raise APIError(429, "control_cooldown")
                self.connection.execute("INSERT INTO requests(key,fingerprint,timestamp,bucket) VALUES (?, ?, ?, ?)", (key, fingerprint, now, bucket))
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
            if self.cached is not None and now - self.cached_at < 0.9:
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

    def devices(self):
        from hardware import HardwareInventory
        return HardwareInventory(self.sys, self.proc).collect()

    def management(self):
        from management import broker_request
        try: return broker_request({'action': 'snapshot'})
        except (OSError, ValueError): raise APIError(503, 'control_unavailable')

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
            channel.settimeout(18)
            channel.connect(CONTROL_SOCKET)
            channel.sendall(json.dumps(payload).encode() + b"\n")
            data = b""
            while b"\n" not in data and len(data) < 2048:
                block = channel.recv(2048)
                if not block:
                    break
                data += block
            result = json.loads(data)
            from management import action_receipt
            try:
                receipt = action_receipt(result, payload)
            except (ValueError, TypeError):
                raise APIError(403, "control_not_enabled")
    except APIError:
        raise
    except (OSError, ValueError, AttributeError):
        raise APIError(503, "control_unavailable")
    return receipt


class App:
    def __init__(self, config, collector=None, controller=control, ledger=None, pairing=None, observer=None):
        self.config, self.collector, self.controller = config, collector or Collector(), controller
        self.pairing = pairing
        self.observer = observer
        for key in ("viewerTokenSHA256", "adminTokenSHA256"):
            if not re.fullmatch(r"[0-9a-f]{64}", config.get(key, "")):
                raise ValueError("invalid_auth_configuration")
        if config["viewerTokenSHA256"] == config["adminTokenSHA256"]:
            raise ValueError("roles_require_distinct_tokens")
        self.ledger = ledger or ActionLedger()
        self.led_readbacks = {}
        self.readback_lock = threading.Lock()
        self.stream_slots = threading.BoundedSemaphore(2)

    def management(self):
        result = self.collector.management()
        # Readbacks are authoritative; the read-only host export can lag five seconds.
        with self.readback_lock:
            self.led_readbacks = {key: value for key, value in self.led_readbacks.items()
                                  if time.monotonic() - value[0] < 8}
            leds = []
            for item in result['leds']:
                cached = self.led_readbacks.get(item['id'])
                if cached:
                    try:
                        old = datetime.fromisoformat(result['sampledAt'].replace('Z', '+00:00'))
                        new = datetime.fromisoformat(cached[1]['sampledAt'].replace('Z', '+00:00'))
                        if old < new: item = dict(item, mode=cached[1]['mode'])
                    except (ValueError, KeyError, TypeError): pass
                leds.append(item)
        return dict(result, leds=leds)

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

    def capabilities(self, role, managed):
        return {"apiVersion": 1, "role": role, "snapshotBundle": True, "liveSnapshots": True, "adaptiveStreaming": True,
                "serviceControl": self.config.get("serviceControl") is True and role == "admin" and managed.get('serviceControl', True),
                "deviceReboot": self.config.get("deviceReboot") is True and role == "admin",
                "rawLogs": False,
                "dockerControl": self.config.get('dockerControl') is True and role == 'admin' and managed.get('dockerControl') is True,
                "ledControl": self.config.get('ledControl') is True and role == 'admin' and managed.get('ledControl') is True,
                "managementInventory": True, "powerMeasurement": False, "fanRPM": False, "deviceInventory": True}

    @staticmethod
    def readonly_management(result, role):
        if role == 'admin': return result
        return dict(result, leds=[dict(x, controllable=False) for x in result['leds']],
                    containers=[dict(x, controllable=False) for x in result['containers']])

    def bundled_snapshot(self, role):
        # One authenticated tunnel roundtrip instead of six competing requests.
        # Optional inventories cannot hold basic telemetry hostage when unavailable.
        result = {'status': self.collector.snapshot(), 'services': self.collector.services(),
                  'network': self.collector.network(), 'management': None, 'inventory': None}
        try:
            managed = self.management()
            result['management'] = self.readonly_management(managed, role)
        except (APIError, AttributeError):
            managed = {'serviceControl': False}
        result['capabilities'] = self.capabilities(role, managed)
        try: result['inventory'] = self.collector.devices()
        except (APIError, AttributeError): pass
        return result

    def dispatch(self, env):
        role = self.role(env)
        method, path = env.get("REQUEST_METHOD"), env.get("PATH_INFO", "")
        if env.get("QUERY_STRING"):
            raise APIError(400, "query_not_supported")
        if method == "GET":
            if path == '/v1/snapshot':
                return self.bundled_snapshot(role)
            if path == "/v1/status":
                return self.collector.snapshot()
            if path == "/v1/services":
                return self.collector.services()
            if path == "/v1/network":
                return self.collector.network()
            if path == "/v1/devices":
                return self.collector.devices()
            if path == '/v1/management':
                result = self.management()
                return self.readonly_management(result, role)
            if path == "/v1/capabilities":
                try: managed = self.collector.management()
                except (APIError, AttributeError): managed = {}
                return self.capabilities(role, managed)
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
            elif re.fullmatch(r'/v1/leds/[A-Za-z0-9:_-]{1,80}/actions', path):
                if self.config.get('ledControl') is not True: raise APIError(403, 'control_not_enabled')
                if set(body) != {'mode'} or not isinstance(body['mode'], str) or body['mode'] not in {'on', 'off', 'system'}:
                    raise APIError(400, 'invalid_mode')
                payload = {'led': path.split('/')[3], 'mode': body['mode']}
            elif re.fullmatch(r'/v1/containers/[a-f0-9]{64}/actions', path):
                if self.config.get('dockerControl') is not True: raise APIError(403, 'control_not_enabled')
                if set(body) != {'action'} or not isinstance(body['action'], str) or body['action'] not in ACTIONS:
                    raise APIError(400, 'invalid_action')
                payload = {'container': path.split('/')[3], 'action': body['action']}
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
            from management import cooldown_bucket
            bucket, cooldown = cooldown_bucket(payload)
            self.ledger.reserve(key, fingerprint, bucket=bucket, cooldown=cooldown)
            # Record before dispatch. Never automatically retry an uncertain mutation.
            result = self.controller(payload)
            if 'led' in payload and isinstance(result, dict) and 'led' in result:
                from management import action_receipt
                result = action_receipt(result, payload)
                with self.readback_lock:
                    self.led_readbacks[payload['led']] = (time.monotonic(), result['led'])
            return result
        raise APIError(404 if method in {"GET", "POST"} else 405, "not_found")

    def __call__(self, env, start_response):
        started = time.monotonic()
        path = env.get("PATH_INFO", "")
        if self.pairing and (path in {"/pair", "/pair.js", "/pair.css", "/pairing/offer", "/pairing/decision"}
                             or path in {"/v1/pairing/request", "/v1/pairing/result"}):
            from pairing_web import PairingWeb
            return PairingWeb(self.pairing)(env, start_response)
        try:
            if path == '/v1/events' and env.get('REQUEST_METHOD') == 'GET':
                from realtime import SnapshotStream, frame
                role = self.role(env)
                if env.get('QUERY_STRING'): raise APIError(400, 'query_not_supported')
                interval = env.get('HTTP_X_CORENEST_INTERVAL', '1')
                if interval not in {'1', '5', '15'}: raise APIError(400, 'invalid_stream_interval')
                if not self.stream_slots.acquire(blocking=False): raise APIError(503, 'stream_capacity')
                try:
                    initial = frame(self.bundled_snapshot(role))
                except Exception:
                    self.stream_slots.release()
                    raise
                stream = SnapshotStream(self, env, initial,
                    duration=90 if 'HTTP_X_CORENEST_INTERVAL' in env else 12, interval=int(interval))
                try:
                    start_response('200 OK', [('Content-Type', 'text/event-stream; charset=utf-8'),
                        ('Cache-Control', 'no-store, no-transform'), ('X-Accel-Buffering', 'no'),
                        ('X-Content-Type-Options', 'nosniff')])
                except Exception:
                    stream.close()
                    raise
                return stream
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
        if self.observer:
            # Fixed route categories only: no raw URL, headers, credentials, body or IP.
            route = path[4:] if path in {'/v1/snapshot', '/v1/status', '/v1/services', '/v1/network',
                                       '/v1/capabilities', '/v1/management', '/v1/devices'} else 'other'
            if re.fullmatch(r'/v1/leds/[A-Za-z0-9:_-]{1,80}/actions', path): route = 'led.action'
            if re.fullmatch(r'/v1/containers/[a-f0-9]{64}/actions', path): route = 'container.action'
            event = {'event': 'api_timing', 'route': route, 'status': code,
                     'duration_ms': round((time.monotonic() - started) * 1000)}
            try: self.observer(event)
            except Exception: pass  # Diagnostics cannot turn a completed mutation into a failure.
        if code == 401:
            headers.append(("WWW-Authenticate", "Bearer"))
        start_response(str(code) + " " + labels[code], headers)
        return [body]


