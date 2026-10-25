"""CI real-container integration test. Fixtures are explicitly not board telemetry."""
import argparse
import hashlib
import json
from pathlib import Path
import secrets
import subprocess
import tempfile
import time
import urllib.error
import urllib.request


def docker(*args):
    return subprocess.check_output(["docker", *args], timeout=90).decode().strip()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--platform", default="amd64")
    args = parser.parse_args()
    image, name = "corenest-server:0.3.0", "corenest-ci-" + secrets.token_hex(6)
    with tempfile.TemporaryDirectory() as folder:
        telemetry = Path(folder)
        telemetry.chmod(0o755)
        def update_fixture():
            (telemetry / "telemetry.json").write_text(json.dumps({"exportedAt": time.time(),
                "status": {"hostname": "ci-host-fixture-not-measurement", "powerWatts": None},
                "services": {"services": []}, "network": {"campusStatus": "unknown"}}))
            (telemetry / "telemetry.json").chmod(0o644)
        update_fixture()
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        try:
            docker("run", "-d", "--name", name, "--platform", "linux/" + args.platform, "--read-only",
                   "--cap-drop=ALL", "--security-opt=no-new-privileges", "--pids-limit=64", "--memory=128m",
                   "--publish", "127.0.0.1::18766", "--mount", "type=bind,source=%s,target=/host-telemetry,readonly" % telemetry,
                   "--mount", "type=volume,target=/data",
                   "--tmpfs", "/tmp:size=8m", image)
            mapping = docker("port", name, "18766/tcp")
            assert mapping.startswith("127.0.0.1:"), "public_port_forbidden"
            base = "http://" + mapping
            def request(path, data=None, auth=None, status=200):
                headers = {"Content-Type": "application/json"}
                if auth: headers["Authorization"] = auth
                req = urllib.request.Request(base + path, data=json.dumps(data).encode() if data is not None else None, headers=headers)
                try:
                    with opener.open(req, timeout=10) as response:
                        assert response.status == status
                        return json.load(response) if response.headers.get_content_type() == "application/json" else response.read()
                except urllib.error.HTTPError as error:
                    assert error.code == status, "unexpected_http_status"
            for _ in range(60):
                try:
                    request("/pair"); break
                except OSError: time.sleep(0.5)
            else: raise AssertionError("container_not_ready")
            request("/v1/status", status=401)
            grant_data = json.loads(docker("exec", name, "python", "/app/pairing.py", "create", "--endpoint", "https://ci.example.com"))
            from urllib.parse import parse_qs
            values = parse_qs(grant_data["fragment"])
            offer = json.loads(values["offer"][0]); manager = values["manager"][0]
            token = secrets.token_urlsafe(32)
            pending = request("/v1/pairing/request", {"ticket": offer["ticket"], "tokenSHA256": hashlib.sha256(token.encode()).hexdigest(), "name": "CI test phone"})
            request("/v1/status", auth="Bearer " + token, status=401)
            page = request("/pairing/offer", {}, "Pairing " + manager)
            assert pending["verificationCode"] == page["verificationCode"]
            request("/pairing/decision", {"approve": True}, "Pairing " + manager)
            update_fixture()
            assert request("/v1/status", auth="Bearer " + token)["hostname"] == "ci-host-fixture-not-measurement"
            caps = request("/v1/capabilities", auth="Bearer " + token)
            assert caps["role"] == "viewer" and not caps["serviceControl"]
            docker("restart", name)
            # Docker can allocate a new ephemeral host port on restart; credentials stay in the volume.
            base = "http://" + docker("port", name, "18766/tcp")
            for _ in range(60):
                try:
                    assert request("/v1/pairing/result", auth="Bearer " + token)["state"] == "approved"; break
                except OSError: time.sleep(0.5)
            else:
                print(docker("logs", "--tail", "30", name))
                raise AssertionError("restart_not_ready")
            docker("exec", name, "python", "/app/pairing.py", "revoke", pending["deviceId"])
            request("/v1/status", auth="Bearer " + token, status=401)
            inspect = json.loads(docker("inspect", name))[0]
            assert inspect["Config"]["User"] == "10001:10001"
            assert inspect["HostConfig"]["ReadonlyRootfs"]
            assert not inspect["HostConfig"]["Privileged"]
            assert not any("docker.sock" in mount["Destination"] for mount in inspect["Mounts"])
            print(json.dumps({"container_integration": "passed", "platform": args.platform,
                              "pairing": "approval_required", "restart_persistence": "passed", "revoke": "passed",
                              "host_metrics": "explicit_fixture", "privileged": False}))
        finally:
            # Exact random CI-created name only; never an operator's deployed container or volume.
            subprocess.run(["docker", "rm", "-f", "-v", name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)


if __name__ == "__main__": main()
