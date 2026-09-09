# MoonXZ contributor notes

- The public API lives in the root `moonxz` package.
- Core decoding logic must remain pure MoonBit and runtime independent.
- Keep malformed-input handling explicit and testable.
- Run `moon check`, `moon test`, and `moon fmt --check` before committing.
