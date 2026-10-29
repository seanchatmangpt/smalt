# KD-171R — /api/sync/state shared-secret caller gate + off-host witness court

**Standing:** **ALIVE** — real gate on the route, real off-host court 6/6 over two
real Next dev servers + the real substrate cosmos face; zero mocks.
Context: solo
Date: 2026-10-22
Repo: /Users/sac/smalt (main)
Lane: KD-171R
Closes: KD-171 (loopback-open sync/state posture)

## What landed

- `workspace/lib/caller-gate.ts` (NEW, `// KD-COVERS: KD-171`): shared caller
  gate. `assertLoopbackCaller` (E7-1 loopback Host/Origin posture, moved
  verbatim from route.ts) + `assertSyncCaller`: when `SMALT_BFF_SYNC_SECRET`
  is set, requests must carry `x-smalt-sync-secret` matching the env secret —
  `node:crypto.timingSafeEqual` over UTF-8 buffers with a length-mismatch
  guard that still burns a padded comparison (ingest HMAC gate pattern from
  `workspace/app/api/v1/ingest/route.ts`). Missing -> 403
  `sync_state_missing_secret`; wrong -> 403 `sync_state_invalid_secret`. Env
  unset keeps the KD-171 loopback-open dev posture (KD-173 typed posture law).
- `workspace/app/api/sync/state/route.ts`: `assertLoopbackCaller` replaced by
  `assertSyncCaller` as the POST gate; gate comments + header contract updated
  to name both halves; debug-faces conventions followed.
- `workspace/scripts/kd171r-court.mjs` (NEW): off-host witness court.

## Court — real off-host witness (not a header probe)

`node scripts/kd171r-court.mjs` boots REAL Next dev servers (`next dev -H
0.0.0.0`) and POSTs to the machine's genuine non-loopback LAN IP
(192.168.12.205), so the Host header is genuinely non-loopback — the request
does not originate from loopback. Embedded output (final run, exit 0):

```
$ node scripts/kd171r-court.mjs
[PASS] A1 off-host no-secret -> 403 non_loopback :: status=403 body={"error":"sync_state_non_loopback","detail":"non-loopback host \"192.168.12.205\""}
[PASS] A2 loopback missing secret -> 403 missing_secret :: status=403 body={"error":"sync_state_missing_secret","detail":"missing x-smalt-sync-secret header"}
[PASS] A3 loopback wrong secret -> 403 invalid_secret :: status=403 body={"error":"sync_state_invalid_secret","detail":"invalid x-smalt-sync-secret header"}
[PASS] A4 loopback correct secret -> route proceeds (applied) :: status=200 body={"applied":[{"id":"kd171r-ok-1792670631855","etag":"\"aa15e848-e958-41d6-9661-1465d728e318\"","status":"applied"}],"conflicts":[],"errors":[]}
[PASS] B1 env unset loopback no-secret -> proceeds :: status=200 body={"applied":[{"id":"kd171r-b1-1792670632856","etag":"\"869475bd-0b7a-4f72-b26f-27a8d88dbb08\"","status":"applied"}],"conflicts":[],"errors":[]}
[PASS] B2 env unset header-present -> proceeds (header inert) :: status=200 body={"applied":[{"id":"kd171r-b2-1792670632890","etag":"\"46931c8c-3760-4b35-b425-1e8d03bfc68b\"","status":"applied"}],"conflicts":[],"errors":[]}

# kd171r-court: 6/6 PASS, 0 FAIL
# VERDICT: PASS — KD-171 close condition witnessed
exit=0
```

- A1 is the off-host leg: destination 192.168.12.205:port (real NIC), so the
  arriving Host header is the LAN IP — unauthed non-loopback POST -> typed 403
  at the real route, satisfying the "not just a header probe" bar.
- A4/B1/B2 proceed legs are real applies through the substrate cosmos face
  (real etags returned, :8443 up).
- Harness note: two concurrent `next dev` servers in one workspace contend on
  the turbopack `.next` lock — the court boots sequentially (A killed before
  B spawns), witnessed as a FAIL-then-fix during court authoring.

## Gates

```
$ npm run lint                    (workspace)            -> clean, exit 0
$ node --test app/api/sync/state/route.test.ts
  tests 10 / pass 8 / fail 0 / skipped 2 (live legs, loud SKIP without
  SYNC_TEST_BASE_URL — pre-existing skip shape, posture unchanged by KD-171R)
$ NODE_PATH=$PWD/node_modules node scripts/e2e-court.mjs
# PASS=70 FAIL=0 SKIP=2 (both skips pre-existing, loud)
```

## Register

KD-171 flipped OPEN -> CLOSED-SIMULATED via `scripts/kd_flip.py --apply --only
KD-171 --witness KD-171=docs/jira/v26.10.22/receipts/kd171r-secret-gate.md`
(the tool's canonical register is `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md`;
witness receipt postdates the `KD-COVERS` shim in
`workspace/lib/caller-gate.ts`), then the status cells in BOTH registers
annotated CLOSED-WITH-EVIDENCE per the KD-173R precedent (tool natively emits
CLOSED-SIMULATED; the evidence court here ran on the real route, off-host).
Note: the v26.10.22 prose register's Status cells are hand-annotated (mirror
sync reports 0 mirrorable rows) — hand-annotation is the KD-173R precedent.

## Boundary

- Gate is best-effort vs header spoofing from an already-loopback caller;
  the air-gap remains the outer trust boundary (KD-169 class).
- Secret compare is plain shared-secret (not HMAC-over-body) — adequate for
  the loopback-boundary caller gate; the ingest face keeps its HMAC-over-body
  form.
