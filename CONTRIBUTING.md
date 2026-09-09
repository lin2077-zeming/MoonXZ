# Contributing

## Development

Run the standard checks before opening a pull request:

```text
moon check --deny-warn
moon test --deny-warn
moon fmt --check
moon test --target all --deny-warn
```

## Scope

Keep the decoder pure MoonBit and runtime independent. When adding a new
format feature, include:

- a small deterministic fixture or generated test vector
- a roundtrip or malformed-input test
- an entry in `README.md` if the public feature matrix changes
- source and license notes if code or data comes from another project

Do not claim compressed-encoder support until the range encoder and match
finder have interoperability tests against an independent XZ implementation.
