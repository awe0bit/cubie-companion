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
            for path in ["status", "services", "network", "capabilities", "devices", "snapshot"]:
                request = urllib.request.Request(base + "/v1/" + path,
                                                 headers={"Authorization": "Bearer " + token})
                with opener.open(request, timeout=12) as response:
                    results[path] = json.load(response)
                    assert response.headers["Cache-Control"] == "no-store"
            assert results["capabilities"]["role"] == "viewer"
            assert not results["capabilities"]["serviceControl"]
            assert not results["capabilities"]["deviceReboot"]
            assert results["status"]["powerWatts"] is None
            assert results['snapshot']['capabilities']['snapshotBundle']
            assert results['snapshot']['status']['powerWatts'] is None
            # Hold both permitted event streams while exercising another worker.
            # No host mutation is performed: this is a real HTTP read/concurrency check.
            streams = []
            try:
                for _ in range(2):
                    request = urllib.request.Request(base + '/v1/events', headers={'Authorization': 'Bearer ' + token})
                    stream = opener.open(request, timeout=12)
                    streams.append(stream)
                    assert stream.headers['Content-Type'].startswith('text/event-stream')
                    assert stream.readline() == b'event: snapshot\n'
                    assert stream.readline().startswith(b'data: ')
                    assert stream.readline() == b'\n'
                started = time.monotonic()
                request = urllib.request.Request(base + '/v1/status', headers={'Authorization': 'Bearer ' + token})
                with opener.open(request, timeout=3) as response: assert response.status == 200
                assert time.monotonic() - started < 3, 'streams_starved_regular_requests'
                try:
                    opener.open(urllib.request.Request(base + '/v1/events', headers={'Authorization': 'Bearer ' + token}), timeout=3)
                    raise AssertionError('stream_capacity_not_enforced')
                except urllib.error.HTTPError as error:
                    assert error.code == 503
                    error.close()
                # At least one subsequent event/heartbeat must arrive without reopening HTTP.
                assert streams[0].readline().startswith((b'event: snapshot', b': heartbeat'))
            finally:
                for stream in streams: stream.close()
            print(json.dumps({"production_http_smoke": "passed", "anonymous_status": 401,
                              "authenticated_get_routes": 7, "concurrent_streams": 2,
                              "stream_capacity_enforced": True, "mutations_executed": 0}))
        finally:
            server.task_dispatcher.shutdown(timeout=5)
            server.close()
            thread.join(timeout=5)
            app.ledger.connection.close()
            assert not thread.is_alive(), "production_server_cleanup_timeout"


if __name__ == "__main__": main()
