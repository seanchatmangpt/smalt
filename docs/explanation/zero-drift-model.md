# zero drift model

**Hydrate → Validate → Persist → Verbatim GET**

Understanding-oriented; the code is
`lib/smalt/arm_gateway/defaults.ex` and the PUT handlers in
`lib/smalt/arm_gateway/router.ex` (`handle_resource_put`,
`build_resource_record`). This doc explains why the pipeline is shaped
the way it is.

## The problem: PUT bodies are partial

A real azurerm client PUTs a sparse body — a storage account without
`sku`, a key vault without `tenantId`. Real Azure would fill in
service-side defaults. An emulator has two bad options and one good
one:

- Reject the sparse body (fails real clients),
- persist the sparse body verbatim (a reader sees a resource Azure
  would never return — an azurerm read nil-panics on exactly these
  fields: `eventhub_namespace_resource.go:541` dereferences `createdAt`,
  witnessed in the T5 wire tier),
- or **hydrate defaults, then persist the merged result**.

smalt hydrates. The four-step pipeline in `handle_resource_put`:

```elixir
merged = Defaults.apply(full_type, conn.body_params)   # 1. hydrate
:ok <- check_shape(conn, full_type, merged)            # 2. validate
record = build_resource_record(...)                    # 3. persist-time merge + enrich
Store.put(...)                                         #    → GET returns the record verbatim
```

### Why hydrate BEFORE validate

Every entry in the `Defaults` table is validator-acceptable per
`Smalt.GraphLaw.Validator.validate_resource/2` (tests assert this). So
validating the **merged** body preserves refusal semantics for
genuinely invalid input while admitting the sparse-but-valid bodies
real clients send. Validating first would 400 bodies that Azure
accepts; validating after persisting would store records the shape
gate never saw. Hydrate-before-validate is the only order that keeps
the shape gate both strict and honest. (SHIM-COURT lane 395 landed the
order; all four PUT handlers share it.)

### Defaults.apply semantics

`apply/2` deep-merges the type's defaults **under** the user body:
user values win per key at every level; maps on both sides merge
recursively; defaults-only keys appear; non-map values (lists,
scalars) are replaced, never merged. Unknown type → body unchanged.
Pure functions, no I/O, no router coupling — the table is data, which
is what makes the ggen "defaults bijection" projection (see the
semantic-kernel roadmap) a swap rather than a rewrite.

Two deliberate exceptions to "user wins":

- `location` and `tags` always come from the **raw** payload. The
  defaults table's `"location" => "[resourceGroup().location]"` is a
  DURMT template expression, not a value the emulator can resolve;
  persisting it would leak interpolation syntax into the record.
- Enrichment (`Defaults.enrich/5`) — name-interpolated values
  (`vaultUri`, `primaryEndpoints`, namespace property sets,
  RootManageSharedAccessKey rules) deep-merged UNDER at record level,
  persist-time only. `vaultUri` deliberately echoes the request
  authority instead of public DNS (KD-T5-F1): azurerm 4.54 **polls**
  the vaultUri waiting for availability, and a public DNS name would
  hang the wire run.

## Why PUT-time persist makes drift traceable

The pipeline's key property: **GET never computes anything.** GET reads
the stored record and returns it verbatim (malformed record → 404
deny-by-default, never a synthesized 200). Everything the client will
ever see is decided at PUT time, in one place, from one merge order.

That is what makes the terraform "zero drift" property meaningful:

- A drift plan compares desired state to the GET surface. If GET were
  an enrichment function over sparse storage, drift would be a
  property of the GET-time algorithm — invisible, version-dependent,
  unreceiptable. Because GET is verbatim, drift is a **fact about the
  stored record**: the native lifecycle's `plan → []` verdict is a
  byte-level claim, and the native run's ids were verified byte-identical
  to the external tfstate (`sdk-results/native-lifecycle.md`).
- Traceability has a temporal axis too. When a divergence appears
  (e.g. a provider derefs a field the record lacks), the fix lands in
  exactly one file — the defaults/enrich tables — and the witness is
  reproducible: same PUT, same record, same GET. A GET-time compute
  model would smear the same bug across handler code paths.
- Enrichment is persist-time rather than GET-time for the same reason
  the timestamps are call-time rather than compile-time (the
  module-attribute lesson in `defaults.ex:22-27`): values that depend
  on context (request authority, wall clock) are computed when the
  context exists and then frozen, so every later reader sees the same
  term.

In short: hydrate-then-persist turns "what does this resource look
like" from a function of the reader into a receipt of the writer.

## See Also

- `lib/smalt/arm_gateway/defaults.ex` — the tables and merge semantics
- `lib/smalt/arm_gateway/router.ex` — `handle_resource_put`,
  `build_resource_record`
- `docs/explanation/semantic-kernel-roadmap.md` — defaults-bijection
  projection
- `docs/NO_SLEEP_DOCTRINE.md` — the plan is an observation, not a
  wait: drift is read from state, never inferred from elapsed time
