# Versioning — ask-ag-ui

This file is this repository's **canonical versioning policy**. When
anything else in the repo disagrees with it, this file wins.

## Semantic Versioning

Versions are `MAJOR.MINOR.PATCH`, following
[Semantic Versioning 2.0.0](https://semver.org):

- **PATCH** — backwards-compatible bug fixes only.
- **MINOR** — backwards-compatible new functionality.
- **MAJOR** — breaking changes.

### Pre-1.0 (0.x.y)

While the major version is `0`, the public API is not frozen: MINOR
carries the breaking changes (removing/renaming public API, changing
defaults or behavior). There is no separate major bump until 1.0.0.

## All releases go through gemchain

This is an `ask-*` gem, so **every** release runs through **gemchain**
from the workspace root — never `rake release`, never a hand-run
`gem build` / `gem push`:

```bash
cd /Users/kaka/Code/ask-rb
gemchain update ask-ag-ui <new-version>
```

## Changelog workflow (Unreleased)

- `CHANGELOG.md` keeps an `## [Unreleased]` section at the top.
- Every user-facing change lands under `Unreleased` in the same commit
  that introduces it, using Keep a Changelog headings (`Added`,
  `Changed`, `Fixed`, `Removed`).
- At release time, rename `## [Unreleased]` to `## [X.Y.Z] — YYYY-MM-DD`
  and open a fresh empty `## [Unreleased]` above it.
