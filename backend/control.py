"""Optional root broker, socket-activated. Fixed operations, no command strings."""
import json
import argparse
import os
from pathlib import Path
import socket
import struct
import subprocess
import time

UNITS = {"panel": "1panel-core.service", "panel-agent": "1panel-agent.service",
         "monitor": "beszel.service", "monitor-agent": "beszel-agent.service"}


def resolve(payload, config):
    if payload == {"action": "reboot"} and config.get("deviceReboot") is True:
        return ["/bin/systemctl", "--no-block", "reboot"]
    if (isinstance(payload, dict) and set(payload) == {"service", "action"}
            and config.get("serviceControl") is True
            and isinstance(payload["service"], str) and payload["service"] in UNITS
            and isinstance(payload["action"], str) and payload["action"] in {"start", "stop", "restart"}):
        return ["/bin/systemctl", "--no-block", payload["action"], UNITS[payload["service"]]]
    raise ValueError("operation_not_allowed")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--config', default='/etc/a7s-companion/control.json')
    args = parser.parse_args()
    if os.environ.get("LISTEN_PID") != str(os.getpid()) or os.environ.get("LISTEN_FDS") != "1":
        raise SystemExit("systemd_socket_required")
    listener = socket.fromfd(3, socket.AF_UNIX, socket.SOCK_STREAM)
    last_actions = {}
    while True:
        client, _ = listener.accept()
        with client:
            client.settimeout(2)
            try:
                config = json.loads(Path(args.config).read_text())
                _, uid, _ = struct.unpack("3i", client.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
                if uid not in config.get('allowedUIDs', [config.get('apiUID')]):
                    raise ValueError("peer_not_allowed")
                body = b""
                while b"\n" not in body and len(body) <= 1024:
                    part = client.recv(1025)
                    if not part:
                        break
                    body += part
                if len(body) > 1024 or not body.endswith(b"\n"):
                    raise ValueError("invalid_frame")
                payload = json.loads(body)
                if payload == {'action': 'snapshot'}:
                    from management import snapshot
                    client.sendall(json.dumps(snapshot(config)).encode() + b'\n')
                    continue
                if uid != config.get('apiUID'):
                    raise ValueError('read_only_peer')
                from management import cooldown_bucket, action_receipt
                bucket, cooldown = cooldown_bucket(payload)
                if bucket.startswith('led:') and payload['led'] not in config.get('leds', {}):
                    raise ValueError('led_protected')
                now = time.monotonic()
                if now - last_actions.get(bucket, -100.0) < cooldown:
                    raise ValueError("cooldown")
                last_actions[bucket] = now
                if isinstance(payload, dict) and ('led' in payload or 'container' in payload):
                    from management import execute
                    response = action_receipt(execute(payload, config), payload)
                else:
                    command = resolve(payload, config)
                    result = subprocess.run(command, capture_output=True, timeout=5,
                                            env={"PATH": "/usr/bin:/bin", "LC_ALL": "C"})
                    response = {'accepted': result.returncode == 0}
            except (ValueError, OSError, KeyError, TypeError, subprocess.SubprocessError):
                response = {'accepted': False}
            try:
                client.sendall(json.dumps(response).encode() + b"\n")
            except OSError:
                pass


if __name__ == "__main__":
    main()
