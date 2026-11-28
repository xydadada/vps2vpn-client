from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent


class ExitAddressEvidence(unittest.TestCase):
    def test_exit_change_requires_both_address_observations(self):
        with tempfile.TemporaryDirectory() as directory:
            source = ROOT / 'driver/src/androidTest/java/com/vps2vpn/testlab/ExitAddressCheck.java'
            compiled = subprocess.run(
                ['java', '--module', 'jdk.compiler/com.sun.tools.javac.Main',
                 '-source', '17', '-target', '17', '-d', directory, str(source),
                 str(ROOT / 'tests/ExitAddressCheckTest.java')], capture_output=True, text=True,
            )
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            result = subprocess.run(
                ['java', '-cp', directory, 'com.vps2vpn.testlab.ExitAddressCheckTest'],
                capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('36 exit evidence checks passed', result.stdout)


if __name__ == '__main__':
    unittest.main()
