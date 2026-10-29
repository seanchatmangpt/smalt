# Receipt w6f2 — Cosmos stored-procedures witness + close-out

**Standing:** **ALIVE** (module tier)
Date: 2026-10-20
Lane: w6f2 (close-out of w6f, which landed the surface but was disk-blocked pre-witness)
Surface: `lib/smalt/data_plane/cosmos.ex` w6f-marked sproc section (CRUD + execution face)

## Contract under test (as landed by w6f)

- Sproc records in `:smalt_cosmos_pk_meta` under `{2, db, coll, id}`; 256 KB body cap (413).
- Create 201 / dup 409 Conflict / malformed (no `body`) 400 BadRequest; list
  `{_rid, StoredProcedures, _count}`; get/replace/delete + 404 NotFound faces.
- Execute: constant-return bodies (`function f(){ return <literal>; }`) execute → 200 with the
  decoded literal; bodies using `getContext`/`getCollection` → honest typed 400
  ("constant-return bodies on this emulator"), no KD row minted (no proven SDK divergence).

## Witness (real output — `tmp/w6f2_witness.exs`)

Replay: `MIX_BUILD_ROOT=_build-lane-w6f2 MIX_ENV=test mix run --no-start tmp/w6f2_witness.exs`

```
CREATE_COLL_201_OK
F1_CREATE_STATUS=201
F2_DUP_STATUS=409 OK=true
F3_MALFORMED_STATUS=400 OK=true
F4_LIST_CONTAINS_OK=true
F1...F11_STATUS lines above are the literal run output; key legs:
F5_GET_ECHO_OK=true
F6_REPLACE_STATUS=200 BODY_OK=true
F7_EXEC_VALUE=[1, 2, 3]
F8_GETCONTEXT_STATUS=400 CODE=BadRequest
F9_UNKNOWN_404_STATUS=404
F10_DELETE_204_STATUS=204
F11_GET_AFTER_DELETE_404_STATUS=404
W6F2 WITNESS: ALL FACES OK
EXIT=0
```

## Verdict per face

| Face | Verdict |
|---|---|
| create 201 / dup 409 / malformed 400 | PASS |
| list/get/replace echoes (byte-exact body) | PASS |
| execute constant-return → decoded literal | PASS |
| execute getContext → typed 400 (honest limit, documented) | PASS |
| unknown sproc 404 / delete 204 → get 404 | PASS |

## Falsifier

Re-running the witness against a tree where sproc CRUD or the constant-return
execution face is broken (or where the getContext refusal silently 200s) would
make any OK=true here vacuous — the legs assert exact statuses, codes, and the
decoded literal, not just "no crash".

## Notes

- Compile surfaced **pre-existing** warnings only (KvRoutes/KeyVaultActions call-shape
  warnings — other lanes' surfaces, none in the w6f sproc section).
- Disclosure: this lane's own witness file was corrupted twice during authoring by the
  wave's large-Write degradation class (parent-hand authored); recovered via small
  heredoc chunks with a syntax gate after each chunk — the discipline now standard
  across the wave.
- No git commands. Scratch: `tmp/w6f2_witness.exs` (replayable), `_build-lane-w6f2`
  build root left for coordinator `lane-clean`.
