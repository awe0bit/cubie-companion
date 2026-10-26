"""Exercise broker framing and peer authorization without root or a real Docker daemon."""
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest.mock import MagicMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import control

class BrokerTests(unittest.TestCase):
    def exchange(self, uid, payload, config=None):
        cfg = {'apiUID': 10001, 'allowedUIDs': [10001, 996], 'ledControl': True}
        if config: cfg.update(config)
        client = MagicMock()
        client.getsockopt.return_value = struct.pack('3i', 42, uid, 996)
        client.recv.return_value = json.dumps(payload).encode()+b'\n'
        listener = MagicMock()
        listener.accept.side_effect = [(client, None), StopIteration]
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)/'config.json'; path.write_text(json.dumps(cfg))
            with patch('sys.argv', ['control.py','--config',str(path)]), \
                 patch.dict(control.os.environ, {'LISTEN_PID': str(control.os.getpid()), 'LISTEN_FDS': '1'}), \
                 patch.object(control.socket, 'fromfd', return_value=listener, create=True), \
                 patch.object(control.socket, 'AF_UNIX', 1, create=True), \
                 patch.object(control.socket, 'SO_PEERCRED', 17, create=True), \
                 patch('management.snapshot', return_value={'leds': [], 'containers': []}) as read, \
                 patch('management.execute', return_value={'accepted': True}) as write:
                with self.assertRaises(StopIteration): control.main()
                return json.loads(client.sendall.call_args.args[0]), read.call_count, write.call_count

    def test_telemetry_peer_can_read_but_cannot_mutate(self):
        response, reads, writes = self.exchange(996, {'action':'snapshot'})
        self.assertEqual((reads,writes),(1,0))
        response, reads, writes = self.exchange(996, {'led':'board:blue','mode':'off'})
        self.assertEqual(response,{'accepted':False})
        self.assertEqual((reads,writes),(0,0))

    def test_unrecognized_peer_cannot_even_read(self):
        response, reads, writes = self.exchange(12345, {'action':'snapshot'})
        self.assertEqual(response,{'accepted':False})
        self.assertEqual((reads,writes),(0,0))

    def test_api_peer_fixed_mutation_is_forwarded(self):
        response, reads, writes = self.exchange(10001, {'led':'board:blue','mode':'off'})
        self.assertEqual(response,{'accepted':True})
        self.assertEqual((reads,writes),(0,1))

    def test_non_object_payload_is_denied(self):
        response, _, writes = self.exchange(10001, ['led','off'])
        self.assertEqual(response,{'accepted':False})
        self.assertEqual(writes,0)
