import importlib.util
import os
from pathlib import Path
import stat
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('runner_pool', Path(__file__).parents[1] / 'scripts/runner_pool.py')
pool = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pool)


class PoolTests(unittest.TestCase):
    def test_matrix_matches_real_host_architectures(self):
        items = pool.matrix('runner-pool-example', 2, 1)['include']
        self.assertEqual([i['os'] for i in items], ['ubuntu-24.04', 'ubuntu-24.04', 'ubuntu-24.04-arm'])
        self.assertEqual(len({(i['arch'], i['slot']) for i in items}), 3)

    def test_capacity_and_environment_are_bounded(self):
        self.assertEqual(len(pool.matrix('runner-pool-test', 20, 10)['include']), 30)
        for counts in [(0, 0), (-1, 2), (30, 1), (1, 'two')]:
            with self.assertRaises(ValueError):
                pool.matrix('runner-pool-test', *counts)
        with self.assertRaises(ValueError):
            pool.matrix('production', 1, 1)

    def test_ubuntu_hosts_preserve_native_compatibility_test_baselines(self):
        for version in ('22.04', '24.04', '26.04'):
            host = 'ubuntu-' + version
            items = pool.matrix('runner-pool-ubuntu', 1, 1, host)['include']
            self.assertEqual([i['os'] for i in items], [host, host + '-arm'])
            for arch, machine in [('x64', 'x86_64'), ('arm64', 'aarch64')]:
                pool.validate_host(host, arch, 'Linux', machine, version)
                for other in ('22.04', '24.04', '26.04'):
                    if other != version:
                        with self.assertRaises(ValueError):
                            pool.validate_host(host, arch, 'Linux', machine, other)
        self.assertEqual(pool.matrix('runner-pool-approval', 1, 0, 'ubuntu-latest')['include'][0]['os'],
                         'ubuntu-latest')
        with self.assertRaises(ValueError):
            pool.matrix('runner-pool-approval', 0, 1, 'ubuntu-latest')
        with self.assertRaises(ValueError):
            pool.validate_host('ubuntu-latest', 'x64', 'Linux', 'x86_64', '26.04')

    def test_macos_labels_match_the_actual_os_and_architecture(self):
        items = pool.matrix('runner-pool-mac', 0, 5, 'macos-14')['include']
        self.assertEqual(len(items), 5)
        self.assertTrue(all(i['os'] == 'macos-14' and i['arch'] == 'arm64' for i in items))
        self.assertEqual([i['os'] for i in pool.matrix('runner-pool-mac', 1, 1, 'macos-15')['include']],
                         ['macos-15-intel', 'macos-15'])
        self.assertEqual(pool.host_spec('macos-14', 'arm64')['package'], 'osx')
        self.assertEqual(pool.host_spec('macos-14', 'arm64')['system'], 'macOS')
        with self.assertRaises(ValueError):
            pool.matrix('runner-pool-mac', 1, 0, 'macos-14')
        with self.assertRaises(ValueError):
            pool.matrix('runner-pool-mac', 0, 1, 'macos-27')

    def test_ubuntu_sf_labels_keep_native_images_and_do_not_take_unsuffixed_jobs(self):
        items = pool.matrix('runner-pool-sf', 10, 10, 'ubuntu-24.04')['include']
        self.assertEqual(len(items), 20)
        for arch, image, label in [('x64', 'ubuntu-24.04', 'ubuntu-24-sf'),
                                   ('arm64', 'ubuntu-24.04-arm', 'ubuntu-24-arm-sf')]:
            self.assertEqual(pool.host_spec('ubuntu-24.04', arch)['image'], image)
            labels = pool.runner_labels('ubuntu-24.04', arch, 'sf')
            self.assertEqual(labels, ['self-hosted', 'Linux', 'X64' if arch == 'x64' else 'ARM64', label])
            self.assertNotIn(image, labels)
        for platform, suffix in [('ubuntu-22.04', 'sf'), ('macos-15', 'sf'), ('ubuntu-24.04', 'other')]:
            with self.assertRaises(ValueError):
                pool.runner_labels(platform, 'x64', suffix)

    def test_host_validation_rejects_wrong_deployment_baseline(self):
        pool.validate_host('macos-14', 'arm64', 'Darwin', 'arm64', '14.8.3')
        pool.validate_host('macos-15', 'x64', 'Darwin', 'x86_64', '15.7')
        pool.validate_host('linux', 'arm64', 'Linux', 'aarch64', '24.04')
        for host in [('Darwin', 'arm64', '15.7'), ('Darwin', 'x86_64', '14.8'),
                     ('Linux', 'aarch64', '24.04')]:
            with self.assertRaises(ValueError):
                pool.validate_host('macos-14', 'arm64', *host)

    def test_mac_arm_aliases_match_native_images_and_target_job_labels(self):
        for profile, image, major in [('macos-15-arm64', 'macos-15', '15'),
                                      ('macos-26-arm', 'macos-26', '26'),
                                      ('macos-26', 'macos-26', '26')]:
            item = pool.matrix('runner-pool-mac', 0, 1, profile)['include'][0]
            self.assertEqual(item['os'], image)
            labels = pool.runner_labels(profile, 'arm64')
            self.assertTrue({'self-hosted', 'macOS', 'ARM64', profile}.issubset(labels))
            pool.validate_host(profile, 'arm64', 'Darwin', 'arm64', major + '.1')
            with self.assertRaises(ValueError):
                pool.matrix('runner-pool-mac', 1, 0, profile)
            with self.assertRaises(ValueError):
                pool.validate_host(profile, 'arm64', 'Darwin', 'arm64', '14.8')
        self.assertIn('macos-26-arm64', pool.runner_labels('macos-26-arm', 'arm64'))

    def test_parent_credentials_and_context_cannot_reach_child(self):
        parent = dict(HOME='/home/runner', PATH='/bin', USER='runner',
                      GITHUB_TOKEN='secret', GH_TOKEN='secret', GITHUB_REPOSITORY='host/repository',
                      ACTIONS_RUNTIME_TOKEN='secret', RUNNER_TRACKING_ID='parent',
                      RUNNER_JIT_CONFIG='secret',
                      GITHUB_ENV='/parent/env', GITHUB_OUTPUT='/parent/output')
        self.assertEqual(pool.child_environment(parent),
                         {'HOME': '/home/runner', 'PATH': '/bin', 'USER': 'runner'})

    def test_child_creates_readable_formulae_without_exposing_host_diagnostics(self):
        previous = os.umask(0o077)
        try:
            with tempfile.TemporaryDirectory() as temporary:
                directory = Path(temporary)
                script = directory / 'run.sh'
                script.write_text('#!/bin/sh\nset -eu\nmkdir checkout\n'
                                  'printf "class Formula\\n" > checkout/formula.rb\n'
                                  'printf "private target output\\n"\n')
                script.chmod(0o700)
                log_path = directory / 'host.log'
                with log_path.open('wb') as log:
                    process = pool.start_runner(directory, 'dummy', pool.child_environment(os.environ), log)
                    self.assertEqual(process.wait(timeout=10), 0)
                # A restrictive inherited mask makes Homebrew reject formulae
                # with mode 600. The parent must still create private files.
                self.assertEqual(stat.S_IMODE((directory / 'checkout/formula.rb').stat().st_mode), 0o644)
                self.assertEqual(stat.S_IMODE((directory / 'checkout').stat().st_mode), 0o755)
                self.assertEqual(stat.S_IMODE(directory.stat().st_mode), 0o700)
                self.assertEqual(stat.S_IMODE(log_path.stat().st_mode), 0o600)
                self.assertEqual(log_path.read_text(), 'private target output\n')
                probe = directory / 'parent-file'
                probe.write_text('private')
                self.assertEqual(stat.S_IMODE(probe.stat().st_mode), 0o600)
        finally:
            os.umask(previous)


if __name__ == '__main__':
    unittest.main()
