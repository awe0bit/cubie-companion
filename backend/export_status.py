"""Runs as the existing campus user; exports four fixed non-secret fields only."""
import json
import os
from pathlib import Path
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from server import safe_campus_status


def public_fields(raw):
    safe = safe_campus_status(raw)
    return {"status": safe["campusStatus"], "checked_at": safe["campusCheckedAt"],
            "requires_attention": safe["requiresAttention"], "attempts_last_hour": safe["attemptsLastHour"]}


def main():
    target = Path("/run/a7s-companion-public/campus.json")
    try:
        raw = json.loads(Path("/run/a7s-campus-agent/status.json").read_text())
    except (OSError, ValueError):
        raw = {}
    payload = public_fields(raw)
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=str(target.parent), delete=False) as stream:
        temporary = Path(stream.name)
        json.dump(payload, stream)
    try:
        temporary.chmod(0o644)
        os.replace(str(temporary), str(target))
    finally:
        if temporary.exists():
            temporary.unlink()


if __name__ == "__main__": main()
