#!/usr/bin/env python3
import importlib.util
import json
from pathlib import Path
import unittest

root = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('notes', root / 'scripts/release-notes.py')
notes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(notes)


class ReleaseNotes(unittest.TestCase):
    def test_versions(self):
        for tag in ['v0.1.0-alpha.1', 'v1.0.0-beta.2', 'v1.0.0-rc.1', 'v1.0.0']:
            self.assertEqual(notes.validate_tag(tag), tag)
        for tag in ['ubuntu26-build-10-1', 'v01.0.0', 'v1.0.0-alpha.01', 'v1.0', 'v1.0.0/../../x', 'v1.0.0\n']:
            with self.assertRaises(ValueError):
                notes.validate_tag(tag)

    def test_current_batch_does_not_inherit_old_acceptance(self):
        text = notes.render('v0.1.0-alpha.1', 'owner/repo', 'a'*40, 'b'*64,
                            json.loads((root / 'config/release/notes.json').read_text()))
        for title in ['新增功能', '问题修复', '体验优化', '其他变更', 'New Features', 'Bug Fixes', 'Improvements', 'Other Changes']:
            self.assertIn('### '+title, text)
        self.assertIn('Physical acceptance of this batch is pending', text)
        self.assertIn('实机验收尚未完成', text)
        self.assertIn('### 来源与授权', text)
        self.assertIn('### Origin and Licensing', text)
        self.assertIn('/blob/' + 'a'*40 + '/docs/COMMERCIAL-USE.md', text)
        self.assertIn('do not certify image debranding', text)
        self.assertIn('ARM64 Linux images', text)
        self.assertNotIn('Provide Ubuntu 26.04', text)
        self.assertNotIn('forgejo', text.lower())
        self.assertNotIn('ubuntu26-build-', text)
        self.assertNotIn('Contributors', text)  # Supplied by real GitHub release notes, never invented.

    def test_invalid_identity(self):
        with self.assertRaises(ValueError):
            notes.render('v0.1.0', 'owner/repo', 'short', 'b'*64, {})


if __name__ == '__main__':
    unittest.main()
