import json
from pathlib import Path
import tempfile
import unittest
import sys
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from hardware import HardwareInventory
from test_server import App, FakeCollector, call, config


class HardwareTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.root = Path(self.folder.name)
        self.inventory = HardwareInventory(self.root/'sys', self.root/'proc')

    def put(self, path, value=''):
        p = self.root/path
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(value, encoding='utf-8')
        return p

    def usb(self, node='1-2', product='Fixture USB peripheral'):
        base = 'sys/bus/usb/devices/'+node+'/'
        self.put(base+'idVendor', '1234')
        self.put(base+'idProduct', '5678')
        self.put(base+'product', product)
        self.put(base+'speed', '480')
        self.put(base+'authorized', '1')
        return base

    def test_authenticated_inventory_route_and_capability(self):
        app = App(config(), FakeCollector())
        self.assertEqual(call(app, '/v1/devices')['code'], 200)
        self.assertEqual(call(app, '/v1/devices', token=None)['code'], 401)
        self.assertTrue(call(app, '/v1/capabilities')['body']['deviceInventory'])

    def test_missing_hardware_is_empty_not_fabricated(self):
        inventory = self.inventory.collect()
        self.assertEqual(inventory['devices'], [])
        self.assertIsNone(inventory['board']['model'])
        self.assertIsNone(inventory['board']['cpuCores'])
        self.assertIsNone(inventory['board']['memoryBytes'])

    def test_board_model_memory_and_core_count(self):
        self.put('sys/firmware/devicetree/base/model', 'Fixture board\x00')
        self.put('proc/cpuinfo', 'processor : 0\nprocessor : 1\nSerial : never-export-cpu-id\n')
        self.put('proc/meminfo', 'MemTotal: 4096 kB\n')
        board = self.inventory.board()
        self.assertEqual(board['model'], 'Fixture board')
        self.assertEqual(board['cpuCores'], 2)
        self.assertEqual(board['memoryBytes'], 4096*1024)
        self.assertNotIn('never-export', json.dumps(board))

    def test_usb_enumeration_filters_root_hubs_and_interfaces(self):
        self.usb('usb1')
        self.usb()
        base = self.root/'sys/bus/usb/devices'
        # Colon interface names are valid on Linux but cannot be created on Windows.
        with patch('hardware.entries', return_value=[base/'usb1', base/'1-2:1.0', base/'1-2']):
            rows = self.inventory.usb()
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]['id'], 'usb:1-2')
        self.assertEqual(rows[0]['speedMbps'], 480)
        self.assertEqual(rows[0]['state'], 'detected')

    def test_usb_serials_are_not_read_and_blocked_is_not_ready(self):
        base = self.usb()
        self.put(base+'serial', 'never-export-usb-id')
        self.put(base+'authorized', '0')
        rows = self.inventory.usb()
        self.assertNotIn('never-export', json.dumps(rows))
        self.assertEqual(rows[0]['state'], 'blocked')

    def test_unplug_and_bad_ids_do_not_leave_phantom_devices(self):
        base = self.usb()
        (self.root/(base+'idVendor')).unlink()
        self.assertEqual(self.inventory.usb(), [])
        self.put(base+'idVendor', 'not-an-id')
        self.assertEqual(self.inventory.usb(), [])

    def test_descriptors_are_bounded_and_control_characters_removed(self):
        base = self.usb(product='Camera\x00\n\u202e'+('x'*200))
        row = self.inventory.usb()[0]
        self.assertEqual(len(row['name']), 96)
        self.assertNotIn('\u202e', row['name'])
        self.assertNotIn('\n', row['name'])
        self.put(base+'speed', 'nan')
        self.assertIsNone(self.inventory.usb()[0]['speedMbps'])

    def test_storage_uses_512_byte_sectors_and_omits_partitions(self):
        base = 'sys/class/block/mmcblk0/'
        self.put(base+'device/type', 'SD')
        self.put(base+'size', '8')
        self.put(base+'queue/logical_block_size', '4096')
        self.put(base+'device/serial', 'never-export-storage-id')
        self.put('sys/class/block/mmcblk0p1/partition', '1')
        rows = self.inventory.storage()
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]['capacityBytes'], 4096)
        self.assertEqual(rows[0]['bus'], 'sd')
        self.assertNotIn('never-export', json.dumps(rows))

    def test_only_hardware_network_interfaces_and_no_addresses(self):
        base = 'sys/class/net/wlan0/'
        self.put(base+'device/uevent')
        self.put(base+'wireless/state')
        self.put(base+'operstate', 'up')
        self.put(base+'address', 'private-network-identifier')
        self.put('sys/class/net/docker0/operstate', 'up')
        rows = self.inventory.network()
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]['state'], 'up')
        self.assertEqual(rows[0]['bus'], 'wifi')
        self.assertNotIn('private-network', json.dumps(rows))

    def test_bluetooth_registration_does_not_claim_pairing(self):
        self.put('sys/class/bluetooth/hci0/device/uevent')
        self.put('sys/class/bluetooth/hci0/address', 'private-bluetooth-identifier')
        base = self.root/'sys/class/bluetooth'
        with patch('hardware.entries', return_value=[base/'hci0', base/'hci0:peer']):
            rows = self.inventory.bluetooth()
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]['state'], 'detected')
        self.assertNotIn('private-bluetooth', json.dumps(rows))

    def test_device_count_is_bounded(self):
        for number in range(1, 70):
            self.usb('1-'+str(number))
        self.assertEqual(len(self.inventory.usb()), 64)


if __name__ == '__main__': unittest.main()
