"""Check shipped source and generated assets without requiring image libraries."""
import hashlib
import json
from pathlib import Path
import plistlib
import struct
import unittest

ROOT=Path(__file__).resolve().parents[2]


class BrandTests(unittest.TestCase):
    def test_opaque_1024_app_icons_match_manifest(self):
        folder=ROOT/'ios/Cubie/Assets.xcassets/AppIcon.appiconset'
        hashes=json.loads((ROOT/'brand/exports/manifest.json').read_text())
        self.assertEqual(len(hashes),3)
        for name,expected in hashes.items():
            data=(folder/name).read_bytes()
            self.assertEqual(data[:8],b'\x89PNG\r\n\x1a\n')
            self.assertEqual(struct.unpack('>II',data[16:24]),(1024,1024))
            self.assertEqual(data[25],2,'App icon must be RGB without alpha')
            self.assertEqual(hashlib.sha256(data).hexdigest(),expected)

    def test_three_icon_appearances(self):
        images=json.loads((ROOT/'ios/Cubie/Assets.xcassets/AppIcon.appiconset/Contents.json').read_text())['images']
        variants={item.get('appearances',[{'value':'light'}])[0]['value'] for item in images}
        self.assertEqual(variants,{'light','dark','tinted'})

    def test_privacy_manifest_declares_app_owned_preferences(self):
        manifest=plistlib.loads((ROOT/'ios/Cubie/PrivacyInfo.xcprivacy').read_bytes())
        self.assertFalse(manifest['NSPrivacyTracking'])
        self.assertEqual(manifest['NSPrivacyCollectedDataTypes'],[])
        self.assertEqual(manifest['NSPrivacyAccessedAPITypes'][0]['NSPrivacyAccessedAPITypeReasons'],['CA92.1'])

    def test_navigation_uses_native_tabs_not_custom_bar(self):
        source=(ROOT/'ios/Cubie/CubieApp.swift').read_text(encoding='utf-8')
        self.assertIn('if #available(iOS 26.0, *)',source)
        self.assertIn('.tabBarMinimizeBehavior(.never)',source)
        self.assertNotIn('AppTab.network',source)
        self.assertNotIn('UITabBar.appearance',source)
        self.assertNotIn('.toolbarBackground',source)

    def test_qr_only_binding_and_capability_driven_services(self):
        settings=(ROOT/'ios/Cubie/SettingsView.swift').read_text(encoding='utf-8')
        self.assertIn('PairingView()',settings)
        for removed in ['TextField(', 'SecureField(', 'Keychain.load()', 'device-reboot', '验证并连接']:
            self.assertNotIn(removed,settings)
        services=(ROOT/'ios/Cubie/ServicesView.swift').read_text(encoding='utf-8')
        self.assertIn('ServiceDetailView(serviceID:',services)
        self.assertIn('store.capabilities?.serviceControl == true && service.controllable',services)
        self.assertNotIn('ServiceEventsView',services)
        self.assertNotIn('查看事件',services)
        overview=(ROOT/'ios/Cubie/OverviewView.swift').read_text(encoding='utf-8')
        self.assertIn('if let power = board.powerWatts',overview)
        self.assertIn('if let rpm = board.fanRPM',overview)
        self.assertNotIn('历史曲线和通知',overview)

    def test_workflow_requires_modern_sdk(self):
        workflow=(ROOT/'.github/workflows/build-ios.yml').read_text()
        self.assertEqual(workflow.count('DEVELOPER_DIR: /Applications/Xcode_26.3.app/Contents/Developer'),2)
        self.assertIn('tools/select_simulator.py --legacy',workflow)
        self.assertIn('CoreNest-native-screenshots',workflow)


if __name__=='__main__':unittest.main()
