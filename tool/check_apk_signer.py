import argparse
import re
import sys


def verify_signer(output, expected):
    if not re.fullmatch(r"[0-9a-fA-F]{64}", expected):
        raise ValueError("expected certificate digest must be 64 hexadecimal characters")
    counts = re.findall(r"^Number of signers: (.+)$", output, re.MULTILINE)
    certificates = re.findall(
        r"^Signer #([^\s]+) certificate SHA-256 digest: (.*)$",
        output,
        re.MULTILINE,
    )
    if counts != ["1"] or len(certificates) != 1:
        raise ValueError("expected exactly one APK signer")
    signer, digest = certificates[0]
    if signer != "1" or digest.lower() != expected.lower():
        raise ValueError("APK signer does not match the pinned release certificate")


def main():
    parser = argparse.ArgumentParser(description="Check verified apksigner output against a certificate digest")
    parser.add_argument("expected_sha256")
    args = parser.parse_args()
    try:
        verify_signer(sys.stdin.read(), args.expected_sha256)
    except ValueError as error:
        parser.exit(1, str(error) + "\n")
    print("APK signer matches the pinned release certificate")


if __name__ == "__main__":
    main()
