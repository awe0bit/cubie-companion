import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from management import snapshot, execute, docker_records
from test_server import config, call, FakeCollector, VIEWER, ADMIN
from server import App

CID = 'a' * 64

class ManagedCollector(FakeCollector):
    def management(self):
        return {'leds': [{'id': 'board:blue', 'mode': 'system', 'controllable': True}],
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

    def test_capabilities_reflect_host_and_role(self):
        self.assertFalse(call(self.app, '/v1/capabilities')['body']['ledControl'])
        self.assertTrue(call(self.app, '/v1/capabilities', token=ADMIN)['body']['dockerControl'])

    def test_led_fixed_payload(self):
        result = call(self.app, '/v1/leds/board:blue/actions', 'POST', ADMIN, {'mode': 'off'})
        self.assertEqual(result['code'], 200)
        self.assertEqual(self.operations, [{'led': 'board:blue', 'mode': 'off'}])

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
            execute({'led': 'board-blue', 'mode': 'off'}, cfg, root)
            self.assertEqual((folder/'brightness').read_text(), '0')
            (folder/'trigger').write_text('[none] heartbeat timer')
            execute({'led': 'board-blue', 'mode': 'system'}, cfg, root)
            self.assertEqual((folder/'trigger').read_text(), 'heartbeat')
            self.assertRaises(ValueError, execute, {'led': '../../etc', 'mode': 'off'}, cfg, root)

    def test_unavailable_docker_does_not_invent_running_containers(self):
        def fail(_): raise OSError()
        result = snapshot({}, '/missing', fail)
        self.assertFalse(result['dockerAvailable'])
        self.assertEqual(result['containers'], [])
