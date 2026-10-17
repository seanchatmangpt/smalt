# Receipt: cap-appconfig-kv — App Config `/kv` surface capability census (DoD lane, 2026-10-16)

- **Standing: PARTIAL_ALIVE** — surface ALIVE (full CRUD family, etag CAS, label
  isolation, 304, tokenless 401 challenge all witnessed by the offline suite);
  console flip pending substrate boot receipt.
- Surface: `GET/PUT/DELETE /kv/{key}`, `GET /kv` (list, `key=` prefix + `label=`
  filters), `Smalt.Store.list_all/1` full-table scan.
- Evidence file: `test/egress_kv_appconfig_test.exs` (14 tests, cited, not re-run).

## Covered behavior (per test file, read this session)

- CRUD: create 201 with quoted 64-hex etag + GET roundtrip; unconditional
  overwrite of an existing kv is 409; delete 204, idempotent repeat 404; absent
  kv typed 404.
- etag CAS with RFC 7232 `*` semantics: `If-Match` match is 200 / stale is 412;
  `If-None-Match: *` create-only refuses duplicates with 412; `If-Match` on
  absent kv is 412; matching `If-Match` delete is 204, stale 412.
- `Sync-Token`: list responses carry `sync-token: smalt-0` including the empty
  store (test line 123).
- Label isolation: default label `""` vs `label=prod` are distinct rows — same
  key, different values, cross-label GET is 404; list filters by `key=` prefix
  and `label=` jointly.
- 304: `If-None-Match` with matching etag is 304 with etag echoed; mismatch is
  200.
- Tokenless `GET /kv` is a 401 challenge, same challenge path as `/secrets`.
- contentType rides as an opaque passthrough.

## Store.list_all/1 — tuple-key row drop fix

`lib/smalt/store.ex:137` — `list_all/1` is the churn-safe full-table scan that
does not restrict to the binary-key prefix contract; `list/1` silently dropped
tuple-keyed rows (the App Config `{key, label}` rows). `list_all/1` returns all
values in term key order, skipping entries deleted mid-walk. The `/kv` list
handler consumes `list_all/1` via `lib/smalt/egress_router.ex`.

## KD-COVERS cross-reference

KD-53 (EH multi-event batch drops inner messages 2..N) is CLOSED-SIMULATED this
window — flips list at
`docs/jira/v26.10.16/KNOWN_DIVERGENCES.md` line 6 (canonical row:
`docs/jira/v26.10.14/KNOWN_DIVERGENCES.md`); shim carries the
`# KD-COVERS: KD-53` token in `lib/smalt/messaging/event_hubs.ex:84`.
Note: KD-53 is an Event Hubs row, not a /kv row — linked here for window
bookkeeping per lane instructions; no /kv KD row was opened or flipped.

## Evidence (embedded real output, not re-run)

Source: `tmp/w10-batch1.log` lines 2738–2758 (batch lane run of
`test/egress_kv_appconfig_test.exs`; ExUnit does not echo the filename, count
matches the file's 14 `test` blocks exactly):

```
Running ExUnit with seed: 424933, max_cases: 32
Excluding tags: [:amqp_wire]

.......
02:54:49.519 [warning] RollingCounters table :smalt_rolling_counters missing post-boot; dropping counter bump (key={:bandit_request_stop, "/post-boot-loss", 200})
.......
Finished in 0.07 seconds (0.00s async, 0.07s sync)
14 tests, 0 failures
EXIT=0
```

Standing is PARTIAL_ALIVE, not ALIVE: the surface is witnessed green offline,
but the console flip to ALIVE is gated on a substrate boot receipt, which does
not exist yet.
