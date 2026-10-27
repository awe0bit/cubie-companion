import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]/'tools'))
from publish_ota import verified_updates

class OTAPublisherTests(unittest.TestCase):
    def receipt(self, **extra):
        return dict(id='00000000-0000-4000-8000-000000000001',
                    group='00000000-0000-4000-8000-000000000002',
                    platform='ios', runtimeVersion='0.7.0', **extra)

    def test_account_fields_never_escape_receipt(self):
        data = self.receipt(owner='private-owner', dashboardUrl='https://private.example.com')
        value = verified_updates(json.dumps([data]), '0.7.0')
        self.assertNotIn('private', json.dumps(value))
        self.assertEqual(set(value[0]), {'id','group','runtime','platform'})

    def test_wrong_platform_or_runtime_rejected(self):
        for field, value in [('platform','android'), ('runtimeVersion','99.0.0')]:
            data = self.receipt(); data[field] = value
            self.assertRaises(ValueError, verified_updates, json.dumps([data]), '0.7.0')

    def test_missing_or_invalid_receipts_are_not_success(self):
        for raw in ['[]', '{}', 'not-json', json.dumps([{'id':'owner-profile'}])]:
            self.assertRaises((ValueError, TypeError), verified_updates, raw, '0.7.0')
