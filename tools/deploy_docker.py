"""Desktop operator deployer: explicit source transfer, sudo on remote terminal, then open local QR page."""
import argparse
import io
from pathlib import Path
import re
import subprocess
import sys
import tarfile
import tempfile
from pair_device import main as pair_main

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--ssh", required=True)
    parser.add_argument("--endpoint", required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,100}", args.ssh):
        raise SystemExit("Use an existing SSH alias.")
    sys.path.insert(0, str(ROOT / "backend"))
    from pairing import endpoint
    origin = endpoint(args.endpoint)
    ssh = ["ssh", "-o", "StrictHostKeyChecking=yes"]
    result = subprocess.run(ssh + [args.ssh, "mktemp -d /tmp/corenest-deploy.XXXXXXXX"], capture_output=True, timeout=30)
    remote = result.stdout.decode().strip()
    if result.returncode or not re.fullmatch(r"/tmp/corenest-deploy\.[A-Za-z0-9]{8}", remote):
        raise SystemExit("Cannot create isolated staging folder over SSH.")
    files = [ROOT / name for name in ("Dockerfile", ".dockerignore", "compose.yaml", "deploy/install-docker.sh", "deploy/corenest-host.service")]
    files += list((ROOT / "backend").glob("*.py")) + [ROOT / "backend/requirements.txt"] + list((ROOT / "backend/web").glob("*"))
    archive = io.BytesIO()
    with tarfile.open(fileobj=archive, mode="w:gz") as package:
        for path in files:
            # Text deployment preserves LF regardless of Windows checkout settings.
            raw = path.read_bytes().replace(b"\r\n", b"\n")
            info = tarfile.TarInfo(path.relative_to(ROOT).as_posix()); info.size = len(raw); info.mode = 0o644
            package.addfile(info, io.BytesIO(raw))
    subprocess.run(ssh + [args.ssh, "tar -xz -C " + remote], input=archive.getvalue(), check=True, timeout=60)
    # A normal visible SSH terminal lets the owner enter sudo password locally; never collect it here.
    subprocess.run(ssh + ["-t", args.ssh, "cd " + remote + " && sudo sh deploy/install-docker.sh"], check=True)
    print("Deployment staging retained at " + remote + "; no existing files were deleted.")
    sys.argv = ["pair_device.py", "--ssh", args.ssh, "--endpoint", origin]
    pair_main()


if __name__ == "__main__": main()
