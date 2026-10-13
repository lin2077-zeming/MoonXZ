#!/usr/bin/env python3
"""Acceptance-grade audit for a MoonBit project.

Companion to the `moonbit-acceptance-review` skill. The skill explains the
reasoning; this file implements the checks that can be made mechanical so they
do not depend on remembering to do them.

Design rules, learned from a project that passed a checklist review and then
failed acceptance:

1. Report UNVERIFIED, never assume. A check that cannot run is not a pass.
2. Never accept "the document says so" as evidence that a feature exists.
3. Compare against a single source of truth instead of trusting repeated
   copies of a number.
4. Look for negative drift too: a document claiming something is NOT supported
   when the code has since implemented it.

Almost everything here is project-agnostic. The parts that cannot be - which
external tool decodes the project's output, which inputs stress its boundaries -
live in a JSON config so a project supplies them rather than editing this file.

Config file (default `acceptance_audit.json` in the repo root):

{
  "module": "owner/name",
  "toolchain_min": "0.10.14",
  "version_locations": [
    {"file": "README.md", "pattern": "current version is `([^`]+)`"}
  ],
  "count_claims": [
    {"file": "README.md", "pattern": "(\\\\d+)\\\\s*tests", "source": "moon test"}
  ],
  "negative_claims": [
    {"file": "proposal.md", "text": "no streaming interface",
     "refuted_by": {"file": "src/stream.mbt", "pattern": "pub fn .*Stream"}}
  ],
  "empty_input_required": true,
  "boundary_cases": [
    {"name": "128 KiB", "make": "python:scripts/make_case.py:128k"}
  ],
  "external_interop": ["python3", "scripts/interop.py"],
  "fuzz": ["python3", "scripts/fuzz_cli.py", ".", "100"]
}

Usage: python3 acceptance_audit.py [repo-root]
Exit code 1 if any check fails.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

RESULTS: list[tuple[str, str, str]] = []


def record(status: str, check: str, detail: str) -> None:
    RESULTS.append((status, check, detail))


def run(cmd: list[str], cwd: Path, timeout: int = 1800) -> tuple[int, str]:
    try:
        proc = subprocess.run(
            cmd, cwd=cwd, capture_output=True, timeout=timeout,
            text=True, encoding="utf-8", errors="replace",
        )
    except FileNotFoundError:
        return 127, f"command not found: {cmd[0]}"
    except subprocess.TimeoutExpired:
        return 124, f"timed out: {' '.join(cmd)}"
    return proc.returncode, (proc.stdout or "") + (proc.stderr or "")


def read(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except OSError:
        return ""


def load_config(root: Path) -> dict:
    path = root / "acceptance_audit.json"
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        record("FAIL", "config: acceptance_audit.json parses", str(exc))
        return {}


# --- toolchain -------------------------------------------------------------

def check_toolchain(root: Path, config: dict) -> None:
    code, out = run(["moon", "version", "--all"], root)
    if code != 0:
        record("FAIL", "toolchain: moon available", out.strip()[:160])
        return
    match = re.search(r"moonc v(\d+)\.(\d+)\.(\d+)", out)
    if not match:
        record("FAIL", "toolchain: moonc version readable", out.strip()[:160])
        return
    have = tuple(int(g) for g in match.groups())
    record("PASS", "toolchain: moonc detected", "v" + ".".join(map(str, have)))

    wanted = config.get("toolchain_min")
    if not wanted:
        record("UNVERIFIED", "toolchain: meets declared minimum",
               "no toolchain_min in config")
        return
    need = tuple(int(p) for p in str(wanted).split("."))
    if have >= need:
        record("PASS", "toolchain: meets declared minimum", f"{wanted} required")
    else:
        record("FAIL", "toolchain: meets declared minimum",
               f"have {have}, need {need}")


# --- single source of truth ------------------------------------------------

def check_versions(root: Path, config: dict) -> None:
    manifest = read(root / "moon.mod")
    match = re.search(r'^version\s*=\s*"([^"]+)"', manifest, re.M)
    if not match:
        record("FAIL", "version: moon.mod declares one", "no version field")
        return
    version = match.group(1)
    record("PASS", "version: moon.mod", version)

    for entry in config.get("version_locations", []):
        text = read(root / entry["file"])
        found = re.findall(entry["pattern"], text)
        if not found:
            record("UNVERIFIED", f"version: {entry['file']}",
                   "pattern matched nothing (stale pattern?)")
            continue
        for value in found:
            if value != version:
                record("FAIL", f"version: {entry['file']} agrees",
                       f"says {value}, moon.mod says {version}")
            else:
                record("PASS", f"version: {entry['file']} agrees", value)

    # A hardcoded copy in source is the usual cause of drift.
    for src_entry in config.get("version_constants", []):
        text = read(root / src_entry["file"])
        for value in re.findall(src_entry["pattern"], text):
            if value != version:
                record("FAIL", f"version: {src_entry['file']} constant",
                       f"is {value}, moon.mod says {version}")
            else:
                record("PASS", f"version: {src_entry['file']} constant", value)


def check_counts(root: Path, config: dict) -> None:
    claims = config.get("count_claims", [])
    if not claims:
        record("UNVERIFIED", "counts: configured", "no count_claims in config")
        return

    measured: dict[str, str] = {}
    for entry in claims:
        if entry["source"] not in measured:
            code, out = run(["moon", "test", "--target", "wasm"], root)
            m = re.search(r"Total tests:\s*(\d+)", out)
            if not m:
                record("FAIL", "counts: suite reports a total", out.strip()[-160:])
                return
            measured[entry["source"]] = m.group(1)

        actual = measured[entry["source"]]
        text = read(root / entry["file"])
        found = re.findall(entry["pattern"], text)
        if not found:
            record("UNVERIFIED", f"counts: {entry['file']}",
                   "pattern matched nothing")
            continue
        for value in found:
            if str(value) != actual:
                record("FAIL", f"counts: {entry['file']} agrees",
                       f"claims {value}, actual {actual}")
            else:
                record("PASS", f"counts: {entry['file']} agrees", actual)


# --- claim reconciliation --------------------------------------------------

def check_negative_claims(root: Path, config: dict) -> None:
    """A "not supported" claim must still be true.

    Only half of drift points the obvious way. A document written early says a
    feature is out of scope; the feature then gets built; the sentence stays.
    A reviewer reconciling completion against the proposal reads that as work
    that was promised and not delivered.
    """
    claims = config.get("negative_claims", [])
    if not claims:
        record("UNVERIFIED", "drift: negative claims checked",
               "no negative_claims in config")
        return
    for entry in claims:
        text = read(root / entry["file"])
        if entry["text"] not in text:
            record("PASS", f"drift: '{entry['text'][:28]}'",
                   "claim no longer present")
            continue
        ref = entry["refuted_by"]
        if re.search(ref["pattern"], read(root / ref["file"])):
            record("FAIL", f"drift: '{entry['text'][:28]}'",
                   f"still claimed but {ref['file']} matches /{ref['pattern']}/")
        else:
            record("PASS", f"drift: '{entry['text'][:28]}'", "still true")


def check_documented_apis(root: Path, config: dict) -> None:
    """Every API the docs name must exist in the generated interface."""
    interface_dirs = config.get("interface_dirs", ["."])
    names: set[str] = set()
    found_any = False
    for rel in interface_dirs:
        for mbti in (root / rel).glob("**/pkg.generated.mbti"):
            if "_build" in mbti.parts or ".mooncakes" in mbti.parts:
                continue
            found_any = True
            text = read(mbti)
            for m in re.finditer(r"(?:pub fn|pub struct|pub enum)\s+([A-Za-z_][\w:<>]*)", text):
                names.add(m.group(1))
                if "::" in m.group(1):
                    names.add(m.group(1).split("::", 1)[1])

    if not found_any:
        code, _ = run(["moon", "info"], root)
        for mbti in root.glob("**/pkg.generated.mbti"):
            if "_build" in mbti.parts or ".mooncakes" in mbti.parts:
                continue
            found_any = True
            text = read(mbti)
            for m in re.finditer(r"(?:pub fn|pub struct|pub enum)\s+([A-Za-z_][\w:<>]*)", text):
                names.add(m.group(1))
                if "::" in m.group(1):
                    names.add(m.group(1).split("::", 1)[1])

    if not names:
        record("UNVERIFIED", "api: documented names exist",
               "no generated interface found; is it committed?")
        return

    pattern = config.get("api_reference_pattern")
    if not pattern:
        record("UNVERIFIED", "api: documented names exist",
               "no api_reference_pattern in config")
        return

    referenced: set[str] = set()
    for doc_entry in config.get("doc_files", []):
        referenced |= set(re.findall(pattern, read(root / doc_entry)))

    missing = sorted(n for n in referenced if n not in names)
    if missing:
        record("FAIL", "api: documented names exist",
               ", ".join(missing[:8]))
    else:
        record("PASS", "api: documented names exist",
               f"{len(referenced)} names against {len(names)} symbols")


# --- hygiene ---------------------------------------------------------------

def check_hygiene(root: Path, config: dict) -> None:
    code, out = run(["git", "ls-files"], root)
    if code != 0:
        record("FAIL", "hygiene: git repository", "not a git repo")
        return
    tracked = out.splitlines()
    record("PASS", "hygiene: tracked files", str(len(tracked)))

    ignore = config.get("ignored_paths", ["_build/", "target/", ".mooncakes/"])
    bad = [f for f in tracked if any(f.startswith(p) for p in ignore)]
    if bad:
        record("FAIL", "hygiene: no build output tracked", ", ".join(bad[:5]))
    else:
        record("PASS", "hygiene: no build output tracked", "clean")

    if any(f.upper().startswith("LICENSE") or f.upper().startswith("LICENCE")
           for f in tracked):
        record("PASS", "hygiene: root licence", "present")
    else:
        record("FAIL", "hygiene: root licence", "no LICENSE* tracked")

    if any(f.startswith(".github/workflows/") for f in tracked):
        record("PASS", "hygiene: CI workflow", "present")
    else:
        record("FAIL", "hygiene: CI workflow", "no .github/workflows/ tracked")

    if any("THIRD_PARTY" in f.upper() or "NOTICE" in f.upper() for f in tracked):
        record("PASS", "hygiene: third-party notices", "present")
    else:
        record("UNVERIFIED", "hygiene: third-party notices",
               "none found; required if any upstream is referenced")

    porcelain = run(["git", "status", "--porcelain"], root)[1].strip()
    if porcelain:
        record("UNVERIFIED", "hygiene: working tree clean",
               f"{len(porcelain.splitlines())} modified paths")
    else:
        record("PASS", "hygiene: working tree clean", "clean")


# --- interface drift -------------------------------------------------------

def check_interface_committed(root: Path) -> None:
    """The official template's `moon info && git diff --exit-code`.

    Vacuous unless the interface is tracked: git diff ignores untracked files,
    so an untracked pkg.generated.mbti makes the check always pass.
    """
    code, out = run(["git", "ls-files", "*pkg.generated.mbti"], root)
    tracked = [line for line in out.splitlines() if line.strip()] if code == 0 else []
    if not tracked:
        record("FAIL", "interface: pkg.generated.mbti tracked",
               "not tracked, so `moon info && git diff` checks nothing")
        return
    record("PASS", "interface: pkg.generated.mbti tracked", f"{len(tracked)} files")

    run(["moon", "info"], root)
    diff = run(["git", "diff", "--stat", "--", "*pkg.generated.mbti"], root)[1].strip()
    if diff:
        record("FAIL", "interface: matches source",
               "moon info changed it; commit the result")
    else:
        record("PASS", "interface: matches source", "no diff")


# --- strict commands -------------------------------------------------------

def check_strict_commands(root: Path, config: dict) -> None:
    commands = config.get("strict_commands", [
        ["moon", "check", "--deny-warn", "--target", "all"],
        ["moon", "test", "--deny-warn", "--target", "all"],
        ["moon", "fmt", "--check"],
        ["moon", "bundle", "--all"],
    ])
    for cmd in commands:
        code, out = run(cmd, root)
        label = " ".join(cmd)
        if code == 0:
            record("PASS", f"strict: {label}", "clean")
        else:
            record("FAIL", f"strict: {label}", out.strip()[-200:])


# --- behaviour -------------------------------------------------------------

def check_external_interop(root: Path, config: dict) -> None:
    """Cross-implementation validation.

    The single most valuable check here. Testing only against your own encoder
    cannot reveal a misunderstanding shared by the encoder and the decoder.
    """
    cmd = config.get("external_interop")
    if not cmd:
        record("UNVERIFIED", "interop: external implementation",
               "no external_interop in config - interop is NOT verified")
        return
    code, out = run(cmd, root)
    if code == 0:
        record("PASS", "interop: external implementation", out.strip()[-120:])
    else:
        record("FAIL", "interop: external implementation", out.strip()[-300:])


def check_boundary_cases(root: Path, config: dict) -> None:
    """Run whatever the project declares as its boundary cases."""
    cases = config.get("boundary_cases", [])
    if not cases:
        record("UNVERIFIED", "boundary: declared cases",
               "no boundary_cases in config")
        return
    failures = []
    for case in cases:
        cmd = case.get("command")
        if not cmd:
            failures.append(f"{case.get('name', '?')}: no command")
            continue
        code, out = run(cmd, root)
        if code != 0:
            failures.append(f"{case.get('name', '?')}: {out.strip()[:80]}")
    if failures:
        record("FAIL", "boundary: declared cases pass", "; ".join(failures))
    else:
        record("PASS", "boundary: declared cases pass", f"{len(cases)} cases")


def check_empty_input(root: Path, config: dict) -> None:
    cmd = config.get("empty_input_check")
    if not config.get("empty_input_required"):
        record("UNVERIFIED", "empty input: covered", "not required by config")
        return
    if not cmd:
        record("UNVERIFIED", "empty input: covered",
               "empty_input_required set but no empty_input_check command")
        return
    code, out = run(cmd, root)
    if code == 0:
        record("PASS", "empty input: round trips", "ok")
    else:
        record("FAIL", "empty input: round trips", out.strip()[-200:])


def check_fuzz(root: Path, config: dict) -> None:
    cmd = config.get("fuzz")
    if not cmd:
        record("UNVERIFIED", "robustness: malformed inputs",
               "no fuzz command in config - robustness is NOT verified")
        return
    code, out = run(cmd, root)
    if code == 0:
        record("PASS", "robustness: malformed inputs", out.strip()[-120:])
    else:
        record("FAIL", "robustness: malformed inputs", out.strip()[-300:])


# --- report ----------------------------------------------------------------

def main() -> int:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    print(f"acceptance audit of {root}\n")

    config = load_config(root)
    if not config:
        print("No acceptance_audit.json found. Running the project-agnostic "
              "checks only; interop, boundary and robustness will report "
              "UNVERIFIED.\n")

    check_toolchain(root, config)
    check_versions(root, config)
    check_counts(root, config)
    check_negative_claims(root, config)
    check_documented_apis(root, config)
    check_hygiene(root, config)
    check_interface_committed(root)
    check_strict_commands(root, config)
    check_empty_input(root, config)
    check_boundary_cases(root, config)
    check_external_interop(root, config)
    check_fuzz(root, config)

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

    out_path = root / "_build" / "acceptance_audit_report.json"
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(
        json.dumps([{"status": s, "check": c, "detail": d} for s, c, d in RESULTS],
                   ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    print(f"report: {out_path}")

    if unverified:
        print("\nUNVERIFIED is not a pass. Supply the config entries those "
              "checks need, or state in the report that the area is unverified.")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
