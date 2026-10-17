# r232 — smalt.gen Mix task-ification: byte-identical replay over all 6 artifacts

- Date: 2026-10-17
- Lane: I2 (WO-3)
- Subject: commit 483eee3 `fix(generator): W2b — smalt.gen task-ification lands, replaces mix.exs alias chain`
- Standing: PASS

## Command

```
$ mix smalt.gen
```

## Real output (2026-10-17, /Users/sac/smalt)

Igniter reported **"No proposed content changes!"** for all six generated
artifacts — each "unchanged (skipped, identical content)", i.e. byte-identical
replay of the working tree against the ontology graph:

```
* ggen_igniter: unchanged (skipped, identical content): lib/smalt/registry.ex (engine: graphlaw, 9 queries, 178 total row(s)) (via reactor)
smalt.gen: lib/smalt/registry.ex ok
* ggen_igniter: unchanged (skipped, identical content): lib/smalt/ocel/event_registry.ex (engine: graphlaw, 9 queries, 119 total row(s)) (via reactor)
smalt.gen: lib/smalt/ocel/event_registry.ex ok
* ggen_igniter: unchanged (skipped, identical content): lib/smalt/store_tables.ex (engine: graphlaw, 8 queries, 148 total row(s)) (via reactor)
smalt.gen: lib/smalt/store_tables.ex ok
* ggen_igniter: unchanged (skipped, identical content): lib/smalt/cascade_edges.ex (engine: graphlaw, 8 queries, 119 total row(s)) (via reactor)
smalt.gen: lib/smalt/cascade_edges.ex ok
* ggen_igniter: unchanged (skipped, identical content): lib/smalt/config.ex (engine: graphlaw, 8 queries, 143 total row(s)) (via reactor)
smalt.gen: lib/smalt/config.ex ok
* ggen_igniter: unchanged (skipped, identical content): lib/smalt/telemetry/semconv/registry.ex (engine: graphlaw, 5 queries, 35 total row(s)) (via reactor)
smalt.gen: lib/smalt/telemetry/semconv/registry.ex ok
EXIT=0
```

The Mix task `Mix.Tasks.Smalt.Gen` at `lib/mix/tasks/smalt.gen.ex` is live
(comment block at lines 35-36 records the W2a move from the mix.exs alias
chain). `git diff --stat` after the run shows only the pre-existing in-flight
edits to `lib/smalt/config.ex` and
`lib/smalt/telemetry/semconv/registry.ex` — the generator itself proposed
zero changes, so the working tree is exactly generator output.

## Notes

- Replay law holds: regen == tree, exit 0.
- mix.exs also carries a new `test.compliance` alias (in-flight, not part of
  483eee3); receipted separately in r235.
