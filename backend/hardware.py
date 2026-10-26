"""Bounded, read-only Linux hardware inventory. No scans, serials or addresses."""
from datetime import datetime, timezone
from itertools import islice
from pathlib import Path
import platform
import re
import unicodedata


def text(path, limit=96):
    try:
        with Path(path).open('rb') as stream:
            raw = stream.read(512).decode('utf-8', 'replace')
        return ''.join(c for c in raw if not unicodedata.category(c).startswith('C')).strip()[:limit] or None
    except OSError:
        return None


def integer(path, maximum=2**63-1):
    raw = text(path)
    if raw and re.fullmatch(r'[0-9]{1,19}', raw):
        value = int(raw)
        if value <= maximum:
            return value
    return None


def entries(path):
    try:
        return sorted(islice(Path(path).iterdir(), 512), key=lambda p: p.name)
    except OSError:
        return []


def driver(path):
    link = Path(path)/'driver'
    try:
        if link.is_symlink():
            name = link.resolve(strict=True).name
            if re.fullmatch(r'[A-Za-z0-9_.-]{1,96}', name):
                return name
    except (OSError, RuntimeError):
        pass
    return None


class HardwareInventory:
    def __init__(self, sys='/sys', proc='/proc'):
        self.sys, self.proc = Path(sys), Path(proc)

    def board(self):
        model = text(self.sys/'firmware/devicetree/base/model') or text(self.proc/'device-tree/model')
        cores = 0
        memory = None
        try:
            with (self.proc/'cpuinfo').open(encoding='utf-8') as stream:
                cpu = stream.read(1024*1024)
            for line in cpu.splitlines():
                if re.match(r'^processor\s*:', line):
                    cores += 1
        except OSError:
            pass
        try:
            with (self.proc/'meminfo').open(encoding='utf-8') as stream:
                mem = stream.read(65536)
            for line in mem.splitlines():
                match = re.fullmatch(r'MemTotal:\s+([0-9]{1,13}) kB', line.strip())
                if match:
                    memory = int(match[1])*1024
                    break
        except OSError:
            pass
        return {'model': model, 'architecture': platform.machine()[:64],
                'kernel': platform.release()[:96], 'cpuCores': cores or None, 'memoryBytes': memory}

    def usb(self):
        result = []
        root = self.sys/'bus/usb/devices'
        for p in entries(root):
            # Root hubs and interface nodes are not additional physical USB devices.
            if not re.fullmatch(r'[0-9]+-[0-9]+(?:\.[0-9]+)*', p.name):
                continue
            vendor, product = text(p/'idVendor'), text(p/'idProduct')
            if not vendor or not product or not re.fullmatch(r'[0-9a-fA-F]{4}', vendor) or not re.fullmatch(r'[0-9a-fA-F]{4}', product):
                continue
            speed = text(p/'speed')
            speed = float(speed) if speed and re.fullmatch(r'[0-9]{1,5}(?:\.[0-9]{1,3})?', speed) else None
            names = set()
            for interface in islice(root.glob(p.name+':*'), 32):
                name = driver(interface)
                if name:
                    names.add(name)
            result.append({'id': 'usb:'+p.name, 'category': 'usb', 'name': text(p/'product') or 'USB 设备',
                           'node': p.name, 'bus': 'usb', 'driver': ', '.join(sorted(names))[:96] or None,
                           'state': 'blocked' if text(p/'authorized') == '0' else 'detected',
                           'vendorID': vendor.lower(), 'productID': product.lower(), 'speedMbps': speed})
            if len(result) == 64:
                break
        return result

    def storage(self):
        result = []
        for p in entries(self.sys/'class/block'):
            if not re.fullmatch(r'(?:sd[a-z]+|mmcblk[0-9]+|nvme[0-9]+n[0-9]+|vd[a-z]+)', p.name):
                continue
            if (p/'partition').exists() or not (p/'device').exists():
                continue
            kind = text(p/'device/type')
            bus = 'sd' if kind == 'SD' else 'mmc' if kind == 'MMC' else 'nvme' if p.name.startswith('nvme') else 'block'
            if any(re.fullmatch(r'usb[0-9]+', part) for part in p.resolve().parts):
                bus = 'usb'
            sectors = integer(p/'size', (2**63-1)//512)
            result.append({'id': 'storage:'+p.name, 'category': 'storage',
                           'name': text(p/'device/model') or {'sd': 'SD 卡', 'mmc': 'MMC 存储', 'nvme': 'NVMe 存储'}.get(bus, '存储设备'),
                           'node': '/dev/'+p.name, 'bus': bus, 'driver': driver(p/'device'), 'state': 'detected',
                           # Linux sysfs size is in 512-byte sectors, not logical_block_size.
                           'capacityBytes': sectors*512 if sectors is not None else None,
                           'removable': text(p/'removable') == '1'})
            if len(result) == 32:
                break
        return result

    def network(self):
        result = []
        for p in entries(self.sys/'class/net'):
            if not re.fullmatch(r'[A-Za-z0-9_.-]{1,64}', p.name) or p.name == 'lo' or not (p/'device').exists():
                continue
            state = text(p/'operstate')
            result.append({'id': 'network:'+p.name, 'category': 'network', 'name': p.name, 'node': p.name,
                           'bus': 'wifi' if (p/'wireless').exists() else 'ethernet' if text(p/'type') == '1' else 'network',
                           'driver': driver(p/'device'),
                           'state': state if state in {'up', 'down', 'dormant', 'lowerlayerdown', 'notpresent'} else 'unknown',
                           'speedMbps': integer(p/'speed', 10_000_000)})
            if len(result) == 32:
                break
        return result

    def bluetooth(self):
        result = []
        for p in entries(self.sys/'class/bluetooth'):
            if re.fullmatch(r'hci[0-9]{1,3}', p.name):
                # hci registration does not prove the radio is powered, paired or usable.
                result.append({'id': 'bluetooth:'+p.name, 'category': 'bluetooth', 'name': '蓝牙控制器',
                               'node': p.name, 'bus': 'bluetooth', 'driver': driver(p/'device'), 'state': 'detected'})
            if len(result) == 16:
                break
        return result

    def collect(self):
        return {'sampledAt': datetime.now(timezone.utc).isoformat(), 'board': self.board(),
                'devices': self.usb()+self.storage()+self.network()+self.bluetooth()}
