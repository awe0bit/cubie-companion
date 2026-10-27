"""Check shipped source and generated assets without requiring image libraries."""
import hashlib
import json
from pathlib import Path
import plistlib
import struct
import unittest

ROOT=Path(__file__).resolve().parents[2]


class BrandTests(unittest.TestCase):
    def test_isolated_runtime_has_device_and_simulator_loader_paths(self):
        project=(ROOT/'ios/Cubie.xcodeproj/project.pbxproj').read_text()
        self.assertEqual(project.count('LD_RUNPATH_SEARCH_PATHS = ("$(inherited)", "@executable_path/Frameworks")'),2)
        self.assertIn('CoreNestRuntimePackage-release',project)
        workflow=(ROOT/'.github/workflows/build-ios.yml').read_text()
        self.assertIn('tools/runtime_smoke.py',workflow)

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

    def test_prominent_button_theme_contrast(self):
        colors=json.loads((ROOT/'ios/Cubie/Assets.xcassets/AccentColor.colorset/Contents.json').read_text())['colors']
        def luminance(components):
            def linear(value):
                return value/12.92 if value <= 0.04045 else ((value+0.055)/1.055)**2.4
            return sum(linear(float(components[key]))*weight for key,weight in
                       [('red',0.2126),('green',0.7152),('blue',0.0722)])
        light,dark=[luminance(item['color']['components']) for item in colors]
        ink=luminance({'red':'0.07','green':'0.09','blue':'0.12'})
        self.assertGreaterEqual((light+0.05)/(ink+0.05),4.5)
        self.assertGreaterEqual((dark+0.05)/(ink+0.05),4.5)
        brand=(ROOT/'ios/Cubie/Brand.swift').read_text(encoding='utf-8')
        self.assertIn('onAccent = Color(red: 0.07, green: 0.09, blue: 0.12)',brand)
        for name in ['WelcomeView','SettingsView','PairingView']:
            source=(ROOT/f'ios/Cubie/{name}.swift').read_text(encoding='utf-8')
            self.assertIn('.foregroundStyle(Brand.onAccent)',source)

    def test_workflow_requires_modern_sdk(self):
        workflow=(ROOT/'.github/workflows/build-ios.yml').read_text()
        self.assertEqual(workflow.count('DEVELOPER_DIR: /Applications/Xcode_26.3.app/Contents/Developer'),3)
        self.assertIn('tools/select_simulator.py --legacy',workflow)
        self.assertIn('runtime: [modern, legacy]',workflow)
        self.assertIn('tools/select_simulator.py --prepare',workflow)
        self.assertIn('$TEST_DEVICE_ID',workflow)
        self.assertIn('CoreNest-native-screenshots',workflow)

    def test_ci_environment_is_explicit_and_deprecated_action_pins_are_gone(self):
        workflows=[(ROOT/'.github/workflows'/name).read_text() for name in ('build-ios.yml','ios-ota.yml')]
        for workflow in workflows:
            self.assertNotIn('ubuntu-latest',workflow)
            self.assertIn('ubuntu-24.04',workflow)
        build=workflows[0]
        for action in ['actions/cache@55cc8345863c7cc4c66a329aec7e433d2d1c52a9',
                       'actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333',
                       'docker/setup-qemu-action@99012661954931238ded8c8b007157a8430204e1',
                       'docker/setup-buildx-action@f87e5991a6d7451dcb8d9637bfbc97413f497069']:
            self.assertIn(action,build)


if __name__=='__main__':unittest.main()
