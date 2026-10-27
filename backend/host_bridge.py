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
    def devices(self): return self._read("devices")
    def management(self): return self._read("management")
    def logs(self, ident): raise APIError(503, "host_journal_not_exported")


def export_once(collector, folder, cache=None):
    folder = Path(folder)
    cache = {} if cache is None else cache
    now = time.monotonic()
    if now - cache.get('metadata_at', float('-inf')) >= 5:
        try:
            from management import broker_request
            management = broker_request({'action': 'snapshot'})
        except (OSError, ValueError, AttributeError):
            management = {'sampledAt': __import__('server').utc(), 'leds': [], 'containers': [],
                          'dockerAvailable': False, 'serviceControl': False, 'ledControl': False, 'dockerControl': False}
        cache.update(services=collector.services(), network=collector.network(), management=management, metadata_at=now)
    if now - cache.get('devices_at', float('-inf')) >= 10:
        cache.update(devices=collector.devices(), devices_at=now)
    payload = {"status": collector.snapshot(), "services": cache['services'], "network": cache['network'],
               "management": cache['management'], "devices": cache['devices'], "exportedAt": time.time()}
    temporary = folder / "telemetry.tmp"
    temporary.write_text(json.dumps(payload, ensure_ascii=False, allow_nan=False), encoding="utf-8")
    temporary.chmod(0o644)
    os.replace(str(temporary), str(folder / "telemetry.json"))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", default="/run/corenest-host")
    args = parser.parse_args()
    collector = Collector()
    cache = {}
    while True:
        started = time.monotonic()
        export_once(collector, args.output, cache)
        time.sleep(max(0.05, 1 - (time.monotonic() - started)))


if __name__ == "__main__": main()
