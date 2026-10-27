"""Bounded authenticated SSE, with capacity reserved for ordinary/control requests."""
import json
import time


def frame(snapshot):
    encoded = json.dumps(snapshot, ensure_ascii=False, allow_nan=False, separators=(',', ':')).encode('utf-8')
    if len(encoded) > 131072:
        raise ValueError('snapshot_too_large')
    return b'event: snapshot\ndata: ' + encoded + b'\n\n'


class SnapshotStream:
    # Short leases bound worker occupancy even if a proxy delays disconnect detection.
    # The native client renews successful leases, with no repeated full HTTP polling.
    def __init__(self, app, env, initial, duration=12, interval=1):
        self.app, self.env, self.initial = app, env, initial
        self.duration, self.interval = duration, interval
        self.closed = False

    def __iter__(self):
        end = time.monotonic() + self.duration
        previous = self.initial
        try:
            yield previous
            while not self.closed and time.monotonic() < end:
                disconnected = self.env.get('waitress.client_disconnected')
                if callable(disconnected) and disconnected(): break
                time.sleep(self.interval)
                if self.closed or time.monotonic() >= end: break
                if callable(disconnected) and disconnected(): break
                try:
                    # Revalidate revocation/role on every sample, not just stream opening.
                    role = self.app.role(self.env)
                    value = frame(self.app.bundled_snapshot(role))
                except Exception:
                    yield b'event: unavailable\ndata: {}\n\n'
                    break
                yield value if value != previous else b': heartbeat\n\n'
                previous = value
        finally:
            self.close()

    def close(self):
        if not self.closed:
            self.closed = True
            self.app.stream_slots.release()
