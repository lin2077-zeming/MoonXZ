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

    # Multi-chunk inputs, where matches reach across the 64 KiB LZMA2 boundary and
    # a later chunk keeps the previous dictionary. A naive repeated-byte payload
    # would only ever produce distance-1 matches and miss this path.
    period = bytes((i * 7 + 13) & 0xFF for i in range(70000))
    multi_chunk = [
        ("straddling-period", period + period),
        ("short-period", bytes(range(100)) * 1400),
        (
            "mixed-compressibility",
            bytes(65530) + bytes((i * 31 + 5) & 0xFF for i in range(200)) + bytes(65530),
        ),
    ]
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        for name, data in multi_chunk:
            source = root / f"{name}.bin"
            encoded = root / f"{name}.xz"
            restored = root / f"{name}.restored"
            source.write_bytes(data)
            run_cli("compress-file", str(source), str(encoded), "crc64", "none")
            if lzma.decompress(encoded.read_bytes()) != data:
                print(f"MoonXZ -> Python failed for {name}", file=sys.stderr)
                return 1
            run_cli("decompress-file", str(encoded), str(restored))
            if restored.read_bytes() != data:
                print(f"MoonXZ self round trip failed for {name}", file=sys.stderr)
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
            bytes.fromhex("e800000000e9fbffffff90e801000000c3") + bytes(100),
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

    # Filters MoonXZ deliberately refuses must be refused, not approximated: a
    # BCJ filter with wrong address arithmetic corrupts data silently.
    refused = [
        ("arm", lzma.FILTER_ARM),
        ("powerpc", lzma.FILTER_POWERPC),
        ("sparc", lzma.FILTER_SPARC),
        ("armthumb", lzma.FILTER_ARMTHUMB),
    ]
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        payload = bytes.fromhex("000000eb000000eb040000ebffffffea") + bytes(100)
        for name, filter_id in refused:
            encoded = root / f"refused_{name}.xz"
            encoded.write_bytes(
                lzma.compress(
                    payload,
                    format=lzma.FORMAT_XZ,
                    check=lzma.CHECK_CRC64,
                    filters=[{"id": filter_id}, {"id": lzma.FILTER_LZMA2, "preset": 6}],
                )
            )
            result = subprocess.run(
                ["moon", "run", "-q", "cmd/main", "--", "decompress-file",
                 str(encoded), str(root / "refused.out")],
                capture_output=True,
                text=True,
            )
            combined = result.stdout + result.stderr
            if "Unsupported" not in combined:
                print(
                    f"expected Unsupported for refused filter {name}, got: {combined.strip()[:120]}",
                    file=sys.stderr,
                )
                return 1

    # Legacy LZMA-alone: both header forms, in both directions.
    legacy_cases = [
        (
            "alone-sized",
            lzma.compress(payload, format=lzma.FORMAT_ALONE),
        ),
        (
            "alone-end-marker",
            _alone_with_end_marker(payload),
        ),
    ]
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        for name, encoded_bytes in legacy_cases:
            encoded = root / f"{name}.lzma"
            restored = root / f"{name}.restored"
            encoded.write_bytes(encoded_bytes)

            run_cli("lzma-decompress-file", str(encoded), str(restored))
            if restored.read_bytes() != payload:
                print(f"Python -> MoonXZ failed for {name}", file=sys.stderr)
                return 1

            source = root / f"{name}.bin"
            source.write_bytes(payload)
            produced = root / f"{name}.produced.lzma"
            run_cli("lzma-compress-file", str(source), str(produced))
            if lzma.decompress(produced.read_bytes()) != payload:
                print(f"MoonXZ -> Python failed for {name}", file=sys.stderr)
                return 1

    print("MoonXZ interoperability: ok")
    return 0


def _alone_with_end_marker(payload: bytes) -> bytes:
    """Builds a `.lzma` stream that records the unknown-size sentinel.

    The one-shot API records the exact size, so the streaming API is used to get
    a stream terminated by the end marker instead.
    """
    import io

    buffer = io.BytesIO()
    with lzma.open(buffer, "wb", format=lzma.FORMAT_ALONE) as handle:
        handle.write(payload)
    return buffer.getvalue()


if __name__ == "__main__":
    raise SystemExit(main())
