import importlib.util
from pathlib import Path
import subprocess
import sys
import unittest


SCRIPT = Path(__file__).with_name("check_apk_signer.py")
SPEC = importlib.util.spec_from_file_location("check_apk_signer", SCRIPT)
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)
DIGEST = "ab" * 32


def report(digest=DIGEST, count="1", signer="1", subject="CN=Example"):
    return (
        "Verifies\nVerified using v2 scheme (APK Signature Scheme v2): true\n"
        f"Number of signers: {count}\n"
        f"Signer #{signer} certificate DN: {subject}\n"
        f"Signer #{signer} certificate SHA-256 digest: {digest}\n"
    )


class SignerIdentity(unittest.TestCase):
    def test_accepts_only_matching_certificate_independent_of_subject(self):
        for subject in ("CN=Example", "CN=Different Example"):
            CHECK.verify_signer(report(subject=subject), DIGEST.upper())
            CHECK.verify_signer(report(digest=DIGEST.upper()), DIGEST)

    def test_rejects_same_subject_with_another_certificate(self):
        with self.assertRaises(ValueError):
            CHECK.verify_signer(report(digest="cd" * 32), DIGEST)

    def test_rejects_missing_or_ambiguous_signer_information(self):
        for output in (
            "", report(count="0"), report(count="2"), report(signer="2"),
            report() + report(), report().replace("Number of signers: 1\n", ""),
            report() + "Signer #2 certificate SHA-256 digest: " + DIGEST + "\n",
            report() + "Number of signers: 1\n",
        ):
            with self.subTest(output=output), self.assertRaises(ValueError):
                CHECK.verify_signer(output, DIGEST)

    def test_rejects_malformed_or_partial_digests(self):
        for digest in ("", DIGEST[:-1], "g" * 64, DIGEST + " extra", ":".join(["ab"] * 32)):
            with self.subTest(digest=digest), self.assertRaises(ValueError):
                CHECK.verify_signer(report(digest=digest), DIGEST)

    def test_rejects_invalid_expected_digest(self):
        for expected in ("", "g" * 64, DIGEST[:-1], DIGEST + "\n"):
            with self.subTest(expected=expected), self.assertRaises(ValueError):
                CHECK.verify_signer(report(), expected)

    def test_cli_exit_status_and_private_output(self):
        for output, expected_code in ((report(), 0), (report(digest="cd" * 32), 1)):
            completed = subprocess.run(
                [sys.executable, "-I", str(SCRIPT), DIGEST],
                input=output, text=True, capture_output=True, check=False,
            )
            self.assertEqual(completed.returncode, expected_code)
            self.assertNotIn("CN=", completed.stdout + completed.stderr)
            self.assertNotIn(DIGEST, completed.stdout + completed.stderr)


if __name__ == "__main__":
    unittest.main()
