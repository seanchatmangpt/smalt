# clap-noun-verb Pack Integration: smaltctl

## Summary

`cli/` is a real Rust CLI (`smaltctl`) manufactured by ggen 26.10.11 from the
clap-noun-verb pack family. The RDF graph (`cli/ontology.ttl`) is the source of
truth; `cli/ggen.toml` composes six packs; `ggen sync run` projects
`Cargo.toml`, `src/main.rs`, `src/lib.rs`, `src/generated_{cli,behavior,
boundaries}.rs`, `tests/`, and `cli/docs/command-reference.md` deterministically.
Hand-written domain logic lives only in `src/custom_handlers.rs` (the packs'
`cnv:CustomBehavior` seam, generated once via `unless_exists: true` and never
overwritten).

## Packs consumed (absolute paths, local marketplace checkout)

- clap-noun-verb-schema-pack 1.1.0 — vocabulary + 16 fail-closed admission gates
- clap-noun-verb-crate-pack 1.0.0 — Cargo.toml, main.rs, lib.rs, custom_handlers scaffold
- clap-noun-verb-routing-pack — generated_cli.rs typed routes
- clap-noun-verb-behavior-pack — generated_behavior.rs closed BehaviorSpec interpreter
- clap-noun-verb-boundary-pack — generated_boundaries.rs
- clap-noun-verb-verification-pack — tests + docs/command-reference.md

## Surface

Nouns: status, kv, blob, cosmos, sb, doctor, court (13 commands, all
`cnv:CustomBehavior`; zero closed-primitive behaviors).

## Environment

| Variable | Default | Meaning |
|---|---|---|
| SMALT_ARM_URL | http://127.0.0.1:9443 | ARM gateway base URL |
| SMALT_EGRESS_URL | http://127.0.0.1:8443 | Egress plane base URL |
| SMALT_BEARER_TOKEN | (none) | Optional Authorization: Bearer on every request |
| SMALT_BLOB_ACCOUNT | smaltdev | Blob account segment |
| SMALT_REPO | . | Repo root for doctor/court proxies |

## Regeneration

    cd cli && ggen sync run

Regeneration never clobbers `src/custom_handlers.rs`. It WILL refuse if a
generated doc (`cli/docs/command-reference.md`) would differ — delete it and
re-sync, or add `force: true` in the owning pack template config.

## Gate admission lessons (schema-pack gates that refused and how they closed)

1. `040_value_constraints`: `cnv:name` is `^[a-z][a-z0-9-]*$` (hyphens, no
   underscores) while `cnv:fieldName` allows snake_case — use `cnv:name
   "blob-name"`, `cnv:fieldName "blob_name"`.
2. Same gate: `cnv:testValue` must be a simple lexical token (`"resources"`,
   not `"resources | count"`).
3. `050_semantic_closure`: an argument with `position 0` (option) must carry
   `cnv:longFlag` matching the hyphenated field name.
4. `080_owned_nodes`: every argument individual must be owned by exactly ONE
   command — no shared argument individuals across commands; duplicate
   per-command argument individuals instead.

## Live receipt (2026-10-15, substrate PID 50296, private ports)

- Build: `cargo build --release` exit 0; `cargo test --release` exit 0 (1 test).
- `smaltctl status list` (SMALT_ARM_URL=http://127.0.0.1:29443,
  SMALT_EGRESS_URL=http://127.0.0.1:28443, anonymous auth mode) exit 0 with the
  real subscription record and /metadata/endpoints envelope.
- kv create/get/list exit 0 with real key records; `kv create --release-policy
  ...` produces an exportable key; `kv release` correctly surfaces substrate
  SKR admission 403 `UnauthorizedAttestation` (attested-CVM required — correct
  closed behavior, not a CLI defect).
- blob list (containers + blobs) exit 0 with real XML enumeration; put/get
  exit 0 round-trip after a one-time container create (container create is not
  on the CLI surface; `PUT /{account}/{container}?restype=container`).
- cosmos query exit 0 with real ResourceGraph envelope (`{"count":0,...}`).
- sb peek exit 0 (`[]`).
- doctor run exit 0: "[PASS] Smalt doctor diagnostic court passed."
- court run: the CLI proxy works (streams `just court`, propagates exit code);
  the underlying court is currently RED at `test-offline` on a PRE-EXISTING
  compile error in test/runtime_contracts_test.exs:81 (shared-checkout drift,
  outside this lane's owned files).
