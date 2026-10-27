"""Fail-closed change classification: JS-only updates must not generate native/server packages."""
import json
import os
from pathlib import Path
import re
import subprocess

NATIVE_FILES = {'runtime/package.json', 'runtime/package-lock.json', 'runtime/runtime-version.txt', 'runtime/eas.json', 'runtime/app.json',
                'runtime/app.config.js', 'runtime/index.ts', 'runtime/babel.config.js', 'runtime/metro.config.js',
                'tools/package_ipa.py', 'tools/runtime_smoke.py', 'tools/select_simulator.py',
                'tools/capture_screenshots.py'}


def classify(paths, manual=False, unknown=False):
    native = manual or unknown or any(path.startswith(('ios/', 'runtime/plugins/', 'runtime/modules/', 'runtime/patches/'))
                                      or path in NATIVE_FILES for path in paths)
    server = unknown or any((path.startswith('backend/') and not path.startswith('backend/tests/'))
                           or path.startswith('deploy/') or path in {'Dockerfile', '.dockerignore', 'compose.yaml'} for path in paths)
    runtime = native or any(path.startswith('runtime/') for path in paths)
    content = any(path.startswith(('runtime/src/', 'runtime/assets/')) for path in paths)
    return {'native': bool(native), 'server': bool(server), 'runtime': bool(runtime),
            'ota': bool(content and not native and not server)}


def main():
    event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())
    manual = os.environ.get('GITHUB_EVENT_NAME') == 'workflow_dispatch'
    base = event.get('pull_request', {}).get('base', {}).get('sha') or event.get('before', '')
    head = os.environ.get('GITHUB_SHA', '')
    paths, unknown = [], False
    try:
        if not all(re.fullmatch(r'[0-9a-f]{40}', value) and value != '0' * 40 for value in (base, head)):
            raise ValueError('missing_diff_boundary')
        raw = subprocess.check_output(['git', 'diff', '--name-only', '-z', base, head], stderr=subprocess.DEVNULL)
        paths = [value.decode('utf-8') for value in raw.split(b'\0') if value]
    except (ValueError, OSError, subprocess.SubprocessError):
        unknown = True
    result = classify(paths, manual, unknown)
    with open(os.environ['GITHUB_OUTPUT'], 'a', encoding='utf-8') as output:
        for key, value in result.items(): output.write(key + '=' + str(value).lower() + '\n')
    print(json.dumps({'change_scope': result, 'changed_files': len(paths), 'diff_fallback': unknown}))


if __name__ == '__main__': main()
