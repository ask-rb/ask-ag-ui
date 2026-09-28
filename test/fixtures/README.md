# test/fixtures/ag_ui.json — provenance

This is the AG-UI protocol's canonical JSON Schema: every event and model
the suite validates emitted frames against. It is generated from the
reference Python SDK's pydantic models (`ag_ui.core` events, types, and
capabilities — 77 models), with wire keys in camelCase exactly as
`@ag-ui/core` sends them. The file's own `$comment` says the same:
generated, do not edit.

The copy vendored here came from the reference implementation's
`data/ag_ui.json`. It is a test fixture only: nothing at runtime reads it
(the emitter builds frames from `ag-ui-protocol` types, which carry their
own guarantees). It is deliberately _not_ shipped in the gem
(`spec.files` covers `lib/` plus the top-level docs) — it exists so a
fresh clone can run the conformance check with nothing outside the repo.

## Refreshing

When the protocol gains or changes events, refresh the copy from the
source of truth and re-run the suite:

```
cp <reference-checkout>/data/ag_ui.json test/fixtures/ag_ui.json
bundle exec rake test
```

If the suite fails after a refresh, the emitter (or the protocol gem it
builds on) disagrees with the new schema — that is the check working.
Update the translation, never hand-edit this file to make red green.

## A missing fixture must fail loudly

`test/test_helper.rb` resolves this file through a repo-relative path and
reads it eagerly. If the fixture is absent, `File.read` raises `ENOENT`
and the suite errors — validation is never skipped.
