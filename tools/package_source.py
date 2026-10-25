"""Package tracked source only. Ignored/private local files never enter the ZIP."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import zipfile
from privacy_check import tracked, violations

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    version = json.loads((ROOT / "brand/identity.json").read_text())["version"]
    assert re.fullmatch(r"\d+\.\d+\.\d+", version), "invalid_version"
    output = args.output.resolve()
    assert not output.exists(), "refused_existing_source_archive"
    files = tracked()
    for name in files:
        assert not violations(name, (ROOT / name).read_bytes()), "privacy_check_failed"
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, "x", compression=zipfile.ZIP_DEFLATED) as archive:
        for name in files:
            archive.write(ROOT / name, "CoreNest/" + name)
    with zipfile.ZipFile(output) as archive:
        assert archive.testzip() is None
        assert len(archive.namelist()) == len(files)
    print(json.dumps({"version": version, "files": len(files),
                      "sha256": hashlib.sha256(output.read_bytes()).hexdigest(),
                      "source_only": True}))


if __name__ == "__main__": main()
