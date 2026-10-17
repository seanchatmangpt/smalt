# cascade teardown

**The 27-Table Topology, Capture-then-Sweep, D127 Scoping, NFR-4**

Understanding-oriented. Code: `lib/smalt/arm_gateway/router.ex`
(`do_rg_delete`, `cascade_sweep/2`, `storage_account_names/1`,
`vault_secret_sweep/1`, storageAccounts/vaults DELETE handlers);
storage substrate `lib/smalt/store.ex` (27 `@tables`), `lib/smalt/
data_plane/blob_storage.ex` (`drop_account_data/1`). Fence:
`test/arm_cascade_teardown_test.exs`.

## Why cascade at all

Real ARM guarantees: deleting a resource group deletes everything in
it. An emulator that deletes only the RG row leaves orphaned children
GETable — worse than a crash, because it looks correct. The cascade
exists to preserve the ARM delete contract against a store where
children are rows in shared tables keyed by full id.

## The 27-table topology

The Store is 27 `:ordered_set` ETS tables (`store.ex @tables`),
keyed by lowercased full ARM id strings so prefix scans are
deterministic and TF-stable. The topology matters for teardown
because the tables split into two planes:

- the **ARM plane** (`:smalt_resource_groups`, `:smalt_resources`,
  `:smalt_operations`, ...) — rows reachable by id-prefix from the
  deleted RG;
- the **data plane** (`:smalt_blob_containers`, `:smalt_blobs`,
  `:smalt_blob_policy`, `:smalt_blob_blocks`, `:smalt_blob_snapshots`,
  `:smalt_vault_secrets`, ...) — rows keyed by conventions the ARM id
  hierarchy does NOT contain: `"acct/"` blob prefixes, bare secret
  names in `:smalt_vault_secrets` (no vault scoping in the key at
  all).

An id-prefix cascade over the ARM plane structurally cannot reach the
data plane. That is the whole design problem of teardown: the second
plane's keys are derivable only **from** the ARM rows, not from the
deleted id. Hence capture-then-sweep.

## Capture-then-sweep

`cascade_sweep/2` returns the swept **store keys**, not just `:ok`:

```elixir
swept_keys = Store.prefix_keys(:smalt_resources, base)
for key <- swept_keys, do: Store.delete(:smalt_resources, key)
for acct <- storage_account_names(swept_keys), do: BlobStorage.drop_account_data(acct)
vault_secret_sweep(swept_keys)
```

The capture happens **before** deletion semantically for the vault
branch (bare secret names are extracted from the swept ARM keys), and
the ordering is load-bearing in the other direction too: extraction
reads the key strings themselves, which are still in hand after
`prefix_keys/2`. Two extraction patterns ride one mechanism:

- `storage_account_names/1` regexes `storageaccounts/<acct>` out of
  the swept keys (both store-key conventions: prefixed and
  child-route form), then `BlobStorage.drop_account_data/1` sweeps
  the `"acct/"` blob family;
- `VaultData.vault_secret_names/1` extracts bare secret names for the
  FR-6 vault sweep.

Why not sweep lazily (a sweeper process finding orphans later)?
Because "GETable orphan" is a wire-visible defect with a real client
in the loop: azurerm's own polling would observe the phantom. Capture-
then-sweep makes the delete LRO's terminal state (404 on every child)
a property of the delete itself, not of eventual consistency.

## Delete by STORE KEY, never by the record's own id

The cascade iterates `Store.prefix_keys/2` results and deletes by key.
This is the lens-11 measured lesson: `list_prefix/2` returns records,
and a malformed (non-map) child — reachable only via direct external
write — raised `FunctionClauseError` inside `Access.get/3`, 500-ing
the whole delete and leaking every remaining child. Store keys ARE
the lowercased full ids, so key-based deletion is exact and needs no
read of the record at all. A malformed child now deletes cleanly
instead of poisoning its siblings' teardown.

## D127 scoping

D127 is the product decision that blob container DELETE stays
unimplemented — a product gap, not a defect. The scoping question the
cascade had to answer: does the cascade's blob sweep violate or erode
D127? No — and the boundary is drawn precisely (WRAP_LEDGER D127 row,
FR-6 note):

- The gap covers **only the per-container DELETE route itself** — the
  client-facing operation.
- The cascade DOES sweep the data-plane blob tables
  (`drop_account_data/1`) when a storageAccount is deleted directly or
  via RG cascade — account teardown must not orphan containers, which
  would contradict the delete contract the cascade exists to preserve.

The distinction: D127 says smalt will not *offer* container deletion
as an API; it says nothing about containers surviving the deletion of
their own account. Any future wire surface that starts refusing or
implementing container delete must cite D127 and update the
WRAP_LEDGER row.

## NFR-4 identity proof

NFR-4 is the teardown closure requirement: after destroy, **tables
alive + empty**. The identity is checked two ways by design:

- the lifecycle's fail-closed `residue` stage verifies the data-plane
  tables empty post-destroy (witnessed: 17 tables empty,
  `sdk-results/native-lifecycle.md`);
- the `smalt_ets_baseline_identity` check plus the T5 ladder's stage 5
  (no surviving listeners on the T5 port block, no leftover state
  files, state-dir sha256 empty-or-attested).

Why an identity proof rather than a per-table count: counts are
fixture-dependent and rot; "the same set of table names exists, and
every row count is zero" is a property of the *topology*, invariant
across fixtures. It is the teardown analogue of the verbatim-GET
model — the end state is fully determined by the delete, not by what
ran before it.

## See Also

- `lib/smalt/arm_gateway/router.ex:2700-2790` — cascade handlers
- `lib/smalt/store.ex` — the 27-table topology
- `test/arm_cascade_teardown_test.exs` — the fence
- `docs/jira/v26.10.16/WRAP_LEDGER.md` — D127 row, FR-6 teardown scope
- `docs/explanation/semantic-kernel-roadmap.md` — cascade-DAG projection
