# w6aq2 — Deployments what-if close-out witness

- **Subject**: smalt @ main (uncommitted wave-6 tree), `lib/smalt/arm/deployments.ex` what-if face
- **Date**: 2026-10-20
- **Standing**: ALIVE (module tier, isolated-beam verification)
- **Context**: solo

## Landed / repaired this lane

`lib/smalt/arm/deployments.ex` (lane surface, additive):
1. **Defect (witness-caught): bare `:error` crash** — `diff_resource/3` guarded
   `is_nil(before) or match?({:error,_}, before)` but `Smalt.Store.get/3` returns
   bare `:error`; a brand-new resource crashed `elem(:error, 1)`.
   Fixed as `not match?({:ok, _}, before) ->`.
2. **Parity gap (witness-caught): tags missing from what-if delta** — delta entries
   carried only `properties.<k>` paths; real Azure what-if reports tag changes as
   `tags.<k>` entries. Added `tags_delta/2` emitting `Add/Update/Remove`
   `propertyChangeType` entries with `path: "tags.<k>"`.
3. **Compile-freeze unblock (disclosed, sibling's file region):** a concurrent
   writer's non-adjacent duplicate `tags_delta/2` clause group + appended
   `delta ++ [%{"tags" => ...}]` non-parity entry were reconciled away — the file
   had two conflicting implementations of the same delta. The ARM-parity form (per-tag
   `tags.<k>` entries) was kept; the sibling's map-shape implementation removed.
   Disclosed per the disclosure law; the reconciliation was required to make the
   file compile at all (non-adjacent duplicate clauses are a hard error).
4. Warning cleanup: `delta =` unused-assignment in `properties_delta/2` and the
   disjoint-type guard at :247 — both compile clean now (0 deployments.ex
   diagnostics).

## Verification (real output, isolated-beam path)

Full-tree `mix compile` was red on a sibling file (`eh_schema_registry.ex`, w6x's
lane) at run time — per the wave SLA the witness ran on isolated beams
(`elixirc -o tmp/w6aq2_ebin store_tables/store/registry/deployments`).

Witness: `tmp/w6aq2_witness.exs` (replay:
`ERL_LIBS= elixir -pa _build-lane-w6aq2/dev/lib/jason/ebin -pa tmp/w6aq2_ebin -e 'Code.require_file("tmp/w6aq2_witness.exs")'`):
```
MODIFY_FOUND=true
TAGS_DELTA=true
MODIFY_ENTRY: Modify with tags.<k> delta entries (env prod→dev)
CREATE_FOUND=true
IGNORE_FOUND=true
EMPTY_NO_CHANGES=true
W6AQ2 WITNESS: ALL LEGS DONE
```

## Falsifier

Green under a broken diff would be vacuous: re-point
`template_resource_id/1`-derived lookup at a missing key or remove `tags_delta/2`
and `TAGS_DELTA`/`CREATE_FOUND` must flip false/crash. `tags_delta/2` removal is
observable in one re-run.

## Disclosure

- Sibling reconciliation in `deployments.ex` (item 3) touches only the region the
  concurrent writer introduced during this lane's window; `deployments.ex` is this
  lane family's exclusive surface (w6aq → w6aq2).
- No git operations, no mocks, no Process.sleep.

## RE-WITNESS addendum — 2026-10-22 (lane BK-REWIT3): cheap replay PASS — ALIVE

Re-ran `tmp/w6aq2_witness.exs` on `_build-rewit3`: `MODIFY_FOUND=true /
TAGS_DELTA=true (tags.<k> Modify entries) / CREATE_FOUND=true /
IGNORE_FOUND=true / EMPTY_NO_CHANGES=true / W6AQ2 WITNESS: ALL LEGS DONE`,
exit=0. SUSPECT cleared; ALIVE on the integrated tree.
