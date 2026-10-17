# Canonical Public Projection — pack integration receipt

Lane: canonical-projection · 2026-10-14 · checkout `~/smalt` (one canonical checkout, no worktree)

## What landed

- `lib/smalt/projection/canonical.ex` (new): `Smalt.Projection.Canonical` —
  deterministic public capability document over `Smalt.Registry` (types, SHACL
  shape bindings, api-versions, plane endpoints); `capability_document/0`,
  `json/0`, `write/0` emitting `docs/capabilities.json`. Plus
  `Smalt.Projection.Canonical.Entry` — the (a) Ash read resource over
  compile-time Registry attrs (`Ash.DataLayer.Simple` + manual `RegistryRead`,
  read-only, exactly one `:read` action) — and its own
  `Smalt.Projection.Canonical.Domain`, deliberately separate from
  `Smalt.Semantic.Domain` so the public surface can never inherit a
  Store-backed action.
- `docs/capabilities.json` (generated, deterministic): 41 admitted types
  (re-counted on disk 2026-10-16) with
  shape + apiVersion each, endpoints `{controlPlane: 9443, dataPlane: 8443,
  amqp: 5672, eventHubs: 5673}`. Regenerate with
  `mix run -e 'Smalt.Projection.Canonical.write()'` (idempotent byte-identical).
- `test/canonical_projection_test.exs` (new): three fence families —
  1. no-drift: doc == Registry-derived truth (types, per-type shape/apiVersion,
     order, endpoint ports, no-silent-subset);
  2. artifact fence: on-disk `docs/capabilities.json` == rendered `json/0`
     (stale generated artifact fails the suite);
  3. grep fence: rendered doc and on-disk doc contain none of
     connectionString/accountKey/primaryKey/sharedKey/sharedAccessKey/
     clientSecret/password/secret/sas, nor Store internals
     (`smalt_resources`, `smalt_ledger_transactions`, `:smalt_store`,
     `Smalt.Store`).
  Plus Ash-surface tests: read returns exactly one entry per admitted type
  with Registry attrs, and the resource is read-only (single `:read` action).

## Pack integration (c): ggen sync assessment

The three packs were read, not synced:

- `canonical-ash-projection-generator` queries target the `apg:*`
  vocabulary (`apg:ProjectionProfile`, `apg:Resource`, `apg:attributeName`,
  `apg:ashType`) — smalt's ontology vocabulary has no `apg:` terms, so
  adapting the `.rq` files is NOT trivial and was not forced.
- `xaas-public-ash-projection-pack`'s `semantic-map.rq` targets
  `sh:targetClass` property shapes; smalt's Registry models type→shape
  *bindings*, not per-property SHACL property shapes, so the query's output
  shape does not match the required capability doc either.

What WAS carried over is the packs' projection *pattern*: admitted-surface
only, read-only Ash resource, rendered public map, gates comparing the
rendered artifact against the admitted truth. The projection chain remains
ontology → `Smalt.Registry` (ggen-projected) → `Smalt.Projection.Canonical`
(derived at compile time) — no hand-typed truth anywhere in the chain.

## Verification (receipt)

Gate (executed, exit 0):

```
MIX_BUILD_ROOT=_build-lanecanonical MIX_ENV=test \
  mix test --no-start test/canonical_projection_test.exs
# 11 tests, 0 failures   (Finished in 0.3 seconds)
```

`--no-start` + in-module `setup_all` app boot is required while a concurrent
lane's keeper holds `:mcp_port` 9545 (no `SMALT_TEST_MCP_PORT` override
exists); without it the suite aborts at `Smalt.Application` start with
`:eaddrinuse` before any test runs. With the keeper gone, plain
`mix test test/canonical_projection_test.exs` is equivalent.

Two real runs of `Smalt.Projection.Canonical.write/0` produced
`docs/capabilities.json`; the drift fence re-derives it from the Registry on
every test run.

## Environment notes (shared-tree conditions during this lane)

- Shared compile churn from concurrent lanes: `semantic_epoch.ex`,
  `telemetry/semconv/registry.ex`, `revops.ex`, `mcp/router.ex`,
  `AmqpDialect.ex` (double-generated module-name collision) each broke the
  shared compile transiently while their owning lanes iterated. No unblock
  fix to another lane's file was applied — every failure cleared on its
  owner's next write; this lane only retried in a stable window.
- Build isolation: `MIX_BUILD_ROOT=_build-lanecanonical` (lease; to be
  deleted at integration).

## Falsifiers

- Drift: edit `Smalt.Registry` (add/change a type, shape, version, or port)
  without regenerating → `docs/capabilities.json` fence test fails.
- Leak: add a Store table name or secret-shaped token to the doc → grep
  fence fails.
- Authority creep: add a write action to `Canonical.Entry` → read-only test
  fails.

## Standing

PARTIAL_ALIVE: gate test green on the lane build root; artifact generated and
fence-tested. Not yet wired to `GET /capabilities` (router mount owned by
another lane; the doc artifact is the replacement surface per the lane
contract).
