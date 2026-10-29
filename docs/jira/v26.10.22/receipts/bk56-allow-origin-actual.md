# BK-56 — Actual-response `Access-Control-Allow-Origin` (BK-15b single typed lib residual)

**Standing:** ALIVE
`Context: solo`
Date: 2026-10-22

## Scope

Closes the single typed lib residual from
`docs/jira/v26.10.21/receipts/bk15b-skip-rewitness.md`: actual (non-preflight)
data-plane responses outside the KV CORSPlug pipeline carried no
`access-control-allow-origin`, so browsers blocked the real response even when
the preflight passed 204. Owned surface: `lib/smalt/egress_router.ex` only.
No commit (coordinator lands).

## Changes (lib/smalt/egress_router.ex)

1. **Queue actual requests** — new `queue_actual_cors?/1` arm in
   `egress_cors/2`: non-OPTIONS request on a queue shape whose `Origin` is
   loopback (`loopback_origin?/1`, BK-21's gate) diverts to `queue_mcp_cors/1`
   → `static_cors/1` (CORSPlug registers the allow face on actual responses).
   Nil-origin passes through untouched; non-loopback origins take the ordinary
   path and get no allow face (loopback-only posture preserved).
2. **w6ay blob actual branch** — when the request `Origin` is loopback, the
   actual response now also registers the KV CORSPlug face (echoed
   allow-origin + allow-credentials); the rule-based
   `Access-Control-Expose-Headers` registration is unchanged. Non-loopback
   origins keep the prior posture (rule-based only).
3. **deletedcertificates plane exclusion** — `deletedcertificates` added to
   the `blob_plane_path?/1` first-segment exclusion list; the certs plane's
   soft-delete surface was falling into the w6ay blob branch (account
   heuristic), which is where the certs deleted-get leg hit the gap. The rest
   of the certificates plane was already excluded (static_cors → KV face).

## Wire evidence (before → after)

Before (BK-15b §C, verbatim): queue/blob actual responses carried
`Access-Control-Expose-Headers` only — no allow-origin. After (verbatim from
`/tmp/bk56/wire-witness.txt`, substrate pid 14386, MIX_BUILD_ROOT=_build-bk56):

```
-- queue actual PUT (loopback Origin):   401 +
  access-control-allow-credentials: true
  access-control-allow-origin: *
  access-control-expose-headers: www-authenticate
-- deletedcertificates GET (loopback):   401 + allow-credentials/allow-origin: *
-- queue preflight OPTIONS (unchanged):  204 + identical KV face
  (allow-credentials/allow-origin/allow-methods/max-age — BK-21 face intact)
-- queue actual PUT (non-loopback):      no access-control-allow-* headers
-- blob container PUT (loopback):        401 + allow-credentials/allow-origin: *
```

Allow-origin emits `*` (CORSPlug `["*"]` config posture). Demo fetches are
non-credentialed, so `*` + allow-credentials is accepted by the browser —
witnessed by the OK legs below.

## Browser flip evidence (close condition ran itself)

Fresh substrate bounce (scripts/substrate.sh, lock fd closed, pinned
toolchain PATH + MIX_BUILD_ROOT=_build-bk56; pid 14386, never restarted during
the witness). `node scripts/browser_smoke.mjs` (headless Chromium via
chrome-headless-shell), 2 runs, no demo-side edit:

- run 1 exit 0: `queue=OK(popcorn-q-1792642201290-932977:74-bytes-roundtrip)`;
  `certs=OK(popcorn-cert-490:purge)`
- run 2 exit 0: `queue=OK(popcorn-q-...-726900:74-bytes-roundtrip)`;
  `certs=OK(popcorn-cert-482:purge)`

Baseline (BK-15b): `queue=FAIL(create-queue: fetch blocked — missing CORS
response header)`, `certs=FAIL(deleted-get: fetch blocked — missing CORS
response header)`. Both flipped to OK with zero popcorn_demo changes — the
receipt's own close condition ("NO demo-side edit").

Negative leg: non-loopback `Origin: http://evil.example.com` queue PUT carries
no `access-control-allow-*` headers (wire witness above); non-loopback
preflight still 403.

## Commands / exits

```
export PATH="$HOME/.asdf/installs/erlang/29.0.6/bin:$HOME/.asdf/installs/elixir/1.20.4-otp-29/bin:$PATH"
MIX_BUILD_ROOT=_build-bk56 mix compile                     # exit 0 (fresh lane build root)
just substrate-down                                        # exit 0
9>&- MIX_BUILD_ROOT=_build-bk56 just substrate-up          # UP, pid 14386 (bounded poll on /healthz)
node scripts/browser_smoke.mjs                             # exit 0 ×2 (see receipts above)
```

## Standing

ALIVE for the residual's close condition: queue and certs legs flip in-browser
2/2 runs on a substrate carrying the fix, negative leg clean, preflight faces
byte-identical. Blob leg remains `SKIP(cors-preflight-403)` — the demo-side
classifier mislabel (BK-15b §"mislabelled"); the w6ay actual-response face now
exists on the wire (blob container PUT carries allow-origin), so the blob leg
is unblocked at the lib level for its owner lane.
