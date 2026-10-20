import sys
from pathlib import Path
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import runner_pool as p

class WindowsPoolTests(unittest.TestCase):
    def test_exact_native_image_and_label(self):
        self.assertEqual(p.host_spec("windows-2022", "x64")["image"], "windows-2022")
        self.assertEqual(p.runner_labels("windows-2022", "x64"), ["self-hosted", "Windows", "X64", "windows-2022-sf"])
        self.assertEqual(p.host_spec("windows-2022", "x64")["package"], "win")
    def test_wrong_arch_or_os_rejected(self):
        for args in [("windows-2022", "arm64"), ("windows-2025", "x64")]:
            with self.assertRaises(ValueError): p.host_spec(*args)
        for args in [("Windows", "AMD64", "10.0.26100"), ("Linux", "x86_64", "10.0.20348"), ("Windows", "ARM64", "10.0.20348")]:
            with self.assertRaises(ValueError): p.validate_host("windows-2022", "x64", *args)
        p.validate_host("windows-2022", "x64", "Windows", "AMD64", "10.0.20348")
    def test_parent_credentials_never_inherited(self):
        env = {"Path":"safe", "SystemRoot":"C:\\Windows", "TEMP":"private", "GITHUB_TOKEN":"secret", "GH_TOKEN":"secret", "RUNNER_JIT_CONFIG":"secret", "ACTIONS_RUNTIME_TOKEN":"secret", "AWS_SECRET_ACCESS_KEY":"secret"}
        self.assertEqual(p.child_environment(env), {k:env[k] for k in ("Path","SystemRoot","TEMP")})
    def test_windows_matrix_uses_one_job_hosts(self):
        m=p.matrix("runner-pool-windows-test", 16, 0, "windows-2022")["include"]
        self.assertEqual(len(m),16)
        self.assertTrue(all(x["os"]=="windows-2022" and x["arch"]=="x64" for x in m))
        with self.assertRaises(ValueError): p.matrix("runner-pool-windows-test", 1, 1, "windows-2022")

if __name__ == "__main__": unittest.main()
