"""Package an unsigned arm64 iPhoneOS app; never disguise a simulator as an IPA."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import stat
import struct
import zipfile


def macho_info(data):
    if len(data) < 32 or data[:4] != b'\xcf\xfa\xed\xfe':
        raise ValueError('Expected thin little-endian Mach-O 64')
    cpu, _, file_type, count, command_bytes = struct.unpack_from('<IIIII', data, 4)
    if cpu != 0x0100000C or file_type != 2:
        raise ValueError('Expected an arm64 executable')
    offset = 32
    end = offset + command_bytes
    if end > len(data):
        raise ValueError('Truncated load commands')
    platforms = []
    code_signature = False
    for _ in range(count):
        if offset + 8 > end:
            raise ValueError('Truncated load command')
        command, size = struct.unpack_from('<II', data, offset)
        if size < 8 or offset + size > end:
            raise ValueError('Invalid load command size')
        if command == 0x32:
            if size < 24:
                raise ValueError('Invalid build-version command')
            platforms.append(struct.unpack_from('<I', data, offset + 8)[0])
        if command == 0x1D:
            code_signature = True
        offset += size
    if platforms != [2]:
        raise ValueError('Expected iPhoneOS platform 2, not iOS Simulator')
    return {'architecture': 'arm64', 'platform': 'iPhoneOS',
            'machOHasCodeSignatureCommand': code_signature}


def verify_ipa(path):
    with zipfile.ZipFile(path) as archive:
        if archive.testzip() is not None:
            raise ValueError('Invalid IPA ZIP checksum')
        names = archive.namelist()
        if len(names) != len(set(names)):
            raise ValueError('Duplicate ZIP entries')
        root = 'Payload/Cubie.app/'
        for name in names:
            if not name.startswith(root) or '..' in name.split('/') or '\\' in name:
                raise ValueError('Unexpected IPA payload entry')
        if any('/_CodeSignature/' in name or name.endswith('/embedded.mobileprovision') for name in names):
            raise ValueError('Expected no bundle signature or provisioning profile')
        info = plistlib.loads(archive.read(root + 'Info.plist'))
        if info.get('CFBundleSupportedPlatforms') != ['iPhoneOS']:
            raise ValueError('Not an iPhoneOS application')
        if info.get('CFBundlePackageType') != 'APPL' or info.get('CFBundleExecutable') != 'Cubie':
            raise ValueError('Unexpected app bundle')
        native = macho_info(archive.read(root + 'Cubie'))
        return dict(native, bundleIdentifier=info['CFBundleIdentifier'],
                    version=info['CFBundleShortVersionString'], build=info['CFBundleVersion'],
                    minimumOS=info['MinimumOSVersion'], appleDistributionSigned=False,
                    provisioningProfileIncluded=False,
                    sha256=hashlib.sha256(Path(path).read_bytes()).hexdigest())


def package(app, output):
    if app.name != 'Cubie.app' or not app.is_dir():
        raise ValueError('Cubie.app is missing')
    if output.exists():
        raise ValueError('Refusing to overwrite an existing IPA')
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, 'x', compression=zipfile.ZIP_DEFLATED) as archive:
        for folder, directories, files in os.walk(app, followlinks=False):
            parent = Path(folder)
            for name in list(directories) + files:
                path = parent / name
                entry = 'Payload/Cubie.app/' + path.relative_to(app).as_posix()
                if path.is_symlink():
                    target = os.readlink(path)
                    resolved = path.resolve()
                    if app.resolve() not in resolved.parents:
                        raise ValueError('Symlink escapes app bundle')
                    metadata = zipfile.ZipInfo(entry)
                    metadata.create_system = 3
                    metadata.external_attr = (stat.S_IFLNK | 0o777) << 16
                    archive.writestr(metadata, target)
                elif path.is_file():
                    archive.write(path, entry)
    manifest = verify_ipa(output)
    manifest['sourceCommit'] = os.environ.get('GITHUB_SHA', 'local')
    (output.parent / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    output.with_suffix(output.suffix + '.sha256').write_text(manifest['sha256'] + '  ' + output.name + '\n')
    print(json.dumps(manifest))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', type=Path)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--verify', type=Path)
    args = parser.parse_args()
    if args.verify:
        print(json.dumps(verify_ipa(args.verify)))
    elif args.app and args.output:
        package(args.app, args.output)
    else:
        parser.error('Use --app and --output, or --verify')


if __name__ == '__main__': main()
