#!/usr/bin/env python3
"""Fuzzes the MoonXZ CLI with small malformed inputs looking for panics.

A handled corrupt stream prints `error: ...` and exits. Anything else - a
MoonBit panic, a trap, a non-zero exit without a diagnostic - is a finding.

Usage: fuzz_cli.py <moonxz-repo> [iterations]
"""

import os
import random
import struct
import subprocess
import sys
import tempfile

XZ_MAGIC = b"\xfd7zXZ\x00"


def xz_header(flags=0x00):
    """A valid 12-byte stream header; flags 0x00 and 0x04 are legal."""
    crc = 0  # MoonXZ checks the CRC separately; a bad one is handled output.
    return XZ_MAGIC + struct.pack("<BBHI", flags, 0x00, crc, 0)


def candidates(rng):
    """Yields malformed inputs, favouring shapes that reach the length paths."""
    # The reviewer's report: exactly 28 bytes.
    yield 28, lambda: XZ_MAGIC + bytes(rng.randrange(256) for _ in range(22))

    # A valid header plus an index indicator (0x00) and a footer-ish tail.
    yield 28, lambda: XZ_MAGIC + b"\x00" + bytes(rng.randrange(256) for _ in range(15))

    # A block header that declares a huge compressed size in its last field.
    def big_block():
        body = XZ_MAGIC
        body += b"\x02"  # block header size 2 -> 8 bytes
        body += b"\x00"  # block flags: one filter, no compressed/uncompressed size
        body += b"\x21"  # LZMA2 filter id
        body += b"\x01"  # properties size
        body += b"\x00"  # properties
        body += b"\x00\x00\x00"  # header padding to 4-byte multiple
        body += b"\x02\x00\x00\x00\x00\x00\x00\x00"  # bogus
        return body[:28]

    yield 28, big_block

    # Random bytes with the magic in front, various lengths.
    for length in (12, 13, 16, 24, 28, 32, 40, 60, 128):
        yield length, lambda n=length: (
            XZ_MAGIC + bytes(rng.randrange(256) for _ in range(n - 12))
        )

    # LZMA2 chunk whose compressed-size field is 0xFFFF (65536) but with no body,
    # which is what makes the old length check overflow.
    def lzma2_huge_length():
        body = XZ_MAGIC
        body += b"\x02" + b"\x00" + b"\x21" + b"\x01" + b"\x00" + b"\x00\x00\x00"
        body += b"\xe0" + b"\xff\xff" + b"\xff\xff" + b"\x5d"  # 64 KiB uncompressed
        return body[:28]

    yield 28, lzma2_huge_length

    # Random truncations of a real small .xz file.
    real = None
    try:
        import lzma

        real = lzma.compress(b"hello moonxz", format=lzma.FORMAT_XZ)
    except Exception:
        pass
    if real:
        for cut in range(1, min(len(real), 40)):
            yield 28, lambda c=cut: real[:c]


def main():
    repo = sys.argv[1]
    iterations = int(sys.argv[2]) if len(sys.argv) > 2 else 300
    rng = random.Random(20260925)
    tmp = tempfile.mkdtemp(prefix="moonxz_fuzz_")
    findings = []
    checked = 0

    inputs = []
    for _ in range(iterations):
        for _length, maker in candidates(rng):
            inputs.append(maker())
            if len(inputs) >= iterations:
                break
        if len(inputs) >= iterations:
            break
    # Plus pure random blobs.
    while len(inputs) < iterations:
        n = rng.choice([12, 13, 20, 28, 29, 64])
        inputs.append(bytes(rng.randrange(256) for _ in range(n)))

    for data in inputs:
        src = os.path.join(tmp, "in.bin")
        dst = os.path.join(tmp, "out.bin")
        with open(src, "wb") as fh:
            fh.write(data)
        if os.path.exists(dst):
            os.remove(dst)
        proc = subprocess.run(
            ["moon", "run", "-q", "cmd/main", "--", "decompress-file", src, dst],
            cwd=repo,
            capture_output=True,
            timeout=300,
        )
        out = (proc.stdout + proc.stderr).decode("utf-8", "replace")
        checked += 1
        # A handled stream failure mentions error: and returns normally.
        panicked = any(
            marker in out
            for marker in ("panicked", "panic", "trap", "Fatal", "Segmentation")
        )
        if panicked or (proc.returncode != 0 and "error:" not in out):
            findings.append((len(data), data.hex(), proc.returncode, out.strip()[:400]))
            if len(findings) >= 8:
                break

    print(f"checked {checked} inputs")
    if not findings:
        print("no panics found")
    for length, hexed, code, out in findings:
        print(f"\n--- len={length} exit={code}")
        print(f"    {hexed}")
        print(f"    {out}")


if __name__ == "__main__":
    main()
