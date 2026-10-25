"""Exercise the production entrypoint on an ephemeral loopback port, no board writes."""
import hashlib
import json
from pathlib import Path
import secrets
import tempfile
import threading
import time
import urllib.request
import urllib.error
from serve import build_server


def main():
    with tempfile.TemporaryDirectory() as folder:
        private = Path(folder)
        token = secrets.token_urlsafe(32)
        cfg = {"viewerTokenSHA256": hashlib.sha256(token.encode()).hexdigest(),
               "adminTokenSHA256": hashlib.sha256(secrets.token_bytes(32)).hexdigest()}
        (private / "config.json").write_text(json.dumps(cfg), encoding="utf-8")
        server, app = build_server(private / "config.json", private / "state.sqlite3", 0)
        thread = threading.Thread(target=server.run, daemon=True)
        thread.start()
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        base = "http://127.0.0.1:%d" % int(server.effective_port)
        try:
            for _ in range(50):
                try:
                    opener.open(base + "/v1/status", timeout=1).close()
                    raise AssertionError("anonymous_request_was_accepted")
                except urllib.error.HTTPError as error:
                    assert error.code == 401
                    error.close()
                    break
                except urllib.error.URLError:
                    time.sleep(0.1)
            else:
                raise RuntimeError("production_server_startup_timeout")
            results = {}
            for path in ["status", "services", "network", "capabilities"]:
                request = urllib.request.Request(base + "/v1/" + path,
                                                 headers={"Authorization": "Bearer " + token})
                with opener.open(request, timeout=12) as response:
                    results[path] = json.load(response)
                    assert response.headers["Cache-Control"] == "no-store"
            assert results["capabilities"]["role"] == "viewer"
            assert not results["capabilities"]["serviceControl"]
            assert not results["capabilities"]["deviceReboot"]
            assert results["status"]["powerWatts"] is None
            print(json.dumps({"production_http_smoke": "passed", "anonymous_status": 401,
                              "authenticated_get_routes": 4, "mutations_executed": 0}))
        finally:
            server.close()
            thread.join(timeout=5)
            app.ledger.connection.close()
            assert not thread.is_alive(), "production_server_cleanup_timeout"


if __name__ == "__main__": main()
