"""Publish to EAS without leaking Expo account names, dashboard URLs or raw CLI logs."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]

def verified_updates(raw, runtime):
    data = json.loads(raw)
    items = data if isinstance(data, list) else data.get('updates', [])
    if not items: raise ValueError('missing_update_receipt')
    receipts = []
    for item in items:
        if item.get('platform') != 'ios' or item.get('runtimeVersion') != runtime:
            raise ValueError('update_receipt_mismatch')
        ident, group = item.get('id', ''), item.get('group', '')
        if not all(isinstance(v, str) and re.fullmatch('[a-f0-9-]{36}', v) for v in (ident, group)):
            raise ValueError('invalid_receipt')
        receipts.append({'id': ident, 'group': group, 'runtime': runtime, 'platform': 'ios'})
    return receipts

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--channel', required=True, choices=['preview', 'production'])
    args = parser.parse_args()
    if not os.environ.get('EXPO_TOKEN') or not os.environ.get('CORENEST_EXPO_PROJECT_ID'):
        raise SystemExit('Dedicated OTA authorization missing; nothing published.')
    runtime = (ROOT/'runtime/runtime-version.txt').read_text().strip()
    if not re.fullmatch(r'\d+\.\d+\.\d+', runtime): raise SystemExit('Invalid runtime.')
    source = subprocess.check_output(['git','rev-parse','--short','HEAD'], cwd=ROOT, text=True).strip()
    cli = 'npx.cmd' if os.name == 'nt' else 'npx'
    result = subprocess.run([cli, '--yes', 'eas-cli@25.3.0', 'update', '--channel', args.channel,
        '--environment', args.channel, '--platform', 'ios', '--message', 'CoreNest '+source,
        '--skip-bundler', '--input-dir', 'dist', '--json', '--non-interactive'],
        cwd=ROOT/'runtime', capture_output=True, text=True, encoding='utf-8', timeout=600)
    if result.returncode:
        print(json.dumps({'ota_publish':'not_confirmed','channel':args.channel,'exitCode':result.returncode,
                          'note':'Raw CLI output suppressed for account privacy. Inspect privately before retry.'}))
        raise SystemExit(1)
    try: receipts = verified_updates(result.stdout, runtime)
    except (ValueError, TypeError, KeyError):
        print(json.dumps({'ota_publish':'receipt_not_confirmed','note':'Do not retry automatically; update may exist.'}))
        raise SystemExit(1)
    print(json.dumps({'ota_publish':'published','channel':args.channel,'source':source,'updates':receipts}))

if __name__ == '__main__':
    try: main()
    except (OSError, subprocess.SubprocessError):
        print('{"ota_publish":"not_confirmed","note":"Operator check required; raw logs suppressed."}')
        sys.exit(1)
