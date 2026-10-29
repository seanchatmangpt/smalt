# BK-15b — SKIP-leg re-witness after BK-21's CORS fix (mcp / queue / keyops / blob)

**Standing:** PARTIAL_ALIVE
`Context: solo`
Date: 2026-10-22

## Scope

Follow-up to BK-15 (`bk15-skip-fetch-census.md`) re-running the unblocked
in-browser SKIP legs on a substrate carrying BK-21's CORS fix. lib/ untouched
by this lane (BK-21 owns egress_router). Edits confined to popcorn_demo/ +
tmp/. No commit.

## What changed since BK-15

- BK-21 (landed): queue-shaped preflights divert to the KV CORSPlug face
  (queue preflight 403→204); MCP plane gains a loopback-Origin CORS face
  (404→204).
- BK-46 lane (concurrent, landed in popcorn_demo): `LiveKeyops` Fetch port —
  gen_tcp transport deleted, `request/1` rides `Transport.Fetch` in-browser,
  and the walk's digests are precomputed base64url constants (no `:crypto`
  in the wasm BEAM). BK-15's "TYPED-PERMANENT (:crypto)" note for keyops is
  thereby retired: the digest never needed to be computed in-browser.
- BK-46 lane also fetch-ported `LiveCerts` ("single calculus, mirrors
  PopcornDemo.LiveCerts" — comment in live_keyops.ex) — see Residuals: the
  certs leg now FAILs in-browser where it was a typed SKIP.

## Environment

- Substrate: fresh boot (pid 48942) of landed code via
  `(9>&- just substrate-up)` after `just substrate-down` cleared an orphan
  lock (pid 38111, no listening socket). UP on 9443/9444/5672/5673,
  lock free after boot. Never restarted during the witness (the seeded blob
  CORS rules live in substrate ETS and must survive).
- Cook: pinned toolchain (asdf erlang 29.0.6 / elixir 1.20.4-otp-29 PATH),
  `mix popcorn.cook --out-dir public/out` — PASS, 3 cooks
  ("Cooked 8 applications", exit 0 each).
- Browser: `node scripts/browser_smoke.mjs` (headless Chromium via
  chrome-headless-shell), 3 runs. Exit contract note: exit 1 in runs 2/3 is
  the certs/queue FAIL legs, not the smoke harness.

## Per-leg results (BK-15 baseline → now)

| leg | BK-15 verdict | now | evidence |
|-----|---------------|-----|----------|
| mcp | SKIP(mcp-down: missing CORS) / PENDING-DISPATCH | **OK(32-tools)** — FLIPPED | rode Transport.Fetch end-to-end (root shape + tools/list + tools/call cluster.status), witnessed in 3/3 smoke runs |
| keyops | SKIP(wasm-transport: gen_tcp) / PENDING-DISPATCH | **OK(ES256:verified)** — FLIPPED | full walk: health → KV 401 challenge → STS token → EC create 200 → ES256 sign → verify valid → tampered verify `value:false`, all via Fetch; 2/2 runs after the unblock |
| queue | PENDING-DISPATCH | **FAIL(create-queue: fetch blocked — missing CORS response header)** | preflight 204 witnessed (§A) but the actual PUT create-queue response carries no `access-control-allow-origin` (§C) → browser blocks the actual response |
| blob | SKIP(cors-preflight-403) | **SKIP(cors-preflight-403) — mislabelled** | rules seeded (§B: PUT 202, preflight 200 with rule face) — preflight is no longer the blocker; the classifier types any fetch-CORS failure as preflight-403. Real blocker = same actual-response allow-origin gap as queue (§C) |

### Wire evidence (verbatim, from /tmp/bk15b/wire-witness.txt)

**A. BK-21 preflight faces (204 + exact KV header face):**

```
-- queue preflight:
HTTP/1.1 204 No Content
access-control-allow-credentials: true
access-control-allow-origin: *
access-control-allow-methods: GET,POST,PUT,PATCH,DELETE,OPTIONS

-- mcp preflight:
HTTP/1.1 204 No Content
x-request-id: GOC9TSi9L8UE40MAADPB
access-control-allow-credentials: true
[identical allow-origin/methods/headers/max-age face]
```

**B. Blob `<Cors>` rule seed — the w6av surface EXISTS and works:**

```
$ curl -X PUT "http://127.0.0.1:8443/popcorn?restype=service&comp=properties" \
    -H "authorization: Bearer $TOK" -H "x-ms-version: 2021-12-02" \
    -H "content-type: application/xml" --data-binary "$XML"
202

$ curl -i -X OPTIONS "http://127.0.0.1:8443/popcorn/bk15b-cont?restype=container" \
    -H "Origin: http://localhost:3000" -H "Access-Control-Request-Method: PUT"
HTTP/1.1 200 OK
Access-Control-Allow-Headers: *
Access-Control-Allow-Methods: GET,PUT,POST,DELETE,OPTIONS,HEAD,PATCH
Access-Control-Allow-Origin: http://localhost:3000
Access-Control-Expose-Headers: etag,x-ms-request-id,x-ms-version
Access-Control-Max-Age: 1800
```

(`$XML` = a StorageServiceProperties body with one `<CorsRule>`:
AllowedOrigins `*`, methods GET,PUT,POST,DELETE,OPTIONS,HEAD,PATCH,
AllowedHeaders `*`, MaxAge 1800 — full body in `/tmp/bk15b/wire-witness.txt`.)

## Residual (single, typed): actual-request `Access-Control-Allow-Origin` gap

All actual (non-preflight) data-plane responses OUTSIDE the KV CORSPlug
pipeline — queue paths (BK-21's arm answers OPTIONS only) and blob paths
(w6ay's else-branch registers only `Access-Control-Expose-Headers`) —
carry **no `access-control-allow-origin`**. A browser therefore blocks every
actual queue/blob response even when preflight passes and rules exist.
Wire-verified contrast:

```
/healthz (KV face):   access-control-allow-origin: http://localhost:3000  ← allowed
PUT /popcorn/q-...?restype=queue → 201/409, Access-Control-Expose-Headers only ← blocked
PUT /popcorn/cont?restype=container → 201, Access-Control-Expose-Headers only ← blocked
```

Close condition: extend the w6ay actual-request branch (and the BK-21 queue
arm) to register `access-control-allow-origin` on matching-origin actual
responses — after which the queue and blob legs flip on the next re-witness
with NO demo-side edit (the blob walk's own close condition, stated in
live_blob.ex, predicts exactly this).

## Residual (regression, different lane): certs

`certs=FAIL(deleted-get: fetch blocked — missing CORS response header)` —
the certs leg was fetch-ported by a concurrent lane and its deleted-get step
now hits the same allow-origin gap on a route outside the KV face. Was a
typed SKIP (TYPED-PERMANENT in BK-15) — now a loud FAIL. Owner: the certs
fetch-port lane; blocker class = the same §Residual lib gap.

## BK-15b edit (disclosed unblock, compile-freeze SLA)

`popcorn_demo/lib/popcorn_demo/live_keyops.ex` `request/1` — the leg passes
`body: ""` on the KV-challenge GET; fetch() refuses GET-with-body outright
("Failed to fetch"). Minimal unblock: GET/HEAD drops the body before
dispatch. Owner of live_keyops.ex is the BK-46 lane (active during my
window; mtime moved twice during my session); this edit is disjoint from
their design (their request/1 comment already stated the GET-body law but
the code kept `body: ""`). Disclosed here per the same-checkout fan-out
law; the BK-46 lane should mirror this disclosure in its own receipt.
Also deleted: my own superseded `popcorn_demo/lib/popcorn_demo/pure_sha256.ex`
— a machine-generated pure-Elixir SHA-256 module drafted when keyops's
`:crypto` dependency looked load-bearing; the BK-46 lane's precomputed-digest
design made it redundant before it ever cooked. The constants generator
(verified against hashlib) is kept at `tmp/bk15b/sha256-sidequest/gen.py`;
no other file outside popcorn_demo/ + tmp/ was touched by this lane.

## Commands + exits

```
just substrate-down                                     # clear orphan lock (pid 38111)
(9>&- just substrate-up)                                # fresh boot, landed BK-21 code
# [STATUS] substrate UP (pid 48942), lock FREE
export PATH="$HOME/.asdf/installs/erlang/29.0.6/bin:$HOME/.asdf/installs/elixir/1.20.4-otp-29/bin:$PATH"
cd popcorn_demo
mix popcorn.cook --out-dir public/out                   # exit 0, "Cooked 8 applications"
node scripts/browser_smoke.mjs                          # run 1: exit 0; runs 2/3: exit 1 (certs/queue FAIL)
mix compile                                             # exit 0 (0 errors) after the keyops unblock
```

## Falsifiers

- mcp/keyops flips are falsified if the next substrate restart drops them
  (they must survive restart — the faces are code, not state).
- The allow-origin residual is falsified if a browser smoke shows
  queue=OK / blob=OK against a substrate that serves allow-origin on
  actual queue/blob responses.
- The blob-leg classifier mislabel is falsified by seeding rules and
  watching the verdict REMAIN "cors-preflight-403" — done here (§B+§C).
