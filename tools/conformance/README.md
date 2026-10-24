# MoonXZ conformance

`moonxz-conformance` is a MoonBit-first conformance and differential runner for
XZ/LZMA implementations. It reads a JSON manifest, verifies every fixture hash,
runs each case against MoonXZ and `aurora0x27/lzma-mbt`, and writes a
machine-readable report with explicit `pass`, `fail`, and `skip` results.

The module is deliberately separate from the published
`lin2077-zeming/moonxz` library. That keeps the differential dependency out of
the public library package while allowing both implementations to execute in the
same MoonBit process.

## Run

From the repository root:

```text
moon check --deny-warn --target all
moon test --deny-warn --target all
moon run tools/conformance/cmd/main -- run tools/conformance/corpus/manifest.json _build/conformance-report.json
```

Or from this module:

```text
moon run cmd/main -- run corpus/manifest.json _build/report.json
```

The current corpus contains 24 cases and produces 48 implementation checks. The
`xz-output-limit` case intentionally skips `lzma-mbt` because that implementation
exposes a dictionary-memory limit rather than an uncompressed-output limit.
The latest checked-in run is `docs/conformance-report.json`.

## Corpus

`corpus/manifest.json` describes every fixture and its provenance. Each case
records:

- a stable `id`, operation, input path, expected-output path, and SHA-256 hashes;
- the container format and optional check, chunk size, output cap, or
  concatenated-stream mode;
- any implementation-specific expectation such as `unsupported` or `skip`;
- the external source used to produce or independently validate the fixture.

Coverage includes XZ and `.lzma`, all four XZ checks, Delta, x86 BCJ, all six
currently unsupported BCJ refusal paths, ARM64 differential decode, concatenated
streams with padding, the 128 KiB LZMA2 size boundary, one-byte streamed input,
truncated and corrupted streams, output limits, and cross-implementation XZ
roundtrips.

## Regenerate

The runner does not invoke external programs. Corpus regeneration is an explicit
developer action:

```text
python tools/conformance/scripts/regenerate.py
```

Python 3.14 liblzma generates the non-ARM64 fixtures. ARM64 needs XZ Utils 5.6 or
newer; the script defaults to a local XZ Utils 5.8.3 executable at
`_build/xz583/bin_x86-64/xz.exe`, or honours `XZ_BIN`. The ARM64 stream is written
by `lzma-mbt` and then decoded byte-for-byte by the official `xz` executable
before it is accepted.

## License and provenance

The conformance module uses `aurora0x27/lzma-mbt@0.1.0` as an Apache-2.0
dependency. It does not copy that implementation's code. The ARM64 fixture is a
cross-implementation test artifact validated by XZ Utils 5.8.3; XZ Utils is not
redistributed in this repository.
