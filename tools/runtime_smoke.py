"""Bounded real simulator launch with diagnostic output; demo-only, no device credentials."""
import argparse
import json
from pathlib import Path
import subprocess
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--device', required=True)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    subprocess.run(['xcrun', 'simctl', 'install', args.device, str(args.app)], check=True)
    for route in ['overview', 'services', 'devices']:
        subprocess.run(['xcrun', 'simctl', 'terminate', args.device, 'org.corenest.app'], capture_output=True)
        log = args.output / (route + '-console.log')
        with log.open('wb') as stream:
            child = subprocess.Popen(['xcrun', 'simctl', 'launch', '--console-pty', args.device,
                'org.corenest.app', '--ui-testing', '--preview-tab', route, '--preview-appearance', 'light'],
                stdout=stream, stderr=subprocess.STDOUT)
            time.sleep(12)
            result = child.poll()
            subprocess.run(['xcrun', 'simctl', 'io', args.device, 'screenshot', str(args.output / (route + '.png'))], capture_output=True)
            subprocess.run(['xcrun', 'simctl', 'terminate', args.device, 'org.corenest.app'], capture_output=True)
            try: child.wait(timeout=10)
            except subprocess.TimeoutExpired:
                child.terminate()
                child.wait(timeout=5)
        if result is not None:
            print(log.read_text(errors='replace')[-16000:])
            raise RuntimeError('Embedded runtime terminated early: ' + route)
    print(json.dumps({'runtime_processes_survived_startup': 3, 'physical_device': False}))


if __name__ == '__main__':
    main()
