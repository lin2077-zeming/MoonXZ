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

This dependency is only used by `cmd/main`; the `lib` package does not depend
on the file system or on this module.
