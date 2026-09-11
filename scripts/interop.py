"""Small independent interoperability check for the MoonXZ CLI.

This script intentionally uses Python's standard-library lzma module rather
than the MoonXZ implementation for the reference side of the check.
"""

from __future__ import annotations

import lzma
import subprocess
import sys
import tempfile
from pathlib import Path


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

    filter_cases = [
        (
            "delta",
            [{"id": lzma.FILTER_DELTA, "dist": 1}, {"id": lzma.FILTER_LZMA2, "preset": 6}],
            bytes(range(256)) * 20,
        ),
        (
            "x86",
            [{"id": lzma.FILTER_X86}, {"id": lzma.FILTER_LZMA2, "preset": 6}],
            bytes.fromhex("e800000000e9fbffffff90e801000000c3"),
        ),
    ]
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        for filter_name, filters, filter_payload in filter_cases:
            source = root / f"{filter_name}.bin"
            encoded = root / f"{filter_name}.xz"
            restored = root / f"{filter_name}.restored"
            source.write_bytes(filter_payload)

            run_cli(
                "compress-file",
                str(source),
                str(encoded),
                "sha256",
                filter_name,
            )
            if lzma.decompress(encoded.read_bytes()) != filter_payload:
                print(f"MoonXZ -> Python failed for {filter_name}", file=sys.stderr)
                return 1

            encoded.write_bytes(
                lzma.compress(
                    filter_payload,
                    format=lzma.FORMAT_XZ,
                    filters=filters,
                )
            )
            run_cli("decompress-file", str(encoded), str(restored))
            if restored.read_bytes() != filter_payload:
                print(f"Python -> MoonXZ failed for {filter_name}", file=sys.stderr)
                return 1

    print("MoonXZ interoperability: ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
