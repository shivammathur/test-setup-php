import hashlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zipfile

spec = importlib.util.spec_from_file_location('collector', 'collect-artifacts.py')
collector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(collector)


class CollectorTests(unittest.TestCase):
    def test_all_252_installer_artifacts_and_report_are_paginated(self):
        artifacts = [{'id': n} for n in range(253)]
        with patch.object(collector, 'api', side_effect=[json.dumps({'total_count': 253, 'artifacts': artifacts[i:i+100]}) for i in [0, 100, 200]]) as api:
            self.assertEqual(collector.inventory('owner/repo', '123'), artifacts)
            self.assertEqual(api.call_count, 3)
            self.assertTrue(api.call_args.args[0].endswith('page=3'))

    def test_incomplete_inventory_fails(self):
        with patch.object(collector, 'api', return_value=json.dumps({'total_count': 252, 'artifacts': []})):
            with self.assertRaises(ValueError):
                collector.inventory('owner/repo', '123')

    def test_checksum_and_paths_are_validated_before_extraction(self):
        for name, corrupt in [('summary.json', False), ('summary.json', True), ('../escape', False)]:
            with self.subTest(name=name, corrupt=corrupt), tempfile.TemporaryDirectory() as d:
                raw = io.BytesIO()
                with zipfile.ZipFile(raw, 'w') as z:
                    z.writestr(name, '{}')
                data = raw.getvalue()
                artifact = {'id': 1, 'name': 'installer-test', 'expired': False, 'digest': 'sha256:' + ('0'*64 if corrupt else hashlib.sha256(data).hexdigest())}
                with patch.object(collector, 'api', return_value=data):
                    if corrupt or name.startswith('..'):
                        with self.assertRaises(AssertionError):
                            collector.download('owner/repo', artifact, Path(d))
                        self.assertFalse((Path(d)/'installer-test').exists())
                    else:
                        collector.download('owner/repo', artifact, Path(d))
                        self.assertEqual((Path(d)/'installer-test'/name).read_text(), '{}')

    def test_rate_limit_and_timeout_are_retried(self):
        for failure in [subprocess.CompletedProcess([], 1, b'', b'secondary rate limit'), subprocess.TimeoutExpired('gh', 90)]:
            with self.subTest(failure=failure), patch.object(collector.subprocess, 'run', side_effect=[failure, subprocess.CompletedProcess([], 0, b'ok', b'')]) as run, patch.object(collector.time, 'sleep'):
                self.assertEqual(collector.api('repos/owner/repo/actions/artifacts/1/zip'), b'ok')
                self.assertEqual(run.call_count, 2)


unittest.main()
