# BK-48 — pinion witness: KD-159 / KD-160 (CAS412-minted rows re-witnessed live)

**Standing: ALIVE** — both rows typed **PINION-WITNESSED** in the canonical
register (`docs/jira/v26.10.14/KNOWN_DIVERGENCES.md`). Each row's pinned face
is still intentionally implemented at its pinion site and still reproduces on
the live wire (raw HTTP + real @azure/cosmos 4.10.1), matching the original
CAS412 census receipt
(`docs/jira/v26.10.21/receipts/cas412-cosmos-replace-if-match.md`, standing ALIVE).

- Date: 2026-10-21 · Lane: BK-48 (registrar) · `Context: solo`
- Repo: /Users/sac/smalt (branch main; tree shared with concurrent lanes)
- Evidence receipt (both rows): `docs/jira/v26.10.21/receipts/cas412-cosmos-replace-if-match.md`
  (standing ALIVE: 800/800 accessCondition 412s, 80/80 etag-carrying, 6+69 tiers green)

## KD-159 — @azure/cosmos 4.10.1 `ifMatchEtag` silent no-op (SDK guidance pinion)

Pinion-site verification (current tree):

- `grep -r ifMatchEtag verification/ts/node_modules/@azure/cosmos/dist` → **0 hits**
  (the option is absent from the SDK dist; silent-swallow face unchanged).
- Mechanism unchanged: `dist/commonjs/request/request.js:85-86` —
  `options.accessCondition.type === "IfMatch"` → `If-Match` header.
- Guidance landed: `verification/ts/wf2/index.ts` uses `accessCondition`
  (grep of verification/ts non-node_modules hits: wf2/index.ts only).

Live wire probe (private bench_boot b8 substrate, anonymous auth, twin 39084;
harness `/tmp/bk48_pinion_probe.mjs` + `/tmp/bk48_sdk_leg.sh`):

- stale `item.replace(body, { ifMatchEtag: "bk48-stale-noop" })` → **200 accepted**
  with rotated etag; read-back `v == 99` proves the LWW write actually landed
  (no If-Match header was ever sent) — the pinned no-op face.
- Control: stale `accessCondition: { type: "IfMatch", condition: ... }` → **412**
  (confirms the server-side If-Match CAS is intact; only the SDK option is the no-op).
- Probe summary line: `BK48-SUMMARY {"sdk":"4.10.1","kd159_ifMatchEtag_200":1,
  "kd159_ifMatchEtag_412":0,"kd159_readback_v_after_noop":99,
  "kd159_control_412":true,"kd160_etag_match":true}`, `sdk-leg-exit=0`.

Commands/exits: `bash /tmp/bk48_sdk_leg.sh` → exit 0 (first two attempts
TYPED-TIMEOUT(124) on a cold `_build-bk48` — precompiled, then green; see
disclosure). Raw-face census still witnesses: raw `if-match: bogus` → 412 over
the same plane (KD-160 probe below).

## KD-160 — cosmos 412 carries CURRENT etag in `ETag` header (emulator superset pinion)

Pinion-site verification (current tree): `lib/smalt/data_plane/cosmos.ex`
do_put_doc stale arm, **cosmos.ex:1161-1167**:

```elixir
{:ok, 412,
 success_headers(db, coll, current_lsn(db, coll), %{"etag" => existing["_etag"]}),
 %{"code" => "PreconditionFailed", "message" => precondition_message()}}
```

Live wire probe (raw HTTP over shared substrate data plane 8443, bearer minted
from the emulator STS `POST /{tenant}/oauth2/v2.0/token`):

- create doc → 201, `etag: "a4d38f1b-7861-4a9a-b3ab-ff4587a12657"`.
- PUT with `If-Match: "bogus-stale-etag"` → **412 Precondition Failed**,
  response header `etag: "a4d38f1b-7861-4a9a-b3ab-ff4587a12657"` == read-back
  current `_etag` (byte-equal), Azure envelope body unchanged
  (`{"code":"PreconditionFailed",...}`).
- SDK probe over the b8 twin: `kd160_etag_match=true` (80/80-class face intact
  on this run's sampled 412).

## Registrar edit

- KD-159 and KD-160 status cells (6 cells preserved, pipes escaped) →
  **PINION-WITNESSED 2026-10-21 (BK-48, receipt docs/jira/v26.10.21/receipts/bk48-pinion-witness.md)**
  with per-row probe + census citation.
- `python3 scripts/kd_flip.py` → parses the register clean, **FLIP-ELIGIBLE: 0,
  FLIP-PENDING-WITNESS: 0**, exit 0 (zero skew; no KD-COVERS shim points at
  KD-159/160, so no flip owed — correct).

## Disclosure (tree state, session-introduced)

- `_build-bk48` left in place for reuse (coordinator may reclaim via lane-clean).
- A concurrent lane (TTV-5) held `lib/smalt/store.ex` mid-write (~3 min,
  syntax-error freeze); this lane polled only (bounded 30s polls, owner fixed
  within SLA) and did not touch the file. No compile was needed for the lane's
  own diff (docs-only registrar edit).
- Probe harnesses are stdout-only in /tmp (`bk48_pinion_probe.mjs`,
  `bk48_sdk_leg.sh`) — no jsonl, not a registered bench lane.
