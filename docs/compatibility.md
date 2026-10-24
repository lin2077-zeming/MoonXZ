# MoonXZ compatibility matrix

This document pins the external contract MoonXZ claims and links each claim to
an executable check. It describes the repository version `0.4.5`.

## Normative references

- XZ container: XZ Utils `xz-file-format.txt` from **XZ Utils 5.8.3**
  (<https://github.com/tukaani-project/xz/blob/v5.8.3/doc/xz-file-format.txt>).
- Legacy `.lzma` container: XZ Utils `lzma-file-format.txt` from **XZ Utils
  5.8.3** (<https://github.com/tukaani-project/xz/blob/v5.8.3/doc/lzma-file-format.txt>).
- Filter IDs: XZ Utils `src/liblzma/common/filter_common.c` and the simple
  filter implementations under `src/liblzma/simple/` at tag `v5.8.3`.
- Cross-implementation evidence: MoonXZ and `aurora0x27/lzma-mbt@0.1.0` both
  consume the committed corpus in `tools/conformance/corpus/manifest.json`.
  The independent external oracle is the official XZ Utils 5.8.3 `xz.exe` for
  ARM64 and Python 3.14's liblzma binding for the other committed fixtures.

## Support matrix

`yes` means code exists, the cited test passes, and unsupported paths fail
explicitly. It does not mean byte-identical encoder output.

| Area | Decode | Encode | Evidence / limitation |
| --- | :---: | :---: | --- |
| XZ container (`fd 37 7a 58 5a 00`) | yes | yes | `xz-empty`, `xz-hello-*`, `roundtrip-*` |
| Legacy `.lzma` container | yes | yes | `lzma-sized`, `lzma-end-marker` |
| Raw LZMA2 container | no | no | Outside the current public API; not claimed |
| Automatic `.xz` / `.lzma` detection | no | N/A | Callers select the container API explicitly |
| None check | yes | yes | `xz-hello-none` |
| CRC32 | yes | yes | `xz-hello-crc32`, known vector tests |
| CRC64 / XZ | yes | yes | `xz-hello-crc64`, `roundtrip-*` |
| SHA-256 | yes | yes | `xz-hello-sha256` |
| Single Block | yes | yes | `xz-hello-crc64` |
| Multiple Blocks in one Stream | yes | yes | Writer/Reader and multi-chunk tests |
| Concatenated Streams + Stream Padding | yes | N/A | `xz-concatenated-padding` |
| Index / Footer CRC and backward size | yes | yes | Core container tests |
| Chunk-fed decoding | yes | N/A | `xz-hello-stream-1-byte`; arbitrary chunk sizes supported |
| Output-size cap | yes | N/A | `xz-output-limit` |
| Delta filter | yes | yes | `xz-delta`; distances 1..256 in core tests |
| x86 BCJ filter | yes | yes | `xz-x86`; liblzma bidirectional fixture |
| ARM BCJ | no | no | `xz-arm`; MoonXZ returns `Unsupported`, harness compares with `lzma-mbt` |
| ARM64 BCJ | no | no | `xz-arm64`; official xz 5.8.3 validates the fixture, MoonXZ returns `Unsupported` |
| ARM-Thumb BCJ | no | no | `xz-armthumb`; explicit `Unsupported`, `lzma-mbt` decodes |
| PowerPC BCJ | no | no | `xz-powerpc`; explicit `Unsupported`, `lzma-mbt` decodes |
| IA-64 BCJ | no | no | `xz-ia64`; explicit `Unsupported`, `lzma-mbt` decodes |
| SPARC BCJ | no | no | `xz-sparc`; explicit `Unsupported`, `lzma-mbt` decodes |
| Compression levels 0..9 | N/A | yes | Level and ratio tests; level 0 emits stored LZMA2 chunks |
| `Preset.extreme` | N/A | no | Not implemented and not claimed |
| Optimal parsing | N/A | no | Literal and normal-match encoding only |
| Full-file CLI streaming writes | N/A | no | `moonbitlang/x/fs` lacks append; library decoder itself is chunk-fed |

## ARM64 evidence

`xz-arm64` uses a 521-byte payload containing ARM64 `BL` and `ADRP` instruction
patterns. `lzma-mbt` writes an XZ Stream with a legal `ARM64 -> LZMA2` filter
chain and CRC64. The committed fixture was decoded byte-for-byte by official XZ
Utils 5.8.3 before it entered the corpus.

MoonXZ does not implement that filter in `0.4.5`. The conformance runner therefore
expects `Unsupported` from MoonXZ and exact plaintext from `lzma-mbt`. This is a
version boundary with a future implementation path, not a claim that the XZ
filter is invalid or permanently excluded.

## Chunk-decoding evidence

`xz-hello-stream-1-byte` feeds every byte separately through
`XzStreamDecoder`. The fixture is produced by Python liblzma and omits the
optional compressed size in the Block Header, which is the common external XZ
shape. This case exposed a real `0.4.4` defect: an incomplete block could be
reported as `Truncated` before more bytes arrived. `0.4.5` fixes the scanner path
and keeps the fixture as a regression test.

## Reproducing the evidence

```text
moon check --deny-warn --target all
moon test --deny-warn --target all
moon fmt --check
moon run tools/conformance/cmd/main -- run tools/conformance/corpus/manifest.json _build/conformance-report.json
```

The report has one result per case and implementation. A skipped check is shown
explicitly rather than counted as a pass. Fixture SHA-256 values are verified
before any case runs. The current checked-in result is
`docs/conformance-report.json` (24 cases, 47 pass, 0 fail, 1 intentional skip).
