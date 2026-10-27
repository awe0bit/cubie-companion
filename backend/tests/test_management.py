import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from management import snapshot, execute, docker_records, cooldown_bucket, action_receipt
from test_server import config, call, FakeCollector, VIEWER, ADMIN
from server import App, ActionLedger, APIError

CID = 'a' * 64

class ManagedCollector(FakeCollector):
    def management(self):
        return {'sampledAt': '2026-10-27T00:00:00+00:00',
                'leds': [{'id': 'board:blue', 'mode': 'system', 'controllable': True}],
                'containers': [{'id': CID, 'controllable': True}],
                'ledControl': True, 'dockerControl': True, 'serviceControl': True}

class ManagementTests(unittest.TestCase):
    def setUp(self):
        self.operations = []
        self.app = App(config(ledControl=True, dockerControl=True), ManagedCollector(),
                       lambda payload: self.operations.append(payload) or {'accepted': True})

    def test_read_requires_auth_and_viewer_is_read_only(self):
        self.assertEqual(call(self.app, '/v1/management', token=None)['code'], 401)
        value = call(self.app, '/v1/management')['body']
        self.assertFalse(value['leds'][0]['controllable'])
        self.assertFalse(value['containers'][0]['controllable'])

    def test_single_roundtrip_snapshot_preserves_roles_and_partial_availability(self):
        value = call(self.app, '/v1/snapshot')['body']
        self.assertTrue(value['capabilities']['snapshotBundle'])
        self.assertFalse(value['capabilities']['ledControl'])
        self.assertFalse(value['management']['leds'][0]['controllable'])
        self.assertEqual(set(value), {'status', 'services', 'network', 'capabilities', 'management', 'inventory'})
        with patch.object(self.app.collector, 'management', side_effect=APIError(503, 'unavailable')):
            value = call(self.app, '/v1/snapshot', token=ADMIN)['body']
            self.assertIsNone(value['management'])
            self.assertFalse(value['capabilities']['ledControl'])
            self.assertFalse(value['capabilities']['serviceControl'])
            self.assertIsNotNone(value['status'])

    def test_capabilities_reflect_host_and_role(self):
        self.assertFalse(call(self.app, '/v1/capabilities')['body']['ledControl'])
        self.assertTrue(call(self.app, '/v1/capabilities', token=ADMIN)['body']['dockerControl'])

    def test_led_fixed_payload(self):
        result = call(self.app, '/v1/leds/board:blue/actions', 'POST', ADMIN, {'mode': 'off'})
        self.assertEqual(result['code'], 200)
        self.assertEqual(self.operations, [{'led': 'board:blue', 'mode': 'off'}])

    def test_led_cooldown_independent_and_dangerous_actions_still_protected(self):
        ledger = ActionLedger()
        with patch('server.time.time', return_value=1000):
            ledger.reserve('control1', 'restart')
            bucket, cooldown = cooldown_bucket({'led': 'board:blue', 'mode': 'off'})
            ledger.reserve('blue1', 'off', bucket, cooldown)
            with self.assertRaises(APIError): ledger.reserve('blue2', 'on', bucket, cooldown)
            ledger.reserve('green1', 'off', 'led:board:green', .2)
        with patch('server.time.time', return_value=1000.3):
            ledger.reserve('blue2', 'on', bucket, cooldown)
            with self.assertRaises(APIError): ledger.reserve('control2', 'stop')
            with self.assertRaises(APIError): ledger.reserve('blue1', 'off', bucket, cooldown)
        self.assertEqual(cooldown_bucket({'container': CID, 'action': 'stop'}), ('control', 10))
        self.assertEqual(cooldown_bucket({'led': [], 'mode': 'on'}), ('control', 10))
        ledger.connection.close()

    def test_readback_boundary_sanitizes_and_rejects_mismatched_led(self):
        payload = {'led': 'board:blue', 'mode': 'off'}
        result = {'accepted': True, 'private': 'never export', 'led': {
            'id': 'board:blue', 'mode': 'off', 'sampledAt': '2026-10-27T00:00:00+00:00'}}
        self.assertNotIn('private', action_receipt(result, payload))
        result['led']['id'] = 'board:green'
        self.assertRaises(ValueError, action_receipt, result, payload)

    def test_old_host_sample_does_not_undo_confirmed_led_readback(self):
        self.app.controller = lambda p: {'accepted': True, 'led': {
            'id': p['led'], 'mode': p['mode'], 'sampledAt': '2026-10-27T00:00:02+00:00'}}
        self.assertEqual(call(self.app, '/v1/leds/board:blue/actions', 'POST', ADMIN, {'mode': 'off'})['code'], 200)
        self.assertEqual(call(self.app, '/v1/management', token=ADMIN)['body']['leds'][0]['mode'], 'off')
        self.assertEqual(self.app.collector.management()['leds'][0]['mode'], 'system')

    def test_old_ledger_schema_migrates_without_losing_deduplication(self):
        import sqlite3, time
        with tempfile.TemporaryDirectory() as folder:
            path = str(Path(folder)/'ledger.sqlite3')
            connection = sqlite3.connect(path)
            connection.execute('CREATE TABLE requests(key TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, timestamp REAL NOT NULL)')
            connection.execute('INSERT INTO requests VALUES(?,?,?)', ('old', 'payload', time.time()))
            connection.commit(); connection.close()
            ledger = ActionLedger(path)
            with self.assertRaises(APIError) as caught: ledger.reserve('old', 'payload')
            self.assertEqual(caught.exception.code, 'request_already_seen')
            with self.assertRaises(APIError): ledger.reserve('new', 'payload')
            ledger.connection.close()

    def test_container_fixed_payload(self):
        result = call(self.app, '/v1/containers/'+CID+'/actions', 'POST', ADMIN, {'action': 'restart'})
        self.assertEqual(result['code'], 200)
        self.assertEqual(self.operations, [{'container': CID, 'action': 'restart'}])

    def test_viewer_cannot_control_led_or_docker(self):
        for path, body in [('/v1/leds/board:blue/actions', {'mode': 'off'}),
                           ('/v1/containers/'+CID+'/actions', {'action': 'stop'})]:
            self.assertEqual(call(self.app, path, 'POST', VIEWER, body)['code'], 403)
        self.assertEqual(self.operations, [])

    def test_unconfigured_features_fail_closed(self):
        self.app.config['dockerControl'] = False
        self.assertEqual(call(self.app, '/v1/containers/'+CID+'/actions', 'POST', ADMIN, {'action': 'stop'})['code'], 403)

    def test_injection_extra_fields_invalid_types_rejected(self):
        for body in [{'mode': []}, {'mode': 'off;reboot'}, {'mode': 'off', 'path': '/etc/shadow'}]:
            self.assertEqual(call(self.app, '/v1/leds/board:blue/actions', 'POST', ADMIN, body)['code'], 400)
        for ident in ['--all', '../etc', 'a'*12]:
            self.assertEqual(call(self.app, '/v1/containers/'+ident+'/actions', 'POST', ADMIN, {'action': 'stop'})['code'], 404)

    def test_docker_inventory_never_exports_private_fields(self):
        raw = json.dumps({'ID': CID, 'Names': 'demo-blog', 'Image': 'demo/image:1', 'State': 'running',
                          'Mounts': 'private', 'Ports': 'private', 'Labels': 'token=private'})
        items = docker_records(lambda _: raw)
        self.assertEqual(set(items[0]), {'id', 'name', 'image', 'state'})
        self.assertNotIn('private', json.dumps(items))

    def test_self_container_and_unlisted_container_protected(self):
        for name in ['corenest-server-1', 'other-app']:
            raw = json.dumps({'ID': CID, 'Names': name, 'Image': 'image', 'State': 'running'})
            cfg = {'dockerControl': True, 'containers': ['corenest-server-1']}
            with patch('management.subprocess.run') as run:
                self.assertRaises(ValueError, execute, {'container': CID, 'action': 'stop'}, cfg, runner=lambda _: raw)
                run.assert_not_called()

    def test_docker_mutation_uses_exact_id_not_user_name(self):
        raw = json.dumps({'ID': CID, 'Names': 'demo-blog', 'Image': 'image', 'State': 'running'})
        with patch('management.subprocess.run') as run:
            run.return_value.returncode = 0
            execute({'container': CID, 'action': 'restart'}, {'dockerControl': True, 'containers': ['demo-blog']}, runner=lambda _: raw)
            self.assertEqual(run.call_args.args[0], ['/usr/bin/docker', 'restart', '--time', '5', CID])

    def test_led_off_and_restore_preserve_known_system_trigger(self):
        with tempfile.TemporaryDirectory() as root:
            folder = Path(root)/'board-blue'; folder.mkdir()
            for name, value in [('trigger', 'none [heartbeat] timer'), ('brightness', '1'), ('max_brightness', '255')]:
                (folder/name).write_text(value)
            cfg = {'ledControl': True, 'leds': {'board-blue': {'name': 'Blue', 'trigger': 'heartbeat'}}}
            self.assertEqual(snapshot(cfg, root, lambda _: '')['leds'][0]['mode'], 'system')
            receipt = execute({'led': 'board-blue', 'mode': 'off'}, cfg, root)
            self.assertEqual(receipt['led']['mode'], 'off')
            self.assertEqual((folder/'brightness').read_text(), '0')
            (folder/'trigger').write_text('[none] heartbeat timer')
            receipt = execute({'led': 'board-blue', 'mode': 'system'}, cfg, root)
            self.assertEqual(receipt['led']['mode'], 'system')
            self.assertEqual((folder/'trigger').read_text(), 'heartbeat')
            self.assertRaises(ValueError, execute, {'led': '../../etc', 'mode': 'off'}, cfg, root)

    def test_unavailable_docker_does_not_invent_running_containers(self):
        def fail(_): raise OSError()
        result = snapshot({}, '/missing', fail)
        self.assertFalse(result['dockerAvailable'])
        self.assertEqual(result['containers'], [])
