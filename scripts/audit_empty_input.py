#!/usr/bin/env python3
"""Adapter: every MoonXZ entry point must round trip an empty input.

Called by the generic acceptance audit. The reasoning is in
`docs/skills/moonbit-acceptance-review/SKILL.md`: an encoder that rejects its own
empty case is a real gap, and it is the kind of gap a feature checklist misses
because "encode a file" sounds covered.

Exit 0 if every entry point round trips empty input.
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

CLI = ["moon", "run", "-q", "cmd/main"]


def run(args: list[str], root: Path) -> tuple[int, str]:
    proc = subprocess.run(
        CLI + args, cwd=root, capture_output=True, text=True,
        encoding="utf-8", errors="replace",
    )
    return proc.returncode, (proc.stdout or "") + (proc.stderr or "")


def main() -> int:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    failures: list[str] = []

    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        empty = work / "empty.bin"
        empty.write_bytes(b"")

        # XZ: compress then decompress must both succeed and yield nothing.
        xz = work / "empty.xz"
        code, out = run(["compress-file", str(empty), str(xz)], root)
        if code != 0 or not xz.exists():
            failures.append("xz compress: " + (out.strip()[:100] or "no output file"))
        else:
            restored = work / "empty.xz.out"
            code, out = run(["decompress-file", str(xz), str(restored)], root)
            if code != 0:
                failures.append("xz decompress: " + out.strip()[:100])
            elif restored.read_bytes() != b"":
                failures.append("xz round trip produced bytes")

        # LZMA-alone: same shape.
        lz = work / "empty.lzma"
        code, out = run(["lzma-compress-file", str(empty), str(lz)], root)
        if code != 0:
            failures.append("lzma compress: " + (out.strip()[:100] or "failed"))
        else:
            restored = work / "empty.lzma.out"
            code, out = run(["lzma-decompress-file", str(lz), str(restored)], root)
            if code != 0:
                failures.append("lzma decompress: " + out.strip()[:100])
            elif restored.read_bytes() != b"":
                failures.append("lzma round trip produced bytes")

    if failures:
        print("empty input failed: " + "; ".join(failures), file=sys.stderr)
        return 1
    print("empty input round trips for xz and lzma")
    return 0


if __name__ == "__main__":
    sys.exit(main())
