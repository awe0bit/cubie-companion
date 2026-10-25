"""Operator launcher: generate a QR offer remotely, forward loopback, open LOCAL browser.

Uses the operator's existing SSH config/key. No hostname or API credentials are built in.
Keep running until pairing completes; Ctrl+C closes only this SSH forward.
"""
import argparse
import json
import re
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
import webbrowser
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))
from pairing import endpoint


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--ssh", help="Existing SSH alias, e.g. board. Omit on the board.")
    parser.add_argument("--endpoint", required=True, help="Configured, reachable HTTPS API origin, not the SSH hostname.")
    parser.add_argument("--role", choices=("viewer", "admin"), default="viewer")
    args = parser.parse_args()
    origin = endpoint(args.endpoint)
    if args.ssh and not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,100}", args.ssh):
        raise SystemExit("Use an existing simple SSH host alias.")
    # Validate the public origin BEFORE creating an offer. Do not claim success behind an Access login redirect.
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *unused): return None
    opener = urllib.request.build_opener(NoRedirect())
    try:
        with opener.open(origin + "/pair", timeout=12) as response:
            if b"CoreNest" not in response.read(32768): raise ValueError()
    except (OSError, ValueError):
        raise SystemExit("HTTPS endpoint is not reachable as CoreNest (or Cloudflare Access requires login). Configure routing/auth first; no QR was issued.")
    command = ["docker", "compose", "-f", "/opt/corenest/compose.yaml", "exec", "-T", "server", "python",
               "/app/pairing.py", "create", "--endpoint", origin, "--role", args.role]
    prefix = ["ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", args.ssh] if args.ssh else []
    result = subprocess.run(prefix + command, capture_output=True, timeout=45)
    if result.returncode:
        raise SystemExit("Cannot create offer. Check Docker installation and operator permissions; no credentials were printed.")
    offer = json.loads(result.stdout)
    port, tunnel = 18766, None
    if args.ssh:
        with socket.socket() as channel:
            channel.bind(("127.0.0.1", 0)); port = channel.getsockname()[1]
        tunnel = subprocess.Popen(["ssh", "-N", "-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
            "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=20", "-L",
            "127.0.0.1:%d:127.0.0.1:18766" % port, args.ssh], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            creationflags=subprocess.CREATE_NO_WINDOW if sys.platform == "win32" else 0)
    url = "http://127.0.0.1:%d/pair#%s" % (port, offer["fragment"])
    local = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        for _ in range(50):
            if tunnel is not None and tunnel.poll() is not None: raise SystemExit("SSH forwarding failed.")
            try:
                local.open("http://127.0.0.1:%d/pair" % port, timeout=1).close()
                break
            except OSError: time.sleep(0.1)
        else: raise SystemExit("Pairing page did not start.")
        opened = webbrowser.open(url)
        print("Pairing page opened. Scan in CoreNest, compare the six-digit code, then approve. Ctrl+C closes the forward.")
        if not opened:
            # Explicitly requested terminal fallback; the bootstrap URL is a secret, not a log artifact.
            print("No desktop browser. Open this private, five-minute link on your own computer (do not share):\n" + url)
        while time.time() < offer["expiresAt"] + 10:
            if tunnel is not None and tunnel.poll() is not None: break
            time.sleep(1)
    except KeyboardInterrupt:
        pass
    finally:
        if tunnel is not None:
            tunnel.terminate()
            try: tunnel.wait(timeout=5)
            except subprocess.TimeoutExpired: tunnel.kill(); tunnel.wait()


if __name__ == "__main__": main()
