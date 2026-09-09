"""Small independent interoperability check for the MoonXZ CLI.

This script intentionally uses Python's standard-library lzma module rather
than the MoonXZ implementation for the reference side of the check.
"""

from __future__ import annotations

import lzma
import subprocess
import sys


def run_cli(*args: str) -> str:
    result = subprocess.run(
        ["moon", "run", "-q", "cmd/main", "--", *args],
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip()


def main() -> int:
    payload = b"MoonXZ interoperability test. " * 200

    for check_name, check_kind in [
        ("none", lzma.CHECK_NONE),
        ("crc32", lzma.CHECK_CRC32),
        ("crc64", lzma.CHECK_CRC64),
        ("sha256", lzma.CHECK_SHA256),
    ]:
        moonxz_bytes = bytes.fromhex(
            run_cli("compress", payload.hex(), check_name)
        )
        if lzma.decompress(moonxz_bytes) != payload:
            print(f"MoonXZ -> Python failed for {check_name}", file=sys.stderr)
            return 1

        pythonxz_bytes = lzma.compress(
            payload,
            format=lzma.FORMAT_XZ,
            check=check_kind,
            preset=6,
        )
        decoded = bytes.fromhex(run_cli("decompress", pythonxz_bytes.hex()))
        if decoded != payload:
            print(f"Python -> MoonXZ failed for {check_name}", file=sys.stderr)
            return 1

    print("MoonXZ interoperability: ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
