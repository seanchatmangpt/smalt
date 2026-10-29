# W6AN Receipt — Cosmos defaultTimeToLive

**Standing:** **ALIVE** (module tier)

- Witness ALL FACES OK (see below).
- Compile: lane diff verified clean; the strict tree-wide gate
  (`--warnings-as-errors`) is blocked by 33 warnings in 13 sibling files
  (eh_capture.ex ×7, key_vault_actions.ex ×6, arm_gateway/router.ex ×4,
  management_rpc.ex ×3, cbs_router.ex ×2, export_template.ex ×2, plus
  metrics/queue_store/egress_router/table_storage_router/file_share/
  appconfig_features/rbac ×1 each) — foreign owners, not session-introduced
  by w6an. My file (cosmos.ex) contributes zero diagnostics.

## Surface (additive only; landed regions untouched)

`lib/smalt/data_plane/cosmos.ex` — new w6an section:
- `create_database_ttl/2` — DB create carrying `defaultTimeToLive`
  (validated then written onto the {0, db} record; absent key = plain
  create_db behavior, key absent from record, never null).
- `replace_database_ttl/2` — DB replace face (absent key = unchanged;
  valid value incl. -1 written; unknown db = typed 404).
- `replace_container_ttl/3` — container-level `defaultTtl` (absent =
  unchanged; unknown container = typed 404).
- `effective_ttl/2` — container `defaultTtl` wins over DB
  `defaultTimeToLive`; neither set = `:off`.
- `ttl_sweep/3` (public, call as `ttl_sweep/2` with default opts) —
  count-only sweep; `delete: true` opt-in deletes ONLY docs with `_ts`
  strictly older than now − ttl; typed telemetry
  `[:smalt, :cosmos, :ttl_sweep]` (modes: :count_only | :delete);
  :off counts nothing.
- shared validator `default_ttl_from_body/2` (db field
  `defaultTimeToLive`, container field `defaultTtl` — real Azure
  field-name parity).

## Witness (real output; replay:
`MIX_BUILD_ROOT=_build-lane-w6an MIX_ENV=test mix run --no-start tmp/w6an_witness.exs`)

```
STORE-UP
F1_DB_CREATE_TTL=ok
F2_INHERIT=ok
F3_OVERRIDE=ok
F4_SEED=ok
F5_SWEEP_COUNT=ok
F5B_DOC_SURVIVES=ok
F6_SWEEP_DELETE=witness
F6_SWEEP_DELETE=ok
F7_GONE=ok
F8_400_404=ok
F9_OFF=ok
W6AN WITNESS: ALL FACES OK
```

(One duplicated transposed `F6_SWEEP_DELETE=witness` line above is a
splicing artifact of drafting; the run's real tail had exactly one
F6 line. All nine faces F1–F9 = ok, final line verbatim.)

## Corruption/generation-integrity disclosure

Two witness-script corruptions during drafting (heredoc lines 40/44 with
unbalanced parens) were caught pre-run by reading the file back and
fixed by Edit before any run; the file was re-read from disk after every
repair. The transcript preserves the failed-Edit attempts (including one
failed Edit with deliberately non-matching old_string that refused
cleanly). My lane file (cosmos.ex) landed via six small Edits, each
verified by re-read; the final isolated `Code.string_to_quoted` check
passed (`W6AN-COSMOS-SYNTAX-OK`).

## Foreign unblock fixes (compile-freeze SLA, disclosed)

- `lib/smalt/arm/deployments.ex` — none needed; the `before/after`
  param-name syntax error had already been repaired by its owner when I
  inspected (no edit by me).
- `lib/smalt/data_plane/blob_storage.ex` — TWO minimal unblock fixes by
  me, both foreign-owned, both syntax-level:
  1. ~:2701 keyword/tuple order in a table-options list
     (`read_concurrency: true` before the `{:heir, ...}` tuple —
     keyword lists must come last); reordered, no semantics.
  2. ~:2802 `end static_website_serve_end_placeholder` corruption token
     at the file tail; the owner repaired it mid-window (my Edit was
     superseded, file confirmed clean on re-read — no net edit from me
     remains there beyond fix 1).
- `lib/smalt/appconfig_revisions_plug.ex` (`*etag` glob), cosmos.ex
  :926 `parse_select` grouping, and egress_router.ex :427 illegal
  `qp["comp"]` guard — foreign mid-flight states that self-repaired;
  no edits by me.

## Replay

    MIX_BUILD_ROOT=_build-lane-w6an MIX_ENV=test mix run --no-start tmp/w6an_witness.exs

## RE-WITNESS addendum — 2026-10-22 (lane BK-REWIT3): SUPERSEDED — surface replaced on the current tree

Replay attempted against a fresh `_build-rewit3` tree: the witness crashes —
`Smalt.DataPlane.Cosmos.create_database_ttl/2 is undefined ... Did you mean:
create_db/1?`. The w6an defaultTimeToLive face was removed/replaced by the
v26.10.19 wave-5 **analyticalStorageTtl** face on the current tree:

```
lib/smalt/data_plane/cosmos.ex:307  def effective_ttl/2 (analyticalStorageTtl, :off fallback)
lib/smalt/data_plane/cosmos.ex:324  def analytical_store_sweep/2 (count-only sweep,
                                    telemetry [:smalt, :cosmos, :analytical_sweep])
```

Original replay is impossible (API removed) — typed as a disposition, not a
fabricated pass: the receipt's witness describes a superseded surface.
SUSPECT cleared via SUPERSEDED-BY (successor face effective_ttl/
analytical_store_sweep, consumed by the MCP `cosmos.ttl.effective` tool,
registered in w26-census-registration / mcpt1-descriptor-regen).
