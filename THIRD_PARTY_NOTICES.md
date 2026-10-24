# Third-Party Notices

## github.com/ulikunitz/xz

MoonXZ's XZ container and LZMA decoder implementation was written after
studying the XZ file format specification and the pure Go implementation at:

- Project: `github.com/ulikunitz/xz`
- Author: Ulrich Kunitz
- Version used for algorithm review: `v0.5.15`
- License: BSD-3-Clause
- Source: https://github.com/ulikunitz/xz

The BSD-3-Clause license text is included at:

- `LICENSES/BSD-3-Clause-ulikunitz-xz.txt`

No Go source file is copied verbatim into this repository. The MoonBit code
uses different data structures and APIs and adds its own error model, bounds
checks, tests, and build configuration. This notice is retained to satisfy
attribution and license obligations for the referenced implementation.

## moonbitlang/x

The file CLI uses:

- Project: `moonbitlang/x`
- Source: https://github.com/moonbitlang/x
- License: Apache-2.0

This dependency is used by `cmd/main` and the independent
`tools/conformance` module; the published `lib` package does not depend on the
file system or on this module.

## aurora0x27/lzma-mbt

The independent conformance module uses this library as a second implementation
under test:

- Project: `aurora0x27/lzma-mbt`
- Version: `0.1.0`
- Source: https://github.com/aurora0x27/lzma-mbt
- License: Apache-2.0

No source file from that project is copied into MoonXZ. The conformance runner
imports the published MoonBit package and compares observable behaviour through
the committed corpus.

## XZ Utils

The corpus generation and independent ARM64 validation use the official XZ
Utils `5.8.3` Windows executable as an external oracle:

- Project: XZ Utils
- Source: https://github.com/tukaani-project/xz/releases/tag/v5.8.3
- License: see the upstream release; the executable is not redistributed here

The committed ARM64 fixture is a test artifact produced by `lzma-mbt` and
validated byte-for-byte with that executable before being added to the corpus.
