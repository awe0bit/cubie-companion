import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from server import App
from realtime import SnapshotStream, frame
from host_bridge import export_once
from test_server import config, FakeCollector, VIEWER, call


class RealtimeTests(unittest.TestCase):
    def setUp(self):
        self.app = App(config(), FakeCollector())
        self.addCleanup(self.app.ledger.connection.close)

    def open(self, **extra):
        result = {}
        env = {'PATH_INFO': '/v1/events', 'REQUEST_METHOD': 'GET', 'QUERY_STRING': '',
               'HTTP_AUTHORIZATION': 'Bearer ' + VIEWER, 'wsgi.input': io.BytesIO()}
        env.update(extra)
        stream = self.app(env, lambda status, headers: result.update(status=int(status.split()[0]), headers=dict(headers)))
        self.addCleanup(getattr(stream, 'close', lambda: None))
        return result, stream

    def test_auth_query_and_method_checked_before_stream(self):
        for extra, expected in [({'HTTP_AUTHORIZATION': ''}, 401), ({'QUERY_STRING': 'token=x'}, 400),
                                ({'REQUEST_METHOD': 'POST'}, 403)]:
            result, stream = self.open(**extra)
            self.assertEqual(result['status'], expected)
            self.assertNotIn(b'event:', b''.join(stream))

    def test_capacity_reserved_and_released_even_before_iteration(self):
        a, first = self.open(); b, second = self.open(); c, rejected = self.open()
        self.assertEqual([a['status'], b['status'], c['status']], [200, 200, 503])
        self.assertEqual(call(self.app)['code'], 200)
        first.close(); first.close()
        d, fourth = self.open()
        self.assertEqual(d['status'], 200)

    def test_adaptive_cadence_is_bounded_and_legacy_lease_is_preserved(self):
        response, legacy = self.open()
        self.assertEqual((legacy.duration, legacy.interval), (12, 1))
        legacy.close()
        for value in ['1', '5', '15']:
            response, stream = self.open(HTTP_X_CORENEST_INTERVAL=value)
            self.assertEqual(response['status'], 200)
            self.assertEqual((stream.duration, stream.interval), (90, int(value)))
            stream.close()
        for value in ['0', '2', '60', '-1', '1.0', 'x', '1,5']:
            response, stream = self.open(HTTP_X_CORENEST_INTERVAL=value)
            self.assertEqual(response['status'], 400)

    def test_slow_stream_still_releases_revoked_or_disconnected_clients_promptly(self):
        response, stream = self.open(HTTP_X_CORENEST_INTERVAL='15')
        iterator = iter(stream); next(iterator)
        with patch.object(self.app, 'role', side_effect=ValueError()), patch('realtime.time.sleep') as sleep:
            self.assertIn(b'unavailable', next(iterator))
            self.assertEqual(list(iterator), [])
            sleep.assert_called_once_with(1)
        self.assertTrue(stream.closed)

    def test_initial_event_is_viewer_filtered_json_and_unbuffered(self):
        response, stream = self.open()
        value = next(iter(stream))
        self.assertTrue(value.startswith(b'event: snapshot\ndata: '))
        bundle = json.loads(value.split(b'data: ', 1)[1])
        self.assertTrue(bundle['capabilities']['liveSnapshots'])
        self.assertFalse(bundle['capabilities']['ledControl'])
        self.assertEqual(response['headers']['X-Accel-Buffering'], 'no')
        self.assertEqual(response['headers']['Cache-Control'], 'no-store, no-transform')
        self.assertNotIn('Content-Length', response['headers'])
        self.assertNotIn(VIEWER.encode(), value)

    def test_disconnect_and_revocation_release_slots(self):
        response, stream = self.open(**{'waitress.client_disconnected': lambda: True})
        self.assertEqual(len(list(stream)), 1)
        self.assertTrue(stream.closed)
        response, stream = self.open()
        iterator = iter(stream)
        next(iterator)
        with patch.object(self.app, 'role', side_effect=ValueError()), patch('realtime.time.sleep'):
            self.assertEqual(next(iterator), b'event: unavailable\ndata: {}\n\n')
            self.assertEqual(list(iterator), [])
        self.assertTrue(stream.closed)

    def test_heartbeat_does_not_invent_new_measurements_and_frames_are_bounded(self):
        response, stream = self.open()
        iterator = iter(stream)
        next(iterator)
        with patch('realtime.time.sleep'):
            self.assertEqual(next(iterator), b': heartbeat\n\n')
        iterator.close()
        with self.assertRaises(ValueError): frame({'oversized': 'x' * 131072})

    def test_host_fast_sampling_does_not_repeat_slow_commands_each_second(self):
        collector = FakeCollector()
        counts = {'status': 0, 'services': 0, 'network': 0, 'devices': 0}
        for method, key in [('snapshot', 'status'), ('services', 'services'), ('network', 'network'), ('devices', 'devices')]:
            original = getattr(collector, method)
            def counted(original=original, key=key):
                counts[key] += 1
                return original()
            setattr(collector, method, counted)
        with tempfile.TemporaryDirectory() as folder, patch('host_bridge.time.monotonic', side_effect=[0, 1, 2, 5, 10]), \
             patch('management.broker_request', side_effect=OSError()):
            cache = {}
            for _ in range(5): export_once(collector, folder, cache)
        self.assertEqual(counts, {'status': 5, 'services': 3, 'network': 3, 'devices': 2})


if __name__ == '__main__': unittest.main()
