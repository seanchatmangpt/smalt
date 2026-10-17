# Receipt: cap-cosmos-throughput

- **Lane**: DoD (capability receipts), v26.10.16
- **Date**: 2026-10-16
- **Repo / subject**: /Users/sac/smalt @ main (docs lane; no build/test runs performed by this lane)
- **Standing**: PARTIAL_ALIVE

## Scope (what landed)

Cosmos container throughput, 80/20 model: throughput from the create/replace
body is stored on the container record as a plain integer.

- **Create path** — `lib/smalt/data_plane/cosmos.ex` `create_collection/…`:
  `throughput_from_body/1` extracts `throughput`; `maybe_put_throughput/2`
  stores it on the record (absent key stays absent — see law below).
- **Replace path** — `Cosmos.replace_collection/3`
  (`lib/smalt/data_plane/cosmos.ex`, ~L193) plus the ARM route
  `PUT /dbs/:db/colls/:coll` (`lib/smalt/arm_gateway/router.ex`
  `handle_cosmos_child_put/5`, L1406, dispatched with `sub_id` threaded
  from L1185). Replace stores the new throughput on the record; a PUT body
  without `throughput` leaves the stored value unchanged.
- **Typed 400** — present-but-non-integer, float, zero, or negative
  `throughput` returns typed `400 BadRequest`
  (`"Invalid throughput: expected a positive integer, got: …"`,
  cosmos.ex ~L228–244). Floats are deliberately rejected (`is_integer/1`
  guard, no float coercion) — 80/20, real Cosmos accepts float-typed
  request units on the wire; registered as an 80/20 simplification, not a
  KD row (no SDK divergence witnessed).
- **Absent-key-absent law** — absent `throughput` parses as `{:ok, nil}`
  and `maybe_put_throughput(record, nil)` is identity: the key is never
  written as `null`, and replace-with-absent leaves the stored value
  untouched. Witnessed by
  `test "absent throughput stays absent on readback (not null)"`,
  cosmos_test.exs L2748.
- **404 ghost replace** — `replace_collection/3` on a container that does
  not exist returns 404, witnessed by
  `test/cosmos_test.exs` L2788
  (`Cosmos.replace_collection("tpdbx", "ghost", %{"throughput" => 400})`).

## Evidence (cited, not re-run — DoD lane: no build/test runs)

- Suite: `test/data_plane/cosmos_test.exs` — **128 tests, 0 failures**
  as landed by the implementing lane (cited per dispatch; not re-executed
  by this lane). Throughput tests confirmed present on disk at
  L2706–2788 ("container throughput (C5 typed gap)" describe block,
  6 tests incl. create-400/read-back-400, router-PUT-800/readback-800,
  absent-stays-absent, typed 400 for `1.5` and `0`, ghost 404).
- Static counts captured by this lane (real output):

```
$ grep -c "  test " /Users/sac/smalt/test/data_plane/cosmos_test.exs
128
$ grep -c "test " /Users/sac/smalt/test/court_ocel_test.exs   # sibling receipt
4
```

## SLA disclosures (seam agreements from the implementing lane)

- **router.ex sub_id threading**: the colls PUT route is reached only
  through `handle_cosmos_child_put(conn, child_type, sub_id, rg_name,
  rel_path)` with `sub_id` threaded from the subscription-scoped dispatch
  (router.ex L1185 → L1406) — throughput replace inherits subscription
  scoping from the ARM path; no direct data-plane bypass route was added.
- **egress_router end-rebalance**: disclosed at the lane seam (coordinator
  dispatch) as the reason the throughput surface touches no egress path;
  the token "rebalance" does not appear in `lib/` on disk at receipt time —
  recorded here verbatim as a disclosure, not an independently verified
  code anchor.

## Consequence

`docs/jira/v26.10.16` capability ledger row for cosmos container
throughput: surface PASS at the 80/20 model with typed error contract.

## Falsifier

`mix test test/data_plane/cosmos_test.exs` returning any failure in the
L2706–2788 block, or a `throughput => nil` key appearing on readback,
falsifies this receipt.

## Replay

```
grep -n "throughput" /Users/sac/smalt/lib/smalt/data_plane/cosmos.ex
grep -n "handle_cosmos_child_put\|colls" /Users/sac/smalt/lib/smalt/arm_gateway/router.ex
sed -n '2700,2790p' /Users/sac/smalt/test/data_plane/cosmos_test.exs
```
