"""Create a private Docker state volume. Repeated starts preserve all credentials."""
import hashlib
import json
import os
from pathlib import Path
import secrets


def main():
    os.umask(0o077)
    path = Path("/data/config.json")
    if not path.exists():
        # Legacy bootstrap bearer values are deliberately discarded; use per-device pairing.
        config = {"viewerTokenSHA256": hashlib.sha256(secrets.token_bytes(32)).hexdigest(),
                  "adminTokenSHA256": hashlib.sha256(secrets.token_bytes(32)).hexdigest(),
                  "serviceControl": False, "deviceReboot": False}
        with path.open("x", encoding="utf-8") as handle:
            json.dump(config, handle)
    os.execv("/usr/local/bin/python", ["python", "/app/serve.py", "--config", str(path),
             "--state", "/data/actions.sqlite3", "--pairing", "/data/pairing.sqlite3",
             "--telemetry", "/host-telemetry", "--bind", "0.0.0.0", "--port", "18766"])


if __name__ == "__main__": main()
