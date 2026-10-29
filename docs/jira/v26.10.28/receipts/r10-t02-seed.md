# r10 — T-02: Resource pre-seeding — import existing Azure resources into local state

- window: v26.10.28 · ticket: `tickets/T02-resource-pre-seeding.md` · date: 2026-10-29
- tier: beam (`test/integration/seed_test.exs`) · status: **CODE-COMPLETE (r10), awaiting integration run**

## landed

1. **Seed runner (Elixir substrate, never `smalt-cli`)**: `mix smalt.seed --file
   <corpus.json> [--dry-run]` (`lib/mix/tasks/smalt.seed.ex`) ingests an
   exported Azure resource corpus — a JSON array of
   `{id, name, type, location, properties}` objects produced by
   `az resource list --output json` + `az resource show` on the developer's
   machine (no live Azure connectivity in the substrate; smalt never phones
   out) — into `Smalt.Store.put(:smalt_resources, key, record)`, the same
   table the ARM PUT paths materialize. Seeding is state hydration, not cloud
   actuation; the actuation-free AU-10 gate on `smalt-cli/` is untouched.
2. **Store row law (GET-compatible with hand-PUT)**: the STORE KEY is the
   downcased resource id (Store-wide lowercased-id convention); the record's
   wire `"id"` keeps the corpus casing; `name`/`type`/`location`/`properties`
   are preserved verbatim; `properties.provisioningState` defaults to
   `"Succeeded"` when the corpus omits it — the same persist-time default the
   generic PUT applies in `build_resource_record/5` — and `location` defaults
   to `"eastus"` on the same raw-payload fallback law; other top-level wire
   members (`tags`, `sku`, `kind`, ...) pass through untouched, so `GET`
   echoes what the real cloud showed.
3. **Dry-run + idempotency**: `--dry-run` prints the would-be seeded ids and
   writes nothing (it does not even boot the Store). Re-runs are idempotent:
   `Store.put/3` is a same-key overwrite, so a double seed is a no-op.
4. **Typed fail-closed ingestion**: missing/unreadable file, malformed JSON,
   or a malformed entry produce a typed `[smalt] ERROR` on stderr + exit 1 —
   never a raise — and ingestion is all-or-nothing: a corpus with any
   malformed entry writes nothing.

## court

`Smalt.Internal.SeedTest` (temp corpus under `System.tmp_dir!/1`, task module
invoked via `run/1` directly, real `:smalt_resources` Store rows, real ARM
router dispatch in-process like `sb_arm_rules_test.exs`; no mocks) — 7 tests:

1. seed → `Store.get` returns the record with `provisioningState` defaulted
   ("Succeeded") and preserved name/type/location/properties; seeded storage
   account then GETs 200 through the ARM router with the same id/name/
   location/properties echo a hand-PUT resource answers (DoD GET-parity face).
2. explicit corpus members pass through verbatim (present
   `provisioningState` preserved, `tags` carried); a properties-less entry
   (Service Bus namespace) defaults wholesale to
   `%{"provisioningState" => "Succeeded"}`.
3. dry-run prints the would-be ids and both rows stay absent.
4. double seed leaves byte-identical rows (`term_to_binary` equality).
5. missing corpus file → typed error exit `{:shutdown, 1}`, never a raise.
6. malformed JSON → typed error exit, nothing written.
7. malformed entry (non-string id) alongside a valid one → typed error exit
   and NO partial seed (the valid entry is absent too).

**Not yet executed** — the r10 lane is code-only per the compile-freeze SLA
(no mix/test/git in this pass); the court runs with the next integration pass
and this receipt + the ticket stamp say so.

## usage

```bash
# one-time export on the developer's machine (their own az session)
az resource list --output json > ids.json
# per-resource bodies (properties), e.g.:
az resource show --ids <id> --output json >> corpus.json   # -> {id, name, type, location, properties}

# point smalt at the exported corpus
mix smalt.seed --file corpus.json           # hydrates :smalt_resources
mix smalt.seed --file corpus.json --dry-run # prints would-be ids, writes nothing

# with the SDK or az pointed at smalt:
GET /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Storage/storageAccounts/<name>
# -> 200, the same id/name/location/properties the real cloud returns
```

## notes

- DoD mapping: "export them once from real Azure, run the seed command, GET
  each of those exact resource ids and receive the same id/name/location/
  properties" = court tests 1–2; "a seeded resource GETs byte-compatibly with
  a hand-PUT one" = court test 1 (200 echo through the real router);
  "dry-run printing would-be ids" = test 3; "idempotent re-runs" = test 4.
- The receipts-required list also names a seeded-vs-hand-PUT *diff* receipt
  and a `listKeys` usable-keys probe: both need a live integration pass (the
  diff runs against the running substrate; listKeys rides the existing
  `handle_storage_list_keys` face) — deferred to the integration run, as with
  r7.
- File scope: only `lib/mix/tasks/smalt.seed.ex` (new),
  `test/integration/seed_test.exs` (new), this receipt, and the T02 ticket
  stamp. No router, Store, or parity/ changes; the seeded rows ride the
  existing generic GET / list / listKeys surfaces unchanged.
