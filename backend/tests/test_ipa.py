"""Packaging tests use synthetic Mach-O headers, never claim an app was built."""
from pathlib import Path
import plistlib
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'tools'))
from package_ipa import macho_info, package, verify_ipa


def executable(platform=2):
    return struct.pack('<IIIIIIII', 0xFEEDFACF, 0x0100000C, 0, 2, 1, 24, 0, 0) + struct.pack('<IIIIII', 0x32, 24, platform, 0, 0, 0)


class IPATests(unittest.TestCase):
    def test_device_binary_platform(self):
        self.assertEqual(macho_info(executable())['platform'], 'iPhoneOS')

    def test_simulator_rejected(self):
        self.assertRaises(ValueError, macho_info, executable(7))

    def test_truncated_binary_rejected(self):
        self.assertRaises(ValueError, macho_info, executable()[:20])

    def test_package_structure_and_hash(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            app = root / 'Cubie.app'
            app.mkdir()
            (app/'Cubie').write_bytes(executable())
            info = {'CFBundleSupportedPlatforms':['iPhoneOS'],'CFBundlePackageType':'APPL',
                    'CFBundleExecutable':'Cubie','CFBundleIdentifier':'org.corenest.app',
                    'CFBundleShortVersionString':'0.1.0','CFBundleVersion':'1','MinimumOSVersion':'17.0'}
            (app/'Info.plist').write_bytes(plistlib.dumps(info))
            output=root/'artifacts/Cubie-unsigned.ipa'
            package(app,output)
            result=verify_ipa(output)
            self.assertEqual(result['architecture'],'arm64')
            self.assertFalse(result['provisioningProfileIncluded'])
            self.assertTrue(output.with_suffix('.ipa.sha256').exists())
            self.assertRaises(ValueError,package,app,output)


if __name__=='__main__':unittest.main()
