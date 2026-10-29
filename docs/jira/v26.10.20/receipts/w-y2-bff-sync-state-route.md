# Receipt: Y2 — BFF reconciliation gateway route /api/sync/state

**Standing:** ALIVE (live witnessed end to end against the running substrate)

## Route

`workspace/app/api/sync/state/route.ts` (new).

- `POST /api/sync/state` — batched delta `[{id, data, baseVersion?}]` →
  `{applied, conflicts: [{id, reason, currentEtag?}], errors}`.
- Empty batch → typed 400 `sync_state_empty_batch`; non-array / non-JSON body →
  typed 400 (`sync_state_invalid_batch` / `sync_state_invalid_json`).
- Per entry: GET current doc etag from the loopback cosmos face (:8443) →
  - doc missing + no baseVersion → create via `POST /docs` with
    `x-ms-documentdb-is-upsert: true` (cosmos PUT replace 404s on a missing
    doc — creation is a POST op; this was a real finding during verification);
  - doc exists, baseVersion matches etag → `PUT` with `If-Match` (atomic CAS
    in the smalt Store; concurrent loser gets 412 → typed `version_conflict`);
  - mismatch → `version_conflict` conflict row with `currentEtag` for rebase;
    baseVersion but doc missing → `doc_not_found`; malformed entries →
    `invalid_entry` per-entry error rows. Never a blind overwrite.
- All networking via `smaltFetch` (air-gap `assertLocalUrl`); no raw fetch.
- Auth: substrate `:enforce` mode → route presents Bearer minted by the
  loopback STS (`SMALT_SYNC_TOKEN` env wins; else mints + caches itself).

## Gates

- `just ws-lint` → exit 0 (0 errors; 28 pre-existing warnings in untouched files)
- `just ws-build` → exit 0 (route compiled as dynamic ƒ)

## Live verification (substrate UP, `next start -p 3111`, curl POST)

Substrate: `scripts/substrate.sh status` → UP (pid 9849, all four ports).
Bearer minted from `POST http://127.0.0.1:9443/smalt/oauth2/v2.0/token`;
db `sync` + coll `state` created (201/201).

Batch 1 — create + stale + malformed + ghost:

```
{"applied":[{"id":"alpha","etag":"\"220fe43d...\"","status":"applied"}],
 "conflicts":[{"id":"alpha","reason":"version_conflict","currentEtag":"\"220fe43d...\""},
              {"id":"ghost","reason":"doc_not_found"}],
 "errors":[{"id":"bad-entry","reason":"invalid_entry"}]}
```

(One entry with `data: "not-an-object"` also returned `invalid_entry` in an
earlier run of the same batch shape.)

CAS re-apply with the live etag:

```
{"applied":[{"id":"alpha","etag":"\"ee5f10ed...\"","status":"applied"}],
 "conflicts":[],"errors":[]}
```

Server state after (direct GET :8443) — the write really landed, `_v: 2`,
`"n": 3`:

```
{"_etag":"\"ee5f10ed...\"","_v":2,"id":"alpha","kind":"state","n":3,...}
```

Replay with the now-stale previous etag → typed conflict, no overwrite:

```
{"applied":[],"conflicts":[{"id":"alpha","reason":"version_conflict",
 "currentEtag":"\"ee5f10ed...\""}],"errors":[]}
```

`[]` → 400 `sync_state_empty_batch`; `{...}` body → 400 `sync_state_invalid_batch`.

## Notes / disclosure

- Two defects found and fixed during live verification (both in-session):
  PUT-replace-on-missing-doc 404 (fixed with POST-upsert create), and the
  first iteration served a stale build (next start serves .next; rebuilt).
- Pre-existing: substrate was already UP (pid 9849) when this lane started —
  not booted by this lane, left running.
- No git operations performed (lane law).
