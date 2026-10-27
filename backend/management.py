"""Root-owned, fixed-operation broker helpers. Never expose the Docker socket to HTTP."""
import json
from pathlib import Path
import re
import socket
import subprocess
from datetime import datetime, timezone

SOCKET = '/run/corenest-control/control.sock'
STATES = {'created', 'running', 'paused', 'restarting', 'removing', 'exited', 'dead'}


def docker_records(runner=None):
    def execute(args):
        result = subprocess.run(['/usr/bin/docker'] + args, capture_output=True, text=True,
                                timeout=6, env={'PATH': '/usr/bin:/bin', 'LC_ALL': 'C'})
        if result.returncode: raise OSError('docker_unavailable')
        return result.stdout
    runner = runner or execute
    # Explicit fields only: no environment, mounts, IPs, ports, labels or logs leave the broker.
    raw = runner(['ps', '-a', '--no-trunc', '--format', '{{json .}}'])
    if len(raw) > 262144: raise ValueError('inventory_too_large')
    result = []
    for line in raw.splitlines()[:128]:
        entry = json.loads(line)
        ident, name, state = entry.get('ID', ''), entry.get('Names', ''), entry.get('State', '')
        if not re.fullmatch('[a-f0-9]{64}', ident): continue
        if not re.fullmatch('[A-Za-z0-9][A-Za-z0-9_.-]{0,127}', name): continue
        image = entry.get('Image', '')
        result.append({'id': ident, 'name': name, 'image': str(image)[:160],
                       'state': state if state in STATES else 'unknown'})
    return result


def protected_container(item):
    return item['name'].startswith(('corenest-', 'corenest_'))


def led_path(root, name):
    if not isinstance(name, str) or not re.fullmatch('[A-Za-z0-9:_-]{1,80}', name):
        raise ValueError('invalid_led')
    path = Path(root) / name
    if not path.is_dir(): raise ValueError('led_unavailable')
    return path


def led_state(path):
    triggers = (path / 'trigger').read_text().split()
    selected = next((x[1:-1] for x in triggers if x.startswith('[')),
                    triggers[0] if len(triggers) == 1 else 'none')
    brightness = int((path / 'brightness').read_text())
    return ('on' if brightness else 'off') if selected == 'none' else 'system'


def cooldown_bucket(payload):
    if (isinstance(payload, dict) and set(payload) == {'led', 'mode'}
            and isinstance(payload['led'], str)
            and re.fullmatch('[A-Za-z0-9:_-]{1,80}', payload['led'])
            and isinstance(payload['mode'], str) and payload['mode'] in {'on', 'off', 'system'}):
        return 'led:' + payload['led'], 0.2
    return 'control', 10


def action_receipt(result, payload):
    """Only fixed, matching readback fields may cross the privileged boundary."""
    if not isinstance(result, dict) or result.get('accepted') is not True:
        raise ValueError('operation_rejected')
    receipt = {'accepted': True}
    if 'led' in payload:
        led = result.get('led')
        if (not isinstance(led, dict) or set(led) != {'id', 'mode', 'sampledAt'}
                or led['id'] != payload['led'] or led['mode'] not in ('on', 'off', 'system')
                or not isinstance(led['sampledAt'], str) or len(led['sampledAt']) > 40):
            raise ValueError('invalid_led_readback')
        datetime.fromisoformat(led['sampledAt'].replace('Z', '+00:00'))
        receipt['led'] = {key: led[key] for key in ('id', 'mode', 'sampledAt')}
    return receipt


def snapshot(config, sysroot='/sys/class/leds', runner=None):
    leds = []
    for name, options in config.get('leds', {}).items():
        try:
            path = led_path(sysroot, name)
            leds.append({'id': name, 'name': str(options.get('name', name))[:80],
                         'mode': led_state(path),
                         'controllable': config.get('ledControl') is True})
        except (OSError, ValueError, TypeError): continue
    try:
        containers = docker_records(runner)
        allowed = config.get('containers', [])
        for item in containers:
            item['controllable'] = (config.get('dockerControl') is True and item['name'] in allowed
                                    and not protected_container(item))
        docker_available = True
    except (OSError, ValueError, TypeError, subprocess.SubprocessError):
        containers, docker_available = [], False
    return {'sampledAt': datetime.now(timezone.utc).isoformat(), 'leds': leds,
            'containers': containers, 'dockerAvailable': docker_available,
            'serviceControl': config.get('serviceControl') is True,
            'ledControl': config.get('ledControl') is True and bool(leds),
            'dockerControl': config.get('dockerControl') is True and docker_available}


def execute(payload, config, sysroot='/sys/class/leds', runner=None):
    if not isinstance(payload, dict): raise ValueError('invalid_operation')
    if set(payload) == {'led', 'mode'} and config.get('ledControl') is True:
        name, mode = payload['led'], payload['mode']
        if not isinstance(name, str) or name not in config.get('leds', {}): raise ValueError('led_protected')
        if not isinstance(mode, str) or mode not in {'on', 'off', 'system'}: raise ValueError('invalid_mode')
        path = led_path(sysroot, name)
        if mode == 'system':
            trigger = config['leds'][name].get('trigger', 'none')
            if trigger not in (path / 'trigger').read_text().replace('[', '').replace(']', '').split():
                raise ValueError('trigger_unavailable')
            (path / 'trigger').write_text(trigger)
        else:
            maximum = int((path / 'max_brightness').read_text())
            (path / 'trigger').write_text('none')
            (path / 'brightness').write_text(str(maximum if mode == 'on' else 0))
        return {'accepted': True, 'led': {'id': name, 'mode': led_state(path),
                'sampledAt': datetime.now(timezone.utc).isoformat()}}
    if set(payload) == {'container', 'action'} and config.get('dockerControl') is True:
        ident, action = payload['container'], payload['action']
        if not isinstance(ident, str) or not re.fullmatch('[a-f0-9]{64}', ident): raise ValueError('invalid_container')
        if not isinstance(action, str) or action not in {'start', 'stop', 'restart'}: raise ValueError('invalid_action')
        item = next((x for x in docker_records(runner) if x['id'] == ident), None)
        if not item or protected_container(item) or item['name'] not in config.get('containers', []):
            raise ValueError('container_protected')
        # Recheck ID + name immediately before action; names supplied by HTTP never become argv.
        args = ['/usr/bin/docker', action]
        if action in {'stop', 'restart'}: args += ['--time', '5']
        result = subprocess.run(args + [ident], capture_output=True, timeout=12,
                                env={'PATH': '/usr/bin:/bin', 'LC_ALL': 'C'})
        return {'accepted': result.returncode == 0}
    raise ValueError('operation_not_allowed')


def broker_request(payload, path=SOCKET):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as channel:
        channel.settimeout(18)
        channel.connect(path)
        channel.sendall(json.dumps(payload).encode() + b'\n')
        data = b''
        while b'\n' not in data and len(data) <= 131072:
            block = channel.recv(16384)
            if not block: break
            data += block
        if len(data) > 131072 or not data.endswith(b'\n'): raise ValueError('invalid_broker_response')
        return json.loads(data)
