#!/usr/bin/env python3
"""Reproduces the LZMA2 chunk-size carry bug and probes chunk sizes.

Generates XZ files whose compressed output is dominated by one or more LZMA2
chunks of a chosen uncompressed size, then reports the control byte that
liblzma emitted for each chunk. That byte is what MoonXZ mis-parses.
"""

import lzma
import os
import sys


def chunk_controls(path):
    """Walks a .xz file and returns the LZMA2 control bytes it contains."""
    raw = open(path, "rb").read()
    # Skip the 12-byte stream header, then the block header, to reach LZMA2.
    pos = 12
    if raw[pos] == 0:
        # Index; nothing else to walk.
        return []
    block_header_size = (raw[pos] + 1) * 4
    pos += block_header_size
    controls = []
    while pos < len(raw):
        control = raw[pos]
        if control == 0:
            break
        controls.append(control)
        pos += 1
        if 1 <= control <= 2:
            size = int.from_bytes(raw[pos:pos + 2], "big") + 1
            pos += 2 + size
            continue
        if control < 0x80:
            break
        uncompressed = ((control & 0x1F) << 16) | (
            int.from_bytes(raw[pos:pos + 2], "big") + 1
        )
        pos += 2
        compressed = int.from_bytes(raw[pos:pos + 2], "big") + 1
        pos += 2
        if (control & 0x60) >= 0x40:
            pos += 1  # properties byte
        pos += compressed
    return controls


def main():
    outdir = sys.argv[1] if len(sys.argv) > 1 else "."
    os.makedirs(outdir, exist_ok=True)
    # Sizes chosen to straddle the 16-bit field: below, exactly at, and above
    # 64 KiB, plus the specifically reported 128 KiB / 256 KiB / 1 MiB.
    sizes = [1, 1000, 65535, 65536, 65537, 131072, 131073, 262144, 1048576]
    index = []
    for size in sizes:
        # Incompressible data forces liblzma to emit fixed-size chunks.
        data = bytes((i * 7 + 13) % 251 for i in range(size))
        path = os.path.join(outdir, f"incompressible_{size}.xz")
        with lzma.open(path, "wb", format=lzma.FORMAT_XZ, preset=6) as fh:
            fh.write(data)
        open(os.path.join(outdir, f"incompressible_{size}.bin"), "wb").write(data)

        controls = chunk_controls(path)
        highlighted = [f"0x{c:02X}" for c in controls[:4]]
        index.append((size, os.path.getsize(path), len(controls), highlighted))

    # Also a mildly compressible case, where chunk sizes vary.
    for size in [131072, 262144, 1048576]:
        data = (b"MoonXZ verify pattern 0123456789\n" * (size // 32 + 1))[:size]
        path = os.path.join(outdir, f"repeat_{size}.xz")
        with lzma.open(path, "wb", format=lzma.FORMAT_XZ, preset=6) as fh:
            fh.write(data)
        open(os.path.join(outdir, f"repeat_{size}.bin"), "wb").write(data)
        controls = chunk_controls(path)
        index.append((f"repeat {size}", os.path.getsize(path), len(controls),
                      [f"0x{c:02X}" for c in controls[:4]]))

    print(f"{'input':>16} {'xz bytes':>9} {'chunks':>7}  first control bytes")
    for size, xzsize, chunks, shown in index:
        print(f"{str(size):>16} {xzsize:>9} {chunks:>7}  {' '.join(shown)}")


if __name__ == "__main__":
    main()
