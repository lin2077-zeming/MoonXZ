#!/usr/bin/env python3
"""Checks that the documents and the code agree.

Written after the first acceptance review failed. Every finding that review
reported was, at bottom, the same failure: something the project *said* was not
something the project *did*, or something that worked only for the inputs we
happened to try.

The earlier self-check walked the 9 acceptance criteria and confirmed each had
an artifact - a README exists, CI exists, tests exist, a release exists. That
is checklist verification, and it passed while the code was broken. This script
checks the weaker-looking but harder question instead: does each concrete claim
survive contact with the code?

It is deliberately mechanical. A claim that cannot be checked mechanically is
reported as UNVERIFIED rather than assumed true.

Usage: python scripts/self_audit.py [repo-root]
Exit code 1 if any check fails.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path

RESULTS: list[tuple[str, str, str]] = []


def record(status: str, check: str, detail: str) -> None:
    RESULTS.append((status, check, detail))


def run(cmd: list[str], cwd: Path, timeout: int = 900) -> tuple[int, str]:
    proc = subprocess.run(
        cmd, cwd=cwd, capture_output=True, timeout=timeout,
        text=True, encoding="utf-8", errors="replace",
    )
    return proc.returncode, (proc.stdout or "") + (proc.stderr or "")


def read(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except OSError:
        return ""


def check_version_consistency(root: Path) -> None:
    """moon.mod, README, the CLI banner and the proposal must agree."""
    moon_mod = read(root / "moon.mod")
    match = re.search(r'^version\s*=\s*"([^"]+)"', moon_mod, re.M)
    if not match:
        record("FAIL", "version: moon.mod declares one", "no version field found")
        return
    version = match.group(1)
    record("PASS", "version: moon.mod", version)

    # Any place that states the current version must state this one.
    claims = {
        "README.md": [
            r"当前版本是\s*`([^`]+)`",
            r"当前已发布版本为\s*`([^`]+)`",
        ],
    }
    for rel, patterns in claims.items():
        text = read(root / rel)
        for pattern in patterns:
            for found in re.findall(pattern, text):
                if found != version:
                    record(
                        "FAIL",
                        f"version: {rel} states the current version",
                        f"says {found}, moon.mod says {version}",
                    )
                else:
                    record("PASS", f"version: {rel} ({pattern[:24]}...)", found)

    banner = read(root / "cmd" / "main" / "main.mbt")
    # The banner is built from a named constant so there is one place to change.
    consts = re.findall(r'const CLI_VERSION\s*:\s*String\s*=\s*"([^"]+)"', banner)
    if not consts:
        record("FAIL", "version: CLI version constant present",
               'no `const CLI_VERSION : String = "..."` in cmd/main/main.mbt')
    for found in consts:
        if found != version:
            record(
                "FAIL",
                "version: CLI_VERSION matches moon.mod",
                f"constant is {found}, moon.mod says {version}",
            )
        else:
            record("PASS", "version: CLI_VERSION matches moon.mod", found)

    # And the banner must actually use the constant, not a repeated literal.
    if re.search(r'println\("MoonXZ .*CLI_VERSION', banner):
        record("PASS", "version: banner prints the constant", "interpolates CLI_VERSION")
    else:
        record(
            "FAIL",
            "version: banner prints the constant",
            'banner should interpolate CLI_VERSION, not repeat a literal version',
        )


def check_test_count_claims(root: Path) -> None:
    """A stated test count must equal the real one.

    The proposal claimed 34 tests when there were 46, because the number was
    written once and never revisited. A reviewer reading the proposal and then
    running the suite sees the mismatch immediately.
    """
    code, out = run(["moon", "test", "--target", "wasm"], root)
    match = re.search(r"Total tests:\s*(\d+)", out)
    if not match:
        record("FAIL", "tests: suite reports a total", out.strip()[-200:])
        return
    actual = int(match.group(1))
    record("PASS", "tests: actual count", str(actual))

    for rel in ("项目申报书.md", "README.md", "Progress.md"):
        text = read(root / rel)
        for found in re.findall(r"(\d+)\s*个测试", text):
            if int(found) != actual:
                record(
                    "FAIL",
                    f"tests: {rel} states the count",
                    f"claims {found}, actual {actual}",
                )
            else:
                record("PASS", f"tests: {rel}", found)


def check_negative_claims(root: Path) -> None:
    """A "not supported" claim must still be true.

    The proposal said a byte-at-a-time incremental interface was not provided.
    That was true when written and false by the time of review, because
    XzStreamDecoder had since been added. A negative claim that quietly became
    false reads as either a stale document or a missing feature.
    """
    patterns = {
        "项目申报书.md": [
            (r"不提供逐字节增量接口", "lib/streaming.mbt", "XzStreamDecoder", False),
        ],
    }
    for rel, entries in patterns.items():
        text = read(root / rel)
        for claim, src_rel, symbol, _ in entries:
            if claim not in text:
                continue
            src = read(root / src_rel)
            if symbol in src:
                record(
                    "FAIL",
                    f"negative claim: {rel} says '{claim[:20]}...'",
                    f"but {symbol} exists in {src_rel}",
                )
            else:
                record("PASS", f"negative claim: {claim[:24]}", "still true")


def check_documented_apis_exist(root: Path) -> None:
    """Every API named in the docs must appear in the generated interface."""
    mbti = read(root / "lib" / "pkg.generated.mbti")
    if not mbti:
        code, out = run(["moon", "info"], root)
        mbti = read(root / "lib" / "pkg.generated.mbti")
    if not mbti:
        record("FAIL", "api: lib/pkg.generated.mbti exists", "run `moon info`")
        return

    names = set(re.findall(r"\b(?:pub fn|pub struct|pub enum)\s+([A-Za-z_][\w:<>]*)", mbti))
    flat = set()
    for name in names:
        flat.add(name)
        if "::" in name:
            flat.add(name.split("::", 1)[1])

    docs = read(root / "README.md") + read(root / "项目申报书.md")
    # Identifiers the docs present as callable API.
    referenced = set(re.findall(r"`@moonxz\.([A-Za-z_][\w]*)", docs))
    referenced |= set(re.findall(r"`(XzReader|XzWriter|XzStreamDecoder)`", docs))
    referenced |= set(re.findall(r"`(compress_lzma1|decompress_lzma1|lzma1_properties|lzma1_declared_size|compress_with_check)`", docs))

    missing = sorted(n for n in referenced if n not in flat)
    if missing:
        record("FAIL", "api: documented names exist", ", ".join(missing))
    else:
        record("PASS", "api: documented names exist", f"{len(referenced)} names checked")


def check_external_interop(root: Path) -> None:
    """The decoder must handle bytes produced by a different implementation.

    This is the check that was missing. All 38 pre-review tests passed while
    legal liblzma output at 128 KiB and above failed to decode, because every
    fixture had been produced by MoonXZ itself. Testing only against your own
    encoder cannot detect a shared misunderstanding of the format.
    """
    script = root / "scripts" / "interop.py"
    if not script.exists():
        record("FAIL", "interop: scripts/interop.py exists", "missing")
        return
    code, out = run([sys.executable, str(script)], root)
    if code == 0 and "ok" in out.lower():
        record("PASS", "interop: external liblzma round trip", out.strip()[-80:])
    else:
        record("FAIL", "interop: external liblzma round trip", out.strip()[-300:])


def check_chunk_size_boundaries(root: Path) -> None:
    """Feed the decoder external streams whose size fields sit on boundaries.

    The carry bug lived in an 18-bit field split across two reads, so it only
    appears when the low half is 0xFFFF - that is, when the size is not a
    multiple of 65536. Sizes at exactly 64 KiB pass, which is why a test that
    only used 64 KiB looked like adequate coverage.
    """
    try:
        import lzma
    except ImportError:
        record("UNVERIFIED", "boundary: liblzma boundary sizes", "python lzma unavailable")
        return

    sizes = [65535, 65536, 65537, 131072, 131073, 262144, 1048576]
    tmp = root / "_build" / "self_audit"
    tmp.mkdir(parents=True, exist_ok=True)
    failures = []
    for size in sizes:
        payload = bytes((i * 7 + 13) % 251 for i in range(size))
        # Incompressible data keeps liblzma from merging chunks.
        encoded = lzma.compress(payload, format=lzma.FORMAT_XZ, preset=6)
        src = tmp / f"b_{size}.xz"
        dst = tmp / f"b_{size}.out"
        src.write_bytes(encoded)
        if dst.exists():
            dst.unlink()
        code, out = run(
            ["moon", "run", "-q", "cmd/main", "--", "decompress-file", str(src), str(dst)],
            root,
        )
        if not dst.exists() or dst.read_bytes() != payload:
            failures.append(f"{size}:{(out.strip()[:60] or 'no output')}")

    if failures:
        record("FAIL", "boundary: external sizes decode exactly", "; ".join(failures))
    else:
        record("PASS", "boundary: external sizes decode exactly", f"{len(sizes)} sizes")


def check_malformed_inputs(root: Path) -> None:
    """Malformed input must produce an error, never a panic or a crash."""
    script = root / "scripts" / "fuzz_cli.py"
    if not script.exists():
        record("UNVERIFIED", "robustness: malformed inputs", "scripts/fuzz_cli.py missing")
        return
    code, out = run([sys.executable, str(script), str(root), "80"], root, timeout=1800)
    if "no panics found" in out:
        record("PASS", "robustness: malformed inputs do not panic", "80 inputs")
    else:
        record("FAIL", "robustness: malformed inputs do not panic", out.strip()[-300:])


def check_empty_inputs(root: Path) -> None:
    """Every format must round trip the empty input."""
    tmp = root / "_build" / "self_audit"
    tmp.mkdir(parents=True, exist_ok=True)
    empty = tmp / "empty.bin"
    empty.write_bytes(b"")
    failures = []

    code, out = run(["moon", "run", "-q", "cmd/main", "--", "compress-file",
                     str(empty), str(tmp / "empty.xz")], root)
    if code != 0 or not (tmp / "empty.xz").exists():
        failures.append("xz compress: " + out.strip()[:80])

    for fmt, comp, decomp in (("lzma", "lzma-compress-file", "lzma-decompress-file"),):
        code, out = run(["moon", "run", "-q", "cmd/main", "--", comp,
                         str(empty), str(tmp / f"empty.{fmt}")], root)
        if code != 0:
            failures.append(f"{fmt} compress: " + out.strip()[:80])
            continue
        code, out = run(["moon", "run", "-q", "cmd/main", "--", decomp,
                         str(tmp / f"empty.{fmt}"), str(tmp / f"empty.{fmt}.out")], root)
        if code != 0:
            failures.append(f"{fmt} decompress: " + out.strip()[:80])
        elif (tmp / f"empty.{fmt}.out").read_bytes() != b"":
            failures.append(f"{fmt} round trip produced bytes")

    if failures:
        record("FAIL", "empty input: all formats round trip", "; ".join(failures))
    else:
        record("PASS", "empty input: all formats round trip", "xz and lzma")


def check_repo_hygiene(root: Path) -> None:
    """No build output or caches committed, licence present, CI present."""
    tracked = subprocess.run(
        ["git", "ls-files"], cwd=root, capture_output=True, text=True,
        encoding="utf-8", errors="replace",
    ).stdout.splitlines()

    # `pkg.generated.mbti` is deliberately tracked (see check_interface_committed),
    # so it is not treated as build output here.
    bad = [
        f for f in tracked
        if f.startswith("_build/") or f.startswith(".mooncakes/")
        or f.endswith(".mbti") and "generated" not in f
    ]
    if bad:
        record("FAIL", "hygiene: no build output tracked", ", ".join(bad[:5]))
    else:
        record("PASS", "hygiene: no build output tracked", f"{len(tracked)} files")

    if any(f.startswith("LICENSE") for f in tracked):
        record("PASS", "hygiene: root licence", next(f for f in tracked if f.startswith("LICENSE")))
    else:
        record("FAIL", "hygiene: root licence", "no LICENSE* tracked")

    if any(f.startswith(".github/workflows/") for f in tracked):
        record("PASS", "hygiene: CI workflow tracked", "yes")
    else:
        record("FAIL", "hygiene: CI workflow tracked", "missing")

    if any("THIRD_PARTY" in f for f in tracked):
        record("PASS", "hygiene: third-party notices", "yes")
    else:
        record("FAIL", "hygiene: third-party notices", "missing")


def check_strict_commands(root: Path) -> None:
    """The stricter gates the acceptance guidance treats as positive signals."""
    for label, cmd in (
        ("check --deny-warn --target all", ["moon", "check", "--deny-warn", "--target", "all"]),
        ("fmt --check", ["moon", "fmt", "--check"]),
    ):
        code, out = run(cmd, root)
        if code == 0 or "Finished" in out and "Error" not in out:
            record("PASS", f"strict: {label}", "clean")
        else:
            record("FAIL", f"strict: {label}", out.strip()[-200:])


def check_toolchain_version(root: Path) -> None:
    """moonc must satisfy the stated minimum."""
    code, out = run(["moon", "version", "--all"], root)
    match = re.search(r"moonc v(\d+)\.(\d+)\.(\d+)", out)
    if not match:
        record("FAIL", "toolchain: moonc version readable", out.strip()[:120])
        return
    major, minor, patch = (int(g) for g in match.groups())
    if (major, minor, patch) >= (0, 10, 14):
        record("PASS", "toolchain: moonc >= 0.10.14", f"v{major}.{minor}.{patch}")
    else:
        record("FAIL", "toolchain: moonc >= 0.10.14", f"v{major}.{minor}.{patch}")


def check_interface_committed(root: Path) -> None:
    """The generated interface must be committed and match the current source.

    The official workflow template ends with `moon info && git diff --exit-code`,
    and the acceptance guidance lists reviewing the interface diff as a quality
    signal. With the `.mbti` files untracked that check is vacuous - `git diff`
    does not look at untracked files - which is how it silently did nothing here
    for the whole project.
    """
    tracked = subprocess.run(
        ["git", "ls-files", "*pkg.generated.mbti"], cwd=root,
        capture_output=True, text=True, encoding="utf-8", errors="replace",
    ).stdout.split()
    if not tracked:
        record("FAIL", "interface: pkg.generated.mbti tracked", "no interface committed")
        return
    record("PASS", "interface: pkg.generated.mbti tracked", f"{len(tracked)} files")

    run(["moon", "info"], root)
    diff = subprocess.run(
        ["git", "diff", "--stat", "--", "*pkg.generated.mbti"], cwd=root,
        capture_output=True, text=True, encoding="utf-8", errors="replace",
    ).stdout.strip()
    if diff:
        record("FAIL", "interface: matches current source",
               "moon info produced changes: " + diff.replace("\n", " ")[:160])
    else:
        record("PASS", "interface: matches current source", "no diff after moon info")


def main() -> int:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    print(f"self-audit of {root}\n")

    check_toolchain_version(root)
    check_version_consistency(root)
    check_test_count_claims(root)
    check_negative_claims(root)
    check_documented_apis_exist(root)
    check_repo_hygiene(root)
    check_interface_committed(root)
    check_strict_commands(root)
    check_empty_inputs(root)
    check_chunk_size_boundaries(root)
    check_external_interop(root)
    check_malformed_inputs(root)

    width = max(len(c) for _, c, _ in RESULTS)
    for status, check, detail in RESULTS:
        marker = {"PASS": "  ok ", "FAIL": "FAIL ", "UNVERIFIED": " ??  "}[status]
        print(f"{marker} {check:<{width}}  {detail}")

    failed = [r for r in RESULTS if r[0] == "FAIL"]
    unverified = [r for r in RESULTS if r[0] == "UNVERIFIED"]
    print()
    print(f"{len(RESULTS)} checks: "
          f"{len([r for r in RESULTS if r[0] == 'PASS'])} ok, "
          f"{len(failed)} failed, {len(unverified)} unverified")

    report = root / "_build" / "self_audit_report.json"
    report.parent.mkdir(parents=True, exist_ok=True)
    report.write_text(
        json.dumps([{"status": s, "check": c, "detail": d} for s, c, d in RESULTS],
                   ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    print(f"report: {report}")

    if unverified:
        print("\nUnverified checks are not evidence of correctness.")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
