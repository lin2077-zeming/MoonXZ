#!/usr/bin/env python3
"""Regenerate the MoonXZ conformance corpus and manifest.

The corpus is intentionally small enough to commit. The script is an external
adapter: it may use Python liblzma and the official xz executable, but the
conformance runner itself is MoonBit and consumes only committed files.
"""

from __future__ import annotations

import hashlib
import json
import lzma
import os
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parents[1]
FIXTURES = ROOT / "corpus" / "fixtures"
MANIFEST = ROOT / "corpus" / "manifest.json"
XZ = REPO / "_build" / "xz583" / "bin_x86-64" / "xz.exe"


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write(name: str, data: bytes) -> str:
    path = FIXTURES / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    return f"fixtures/{name}"


def case(
    case_id: str,
    description: str,
    operation: str,
    input_name: str,
    input_data: bytes,
    *,
    expected_name: str | None = None,
    expected_data: bytes | None = None,
    source: str,
    format: str = "xz",
    check: str | None = None,
    stream_chunk: int | None = None,
    max_output: int | None = None,
    concatenated: bool | None = None,
    moonxz_expect: str = "exact",
    lzma_mbt_expect: str = "exact",
) -> dict:
    item = {
        "id": case_id,
        "description": description,
        "operation": operation,
        "input": write(input_name, input_data),
        "input_sha256": sha256(input_data),
        "format": format,
        "source": source,
        "moonxz_expect": moonxz_expect,
        "lzma_mbt_expect": lzma_mbt_expect,
    }
    if expected_data is not None and expected_name is not None:
        item["expected"] = write(expected_name, expected_data)
        item["expected_sha256"] = sha256(expected_data)
    if check is not None:
        item["check"] = check
    if stream_chunk is not None:
        item["stream_chunk"] = stream_chunk
    if max_output is not None:
        item["max_output"] = max_output
    if concatenated is not None:
        item["concatenated"] = concatenated
    return item


def xz(data: bytes, check: int = lzma.CHECK_CRC64, filters=None) -> bytes:
    return lzma.compress(
        data,
        format=lzma.FORMAT_XZ,
        check=check,
        filters=filters,
    )


def generate_arm64() -> tuple[bytes, bytes]:
    payload = FIXTURES / "arm64-filter.bin"
    encoded = FIXTURES / "arm64-filter.xz"
    subprocess.run(
        [
            "moon",
            "run",
            "-q",
            "cmd/gen_arm64",
            "--",
            str(payload),
            str(encoded),
        ],
        cwd=ROOT,
        check=True,
    )
    plain = payload.read_bytes()
    stream = encoded.read_bytes()
    xz_bin = Path(os.environ.get("XZ_BIN", XZ))
    if not xz_bin.exists():
        raise SystemExit(
            f"xz 5.6+ is required to verify ARM64: set XZ_BIN or place it at {xz_bin}"
        )
    decoded = subprocess.run(
        [str(xz_bin), "-dc", str(encoded)],
        check=True,
        capture_output=True,
    ).stdout
    if decoded != plain:
        raise SystemExit("official xz rejected or misdecoded the ARM64 fixture")
    return plain, stream


def generate_lzma_sized(plain: bytes) -> bytes:
    src = FIXTURES / "lzma-sized.bin"
    dst = FIXTURES / "lzma-sized.lzma"
    src.write_bytes(plain)
    subprocess.run(
        [
            "moon",
            "run",
            "-q",
            "cmd/main",
            "--",
            "lzma-compress-file",
            str(src),
            str(dst),
        ],
        cwd=REPO,
        check=True,
    )
    encoded = dst.read_bytes()
    if lzma.decompress(encoded, format=lzma.FORMAT_ALONE) != plain:
        raise SystemExit("Python liblzma rejected MoonXZ's sized .lzma fixture")
    return encoded


def build_manifest() -> dict:
    FIXTURES.mkdir(parents=True, exist_ok=True)
    for old in FIXTURES.glob("*"):
        if old.is_file():
            old.unlink()

    empty = b""
    hello = b"MoonXZ conformance corpus.\n"
    boundary = bytes((i * 7 + 13) & 0xFF for i in range(131072))
    arm_plain = bytes.fromhex("000000eb000000eb040000ebffffffea") + bytes(100)
    armthumb_plain = bytes.fromhex("00f000f837f15bf8") + bytes(100)
    powerpc_plain = bytes.fromhex("4800000149375b9d") + bytes(100)
    ia64_plain = bytes.fromhex("1600000000140000") + bytes(100)
    sparc_plain = bytes.fromhex("4000000040000001") + bytes(100)
    arm64_plain, arm64_stream = generate_arm64()
    lzma_sized = generate_lzma_sized(hello)
    lzma_end_marker = lzma.compress(hello, format=lzma.FORMAT_ALONE)

    hello_crc64 = xz(hello, lzma.CHECK_CRC64)
    hello_crc32 = xz(hello, lzma.CHECK_CRC32)
    hello_sha256 = xz(hello, lzma.CHECK_SHA256)
    hello_none = xz(hello, lzma.CHECK_NONE)
    first = xz(b"first stream", lzma.CHECK_CRC64)
    second = xz(b"second stream", lzma.CHECK_CRC64)
    concatenated = first + b"\0\0\0\0" + second
    concatenated_plain = b"first streamsecond stream"
    delta_filters = [
        {"id": lzma.FILTER_DELTA, "dist": 4},
        {"id": lzma.FILTER_LZMA2, "preset": 6},
    ]
    x86_filters = [
        {"id": lzma.FILTER_X86},
        {"id": lzma.FILTER_LZMA2, "preset": 6},
    ]
    arm_filters = [
        {"id": lzma.FILTER_ARM},
        {"id": lzma.FILTER_LZMA2, "preset": 6},
    ]
    armthumb_filters = [
        {"id": lzma.FILTER_ARMTHUMB},
        {"id": lzma.FILTER_LZMA2, "preset": 6},
    ]
    powerpc_filters = [
        {"id": lzma.FILTER_POWERPC},
        {"id": lzma.FILTER_LZMA2, "preset": 6},
    ]
    ia64_filters = [
        {"id": lzma.FILTER_IA64},
        {"id": lzma.FILTER_LZMA2, "preset": 6},
    ]
    sparc_filters = [
        {"id": lzma.FILTER_SPARC},
        {"id": lzma.FILTER_LZMA2, "preset": 6},
    ]
    x86_plain = bytes.fromhex("e800000000e9fbffffff90e801000000c3") + bytes(100)
    corrupt = bytearray(hello_crc64)
    corrupt[-20] ^= 0x01

    cases = [
        case(
            "xz-empty",
            "Empty XZ stream with CRC64 and no blocks",
            "decode",
            "empty.xz",
            xz(empty),
            expected_name="empty.bin",
            expected_data=empty,
            source="Python 3.14 lzma.compress(format=FORMAT_XZ, check=CHECK_CRC64)",
        ),
        case(
            "xz-hello-crc64",
            "Single-block XZ stream with CRC64",
            "decode",
            "hello-crc64.xz",
            hello_crc64,
            expected_name="hello.bin",
            expected_data=hello,
            source="Python 3.14 lzma.compress(format=FORMAT_XZ, check=CHECK_CRC64)",
        ),
        case(
            "xz-hello-crc32",
            "Single-block XZ stream with CRC32",
            "decode",
            "hello-crc32.xz",
            hello_crc32,
            expected_name="hello.bin",
            expected_data=hello,
            source="Python 3.14 lzma.compress(format=FORMAT_XZ, check=CHECK_CRC32)",
        ),
        case(
            "xz-hello-sha256",
            "Single-block XZ stream with SHA-256",
            "decode",
            "hello-sha256.xz",
            hello_sha256,
            expected_name="hello.bin",
            expected_data=hello,
            source="Python 3.14 lzma.compress(format=FORMAT_XZ, check=CHECK_SHA256)",
        ),
        case(
            "xz-hello-none",
            "Single-block XZ stream with no integrity check",
            "decode",
            "hello-none.xz",
            hello_none,
            expected_name="hello.bin",
            expected_data=hello,
            source="Python 3.14 lzma.compress(format=FORMAT_XZ, check=CHECK_NONE)",
        ),
        case(
            "lzma-sized",
            "LZMA-alone stream with an exact uncompressed-size header",
            "decode",
            "lzma-sized.lzma",
            lzma_sized,
            expected_name="hello.bin",
            expected_data=hello,
            source="MoonXZ compress_lzma1, independently decoded by Python liblzma",
            format="lzma",
        ),
        case(
            "lzma-end-marker",
            "LZMA-alone stream with the unknown-size sentinel and end marker",
            "decode",
            "lzma-end-marker.lzma",
            lzma_end_marker,
            expected_name="hello.bin",
            expected_data=hello,
            source="Python 3.14 lzma.compress(format=FORMAT_ALONE)",
            format="lzma",
        ),
        case(
            "xz-delta",
            "Delta distance 4 followed by LZMA2",
            "decode",
            "delta.xz",
            xz(bytes(range(256)) * 20, filters=delta_filters),
            expected_name="delta.bin",
            expected_data=bytes(range(256)) * 20,
            source="Python 3.14 lzma.compress with FILTER_DELTA(distance=4)",
        ),
        case(
            "xz-x86",
            "x86 BCJ followed by LZMA2",
            "decode",
            "x86.xz",
            xz(x86_plain, filters=x86_filters),
            expected_name="x86.bin",
            expected_data=x86_plain,
            source="Python 3.14 lzma.compress with FILTER_X86",
        ),
        case(
            "xz-arm",
            "ARM BCJ fixture; MoonXZ refuses it and lzma-mbt decodes it",
            "decode",
            "arm.xz",
            xz(arm_plain, filters=arm_filters),
            expected_name="arm.bin",
            expected_data=arm_plain,
            source="Python 3.14 lzma.compress with FILTER_ARM",
            moonxz_expect="unsupported",
        ),
        case(
            "xz-armthumb",
            "ARM-Thumb BCJ fixture; MoonXZ refuses it and lzma-mbt decodes it",
            "decode",
            "armthumb.xz",
            xz(armthumb_plain, filters=armthumb_filters),
            expected_name="armthumb.bin",
            expected_data=armthumb_plain,
            source="Python 3.14 lzma.compress with FILTER_ARMTHUMB",
            moonxz_expect="unsupported",
        ),
        case(
            "xz-powerpc",
            "PowerPC BCJ fixture; MoonXZ refuses it and lzma-mbt decodes it",
            "decode",
            "powerpc.xz",
            xz(powerpc_plain, filters=powerpc_filters),
            expected_name="powerpc.bin",
            expected_data=powerpc_plain,
            source="Python 3.14 lzma.compress with FILTER_POWERPC",
            moonxz_expect="unsupported",
        ),
        case(
            "xz-ia64",
            "IA-64 BCJ fixture; MoonXZ refuses it and lzma-mbt decodes it",
            "decode",
            "ia64.xz",
            xz(ia64_plain, filters=ia64_filters),
            expected_name="ia64.bin",
            expected_data=ia64_plain,
            source="Python 3.14 lzma.compress with FILTER_IA64",
            moonxz_expect="unsupported",
        ),
        case(
            "xz-sparc",
            "SPARC BCJ fixture; MoonXZ refuses it and lzma-mbt decodes it",
            "decode",
            "sparc.xz",
            xz(sparc_plain, filters=sparc_filters),
            expected_name="sparc.bin",
            expected_data=sparc_plain,
            source="Python 3.14 lzma.compress with FILTER_SPARC",
            moonxz_expect="unsupported",
        ),
        case(
            "xz-arm64",
            "ARM64 BL and ADRP filter chain, verified by official xz 5.8.3",
            "decode",
            "arm64-filter.xz",
            arm64_stream,
            expected_name="arm64-filter.bin",
            expected_data=arm64_plain,
            source="lzma-mbt ARM64 encoder; decoded byte-for-byte by xz 5.8.3",
            moonxz_expect="unsupported",
        ),
        case(
            "xz-concatenated-padding",
            "Two concatenated XZ streams separated by four zero padding bytes",
            "decode",
            "concatenated-padding.xz",
            concatenated,
            expected_name="concatenated.bin",
            expected_data=concatenated_plain,
            source="Two Python liblzma streams joined with four-byte stream padding",
            concatenated=True,
        ),
        case(
            "xz-128k-boundary",
            "Incompressible stream above the 18-bit LZMA2 size carry boundary",
            "decode",
            "boundary-128k.xz",
            xz(boundary),
            expected_name="boundary-128k.bin",
            expected_data=boundary,
            source="Python 3.14 lzma.compress at the 128 KiB boundary",
        ),
        case(
            "xz-hello-stream-1-byte",
            "Feed a valid XZ stream into the decoder one byte at a time",
            "stream_decode",
            "hello-crc64.xz",
            hello_crc64,
            expected_name="hello.bin",
            expected_data=hello,
            source="Chunk boundary stress derived from xz-hello-crc64",
            stream_chunk=1,
        ),
        case(
            "xz-truncated",
            "Truncated XZ stream must fail explicitly",
            "decode",
            "truncated.xz",
            hello_crc64[:-1],
            source="Last byte removed from xz-hello-crc64",
            moonxz_expect="error",
            lzma_mbt_expect="error",
        ),
        case(
            "xz-corrupt-check",
            "Corrupted block check must not decode silently",
            "decode",
            "corrupt-check.xz",
            bytes(corrupt),
            source="One bit flipped in the xz-hello-crc64 block check",
            moonxz_expect="error",
            lzma_mbt_expect="error",
        ),
        case(
            "xz-output-limit",
            "MoonXZ output cap must reject a stream that expands past it",
            "decode",
            "boundary-128k.xz",
            xz(boundary),
            source="128 KiB stream with a 1 KiB output cap",
            max_output=1024,
            moonxz_expect="output_limit",
            lzma_mbt_expect="skip",
        ),
        case(
            "roundtrip-empty",
            "Cross-implementation XZ roundtrip for empty input",
            "roundtrip",
            "empty.bin",
            empty,
            source="MoonXZ and lzma-mbt cross-decode each other's output",
            check="crc64",
        ),
        case(
            "roundtrip-hello",
            "Cross-implementation XZ roundtrip for plain text",
            "roundtrip",
            "hello.bin",
            hello,
            source="MoonXZ and lzma-mbt cross-decode each other's output",
            check="crc64",
        ),
        case(
            "roundtrip-128k",
            "Cross-implementation XZ roundtrip above the LZMA2 size boundary",
            "roundtrip",
            "boundary-128k.bin",
            boundary,
            source="MoonXZ and lzma-mbt cross-decode each other's output",
            check="crc64",
        ),
    ]

    return {
        "schema_version": 1,
        "corpus_version": "2026-10-24",
        "generated_by": "tools/conformance/scripts/regenerate.py",
        "cases": cases,
    }


def main() -> int:
    manifest = build_manifest()
    MANIFEST.write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    print(f"wrote {MANIFEST} with {len(manifest['cases'])} cases")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
