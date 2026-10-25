"""Read-only host telemetry bridge: no Docker socket, D-Bus or host root mount."""
import argparse
import json
import os
from pathlib import Path
import time
from server import APIError, Collector


class FileCollector:
    def __init__(self, folder):
        self.path = Path(folder) / "telemetry.json"

    def _read(self, key):
        try:
            if self.path.stat().st_size > 131072:
                raise ValueError()
            data = json.loads(self.path.read_text(encoding="utf-8"))
            age = time.time() - data["exportedAt"]
            if not -5 <= age <= 25 or not isinstance(data[key], dict):
                raise ValueError()
            return data[key]
        except (OSError, ValueError, KeyError, TypeError):
            # Never substitute container measurements for missing/stale host data.
            raise APIError(503, "host_telemetry_unavailable")

    def snapshot(self): return self._read("status")
    def services(self): return self._read("services")
    def network(self): return self._read("network")
    def logs(self, ident): raise APIError(503, "host_journal_not_exported")


def export_once(collector, folder):
    folder = Path(folder)
    payload = {"status": collector.snapshot(), "services": collector.services(), "network": collector.network(),
               "exportedAt": time.time()}
    temporary = folder / "telemetry.tmp"
    temporary.write_text(json.dumps(payload, ensure_ascii=False, allow_nan=False), encoding="utf-8")
    temporary.chmod(0o644)
    os.replace(str(temporary), str(folder / "telemetry.json"))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", default="/run/corenest-host")
    args = parser.parse_args()
    collector = Collector()
    while True:
        export_once(collector, args.output)
        time.sleep(5)


if __name__ == "__main__": main()
