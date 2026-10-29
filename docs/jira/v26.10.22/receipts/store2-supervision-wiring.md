# STORE-2: Store supervision wiring (TTV-5 decomposition)

**Standing**: PARTIAL_ALIVE — compile-verified against the current tree; boot-test
BLOCKED on PENDING-MODULE (Smalt.Store.Heir / Smalt.Store.Partition not yet on disk).

**Context**: solo

## Diff

- `lib/smalt/plane/data_supervisor.ex` — replaced the single `Smalt.Store` child
  with the decomposed supervision block per the TTV-5 contract:
  1. `Smalt.Store.Heir` (via `start_link/1` taking `[]`; contract name
     `Smalt.Store.Heir.start_link/0` — child-spec tuple form, see PENDING note)
  2. 16 permanent `Smalt.Store.Partition` workers, child ids
     `{Smalt.Store.Partition, i}` for `i` in `0..15`, started via
     `Smalt.Store.Partition.start_link/1` with the partition index as arg,
     `one_for_one` (unchanged strategy) so a single partition crash restarts
     only itself
  3. `Smalt.Store` facade last — every partition ready before the facade
     accepts, and the facade ready before the two Bandit listeners below bind
     (existing data-plane ordering semantics preserved: facade-before-listeners
     is unchanged from the pre-diff tree)
- `lib/smalt/application.ex` — **no change required**. The wiring lives entirely
  inside `Smalt.Plane.DataSupervisor`; `Smalt.Plane.DataSupervisor` remains the
  first child in `plane_children/0`, so the plane boot order
  Data -> Control -> Integration -> Identity (AZB-09) is untouched.

## Verification

- `MIX_BUILD_ROOT=_build-store2 mix compile` (Elixir 1.20.4-otp-29, OTP 29
  via asdf shims) — exit 0, "Generated smalt app"; warnings pre-existing
  (Plug router dynamic-dispatch warnings, not introduced by this diff).
- Boot-test: not run — `Smalt.Store.Heir` / `Smalt.Store.Partition` are absent
  from the tree (only `lib/smalt/store.ex` facade + `lib/smalt/store/dets_mirror.ex`
  exist at time of writing). A boot would fail on the missing modules.

## PENDING-MODULE (owed to coordinator)

Child specs are written to the contract names and may need a one-line touch-up
when the TTV-5 lane lands:

1. `Smalt.Store.Heir.start_link/0` — spec passes `[]` as arg
   (`{Smalt.Store.Heir, []}`, i.e. `start_link/1` with an empty list). If
   TTV-5 lands a true zero-arg `start_link/0`, replace with
   `%{id: Smalt.Store.Heir, start: {Smalt.Store.Heir, :start_link, []}}`.
2. `Smalt.Store.Partition.start_link/1` — spec passes the partition index
   `i` in `0..15`. If TTV-5 lands `start_link(index: i)` keyword or opts form,
   wrap accordingly. Ids `{Smalt.Store.Partition, i}` keep the 16 workers
   distinct under `one_for_one`.
3. Partition count pinned at `@partition_count 16` per the operator reference;
   if TTV-5 lands a different bucket count, this constant is the single touch
   point.

## Receipt

- Subject: /Users/sac/smalt @ main (uncommitted working tree, lane STORE-2)
- Build root: `_build-store2` (lane lease; delete at integration)
- Files touched: 1 (`lib/smalt/plane/data_supervisor.ex`) + this receipt
- Not committed, per lane contract.
