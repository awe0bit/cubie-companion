"""Optional root broker, socket-activated. Fixed operations, no command strings."""
import json
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
    if os.environ.get("LISTEN_PID") != str(os.getpid()) or os.environ.get("LISTEN_FDS") != "1":
        raise SystemExit("systemd_socket_required")
    listener = socket.fromfd(3, socket.AF_UNIX, socket.SOCK_STREAM)
    last_action = -100.0
    while True:
        client, _ = listener.accept()
        with client:
            client.settimeout(2)
            try:
                config = json.loads(Path("/etc/a7s-companion/control.json").read_text())
                _, uid, _ = struct.unpack("3i", client.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
                if uid != config["apiUID"] or type(config["apiUID"]) is not int:
                    raise ValueError("peer_not_allowed")
                body = b""
                while b"\n" not in body and len(body) <= 1024:
                    part = client.recv(1025)
                    if not part:
                        break
                    body += part
                if len(body) > 1024 or not body.endswith(b"\n"):
                    raise ValueError("invalid_frame")
                args = resolve(json.loads(body), config)
                now = time.monotonic()
                if now - last_action < 10:
                    raise ValueError("cooldown")
                last_action = now
                result = subprocess.run(args, capture_output=True, timeout=5,
                                        env={"PATH": "/usr/bin:/bin", "LC_ALL": "C"})
                accepted = result.returncode == 0
            except (ValueError, OSError, KeyError, TypeError, subprocess.SubprocessError):
                accepted = False
            try:
                client.sendall(json.dumps({"accepted": accepted}).encode() + b"\n")
            except OSError:
                pass


if __name__ == "__main__":
    main()
