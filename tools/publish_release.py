"""Publish only a verified, unsigned device IPA; never overwrite an existing release."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
from package_ipa import verify_ipa


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--artifact', type=Path, required=True)
    args = parser.parse_args()
    folder = args.artifact.resolve()
    ipa = folder / 'CoreNest-unsigned.ipa'
    verified = verify_ipa(ipa)
    manifest = json.loads((folder / 'manifest.json').read_text())
    assert manifest['sourceCommit'] == os.environ['GITHUB_SHA'], 'source_mismatch'
    assert manifest['sha256'] == verified['sha256'], 'hash_mismatch'
    version = verified['version']
    import re
    assert re.fullmatch(r'\d+\.\d+\.\d+', version), 'invalid_release_version'
    tag = 'v' + version
    repo = 'awe0bit/cubie-companion'
    # Explicit publication must never silently replace a package already installed by users.
    exists = subprocess.run(['gh', 'release', 'view', tag, '--repo', repo], capture_output=True)
    assert exists.returncode != 0, 'release_exists_refusing_overwrite'
    named = folder / ('CoreNest-' + version + '-iOS-unsigned.ipa')
    shutil.copyfile(ipa, named)
    sums = folder / 'SHA256SUMS.txt'
    sums.write_text(hashlib.sha256(named.read_bytes()).hexdigest() + '  ' + named.name + '\n')
    subprocess.run(['gh', 'release', 'create', tag, '--repo', repo,
                    '--target', manifest['sourceCommit'], '--title', 'CoreNest ' + version,
                    '--notes', 'Native iOS control console. Unsigned IPA: sign with your own valid identity. '
                    'Pages support OTA only after independent Expo project authorization. '
                    'No board or Apple credentials are included.', str(named), str(sums), str(folder / 'manifest.json')], check=True)


if __name__ == '__main__':
    main()
