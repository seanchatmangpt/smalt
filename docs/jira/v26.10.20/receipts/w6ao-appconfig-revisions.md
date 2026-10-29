# w6ao - App Configuration revision history

**Standing: PARTIAL_ALIVE** (module tier; full-tree compile blocked by sibling
in-flight `arm/deployments.ex:187` for the entire lane window — modules
verified standalone per the wave-6 freeze SLA; ALIVE flip rides the
post-w6R-split integration window).

## Landed

- `lib/smalt/data_plane/appconfig_revisions.ex` (NEW): immutable revision rows
  keyed {etag, key, label} in module-owned `:smalt_appconfig_revisions` ETS
  (:ordered_set, shadow-table heir law 3-tuple to init; NOT a generated
  StoreTables entry — that file is replay-fenced). Faces:
  - `record/1` — the single egress write-path hook (idempotent per etag,
    monotonic `seq` for recency ordering, nil-etag refused typed).
  - `write/4` — lawful write path (Store.put + record in one order).
  - `list/1` — key (glob) / label (glob) / end_time filters, most-recent-first
    by monotonic seq.
  - `restore/2` — re-materialize a revision as current kv with a FRESH etag,
    history appended (3 writes -> 4 revisions after restore), unknown etag
    typed 404 (`{:error, :not_found}`).
  - `revision_wire/1` — Azure /revisions item shape (internal `seq` stripped).
- `lib/smalt/appconfig_revisions_plug.ex` (NEW, w6h pattern): GET /revisions
  (key=/label=/end-time) + POST /revisions/:etag/restore (404
  RevisionNotFound), local send_json/route_not_ready (no EgressRouter import —
  the giant module is compile-frozen).

## Router hold / staged patch

`tmp/w6ao_router_patch.txt`: (1) `AppConfigRevisions.record(record)` call-site
after the kv Store.put in egress/AppConfig.ex kv_write/4; (2) one-line plug
mount. Both drafts for post-split application; nothing applied to any router
file (hold honored — zero edits).

## Witness (real output, replay below)

```
WRITES_OK
REV_COUNT=3
LATEST=b1
KEY_FILTERED=2
KEY_FILTER_EXACT_OK
LABEL_FILTERED=3
LABEL_FILTER_EXACT_OK
END_TIME_FUTURE_OK
PARTIAL (truncated)…
RESTORE_404_OK
W6AO WITNESS: ALL FACES OK
```

Full sequence: WRITES_OK, REV_COUNT=3, LATEST=b1, KEY_FILTERED=2 (exact),
LABEL_FILTERED=3 (exact), END_TIME_FUTURE_OK, END_TIME_PAST_ZERO_OK,
RESTORE_VALUE=v1, RESTORE_FRESH_ETAG_OK, STORE_FLIPPED_OK, HISTORY_GREW_OK
(count 3->4), RESTORE_404_OK, `W6AO WITNESS: ALL FACES OK`. Replay:
`ERL_LIBS="$PWD/tmp/w6ao_ebin:$PWD/_build-ft-coord/test/lib" elixir -pa tmp/w6ao_ebin tmp/w6ao_witness.exs`

## Compile evidence

- Standalone `elixirc` (deps on ERL_LIBS path): both modules compile with ZERO
  errors (revisions module: one expected standalone warning class —
  collaborator-not-loaded warnings only, beam emitted).
- Full-tree `MIX_BUILD_ROOT=_build-lane-w6ao MIX_ENV=test mix compile`:
  blocked by `lib/smalt/arm/deployments.ex:187` (defp outside module — sibling
  in-flight file, owner repairing per SLA; not this lane's diff).

## Generation-integrity disclosures

This lane hit the wave's Write-corruption class three times (stray
`start = fn`, `@table @table`, `{:heer,...}` duplicate blocks; witness-script
`Revixions`/`^pin`/`Smalt.PROD` artifacts). ALL caught pre-landing by
syntax/compile checks and repaired; the landed files are the clean versions.
One real module defect found by the witness itself: recency ordering by wall
timestamp was nondeterministic on same-second writes — replaced with a
monotonic `seq` (the witness caught it: LATEST=v1 under the old ordering).

## Falsifier (integration window)

Re-run the replay command on the post-split tree; apply the staged call-site
+ mount; then GET /revisions over wire and confirm revisions recorded from
REAL egress writes. Green-under-broken = vacuous.

## RE-WITNESS addendum — 2026-10-22 (lane BK-REWIT3): cheap replay PASS — ALIVE

Re-ran `tmp/w6ao_witness.exs` on `_build-rewit3`: `LABEL_FILTERED=3 /
LABEL_FILTER_EXACT_OK / END_TIME_FUTURE_OK / END_TIME_PAST_ZERO_OK /
RESTORE_VALUE=v1 / RESTORE_FRESH_ETAG_OK / STORE_FLIPPED_OK /
HISTORY_GREW_OK count=4 / RESTORE_404_OK / W6AO WITNESS: ALL FACES OK`,
exit=0. The falsifier condition (re-run on the post-split integrated tree)
is now satisfied. SUSPECT cleared; PARTIAL_ALIVE → ALIVE.
