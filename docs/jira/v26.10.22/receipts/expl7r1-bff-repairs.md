# EXPL7-R1 — BFF sync + bench/debug route repairs (E7-1..E7-4)

**Standing:** **ALIVE** — all repairs landed on the working tree and witnessed with
real route probes (real Next dev server + real substrate, zero mocks).
Context: solo
Date: 2026-10-22
Repo: /Users/sac/smalt (main)
Lane: EXPL7-R1
Parent finding: `expl7-bff-courts-errc.md` (E7-1..E7-4)

## E7-1 — /api/sync/state caller gate + premise-rot repair

Landed BOTH halves: a real gate AND the KD registration of the residual
posture.

- Gate: `assertLoopbackCaller` in `workspace/app/api/sync/state/route.ts` —
  Host header (port-stripped) and, when present, Origin header must be a
  loopback host (127.0.0.1 / localhost / ::1), else typed 403
  `sync_state_non_loopback`. Best-effort vs header spoofing; the posture is
  registered as **KD-171** in `docs/jira/v26.10.22/KNOWN_DIVERGENCES.md`
  (loopback-open per the air-gap law, KD-169 precedent) with close condition
  "shared-secret/HMAC caller gate + off-host witness court".
- Premise rot REPAIRED: the false sentence "Authenticity of batch entries
  requires the BFF session, not the client sig" is deleted; the header now
  states the actual posture ("Caller posture: this face is loopback-open
  (KD-171) — there is NO caller session; the only gate is the loopback-host
  check"). The sig contract wording changed from "the session key" to "the
  HMAC key" (no session exists). The substrate-side "Auth:" line is now
  explicitly "Auth to substrate" (the Bearer authenticates BFF->substrate,
  never caller->BFF).

Witness (real Next dev server on :3123):

```
$ curl -X POST :3123/api/sync/state -H 'Host: evil.example.com' -d '[{"id":"x","data":{"a":1}}]'
{"error":"sync_state_non_loopback","detail":"non-loopback host \"evil.example.com\""} status=403
$ curl -X POST :3123/api/sync/state -H 'Host: 127.0.0.1:3123' -H 'Origin: http://evil.example.com' ...
{"error":"sync_state_non_loopback","detail":"non-loopback origin \"evil.example.com\""} status=403
$ curl -X POST :3123/api/sync/state -H 'Host: 127.0.0.1:3123' ...   (substrate DOWN)
{"error":"sync_state_upstream_auth","detail":"TypeError: fetch failed"} status=502   <- gate passed, route ran
$ (substrate UP) non-loopback Host again -> status=403
```

## E7-2 — createDoc identity swap closed

`createDoc` upsert body is now `JSON.stringify({ ...data, id })` (validated
id wins), with a comment pinning the invariant. Live end-to-end witness
(dev server + real substrate cosmos face on :8443):

```
$ curl -X POST :3123/api/sync/state -H 'Host: 127.0.0.1:3123' \
    -d '[{"id":"vdoc-1","data":{"id":"ATTACKER-ID","payload":"p1"}}]'
{"applied":[{"id":"vdoc-1","etag":"\"c93a552f-1b2e-499e-8691-b3e835c6ba9a\"","status":"applied"}],
 "conflicts":[],"errors":[]} status=200
$ curl :8443/dbs/sync/colls/state/docs/vdoc-1          (bearer from loopback STS)
{"_etag":"\"c93a552f-...\"","_self":".../docs/vdoc-1","id":"vdoc-1","payload":"p1"} status=200
$ curl :8443/dbs/sync/colls/state/docs/ATTACKER-ID     -> status=404
```

The stored doc identity equals the validated id; ATTACKER-ID does not exist;
the applied row's etag matches the stored doc. (Probe doc deleted after the
witness: DELETE -> 204.)

## E7-3 — bench/debug faces env-gated

All five faces now answer typed 404 `{"error":"not_found"}` unless the server
was started with `SMALT_DEBUG_FACES=1` (`workspace/lib/debug-faces.ts`:

- `POST /api/v1/stream` (x-smalt-storm abort) — one-request DoS face
- `GET /api/v1/stream?stats=1` and `?drift=1`
- `GET /api/v1/ingest` (heap + token-bucket counters)
- `POST /api/bench/isr-revalidate` (arbitrary-slug revalidatePath)
- `POST /api/bench/isr-stats` (reset / stale-report; GET left open — read-only)

Witness (gate OFF, fresh dev server without the env):

```
storm POST -> {"error":"not_found"} status=404
stream?stats=1 -> 404 | ingest GET -> 404 | isr-revalidate POST -> 404 | isr-stats POST -> 404
```

Witness (gate ON, `SMALT_DEBUG_FACES=1 npx next dev`):

```
storm POST -> {"aborted":0} 200 | stats -> {"active":0,...} 200
ingest GET -> {"capacity":20000,...,"heap":{...}} 200
isr-stats POST {reset:true} -> {"ok":true,"reset":true} 200
isr-revalidate POST {"slugs":["probe"]} -> {"ok":true,"revalidated":1} 200
```

**Lane consequence (not editable in-lane)**: bench lanes N-6/N-7
(`scripts/bench/n6_isr_stampede.mjs`, `scripts/bench/n7_sse_herd.mjs`) use
these faces and must launch their Next server with `SMALT_DEBUG_FACES=1` —
their next run will 404 on stats/storm/reset otherwise. Handoff to the
bench-lane owners / coordinator.

## E7-4 — e2e-court air-gap guard dedupe

Two hand-copied `assertLocalUrl` functions removed from
`workspace/scripts/e2e-court.mjs`; both legs now import the single shared
`workspace/scripts/lib/airgap.mjs` (provenance comment: mirrors
`lib/smalt.ts` assertLocalUrl; a premise-drift court leg comparing the two
copies is the registered close condition).

Witness:

```
$ node scripts/e2e-court.mjs        (substrate DOWN)
# PASS=67 FAIL=0 SKIP=3   exit=0    (ARM live leg SKIP: substrate down)
$ node scripts/e2e-court.mjs        (substrate UP)
# PASS=68 FAIL=0 SKIP=2   exit=0    <- ARM live leg PASS through the deduped guard
```

## Verification ladder (fresh runs, 2026-10-22)

```
$ just ws-lint                                    -> clean, exit 0
$ for f in codec receipt snapback dom-contract tab-lease spof4; do node scripts/$f-court.mjs; done
codec PASS (0 failures) | receipt all-passed | snapback all-passed
dom-contract PASS (0 failures) | tab-lease 7/0 | spof4 19/0     (all exit 0)
$ node scripts/e2e-court.mjs                      -> PASS=68 FAIL=0 SKIP=2, exit 0
$ SYNC_TEST_BASE_URL=http://127.0.0.1:3123 node --test app/api/sync/state/route.test.ts
tests 10 / pass 10 / fail 0 / skipped 0   (both live-POST legs ran for real)
```

## Standing

ALIVE — every repair executed against a real Next server and (E7-1/E7-2) the
real substrate data plane; probe doc cleaned up (DELETE 204); dev server
stopped. Residual open posture is registered, not silent: KD-171. Handoffs:
bench-lane owners must set `SMALT_DEBUG_FACES=1` (N-6/N-7); close condition
for KD-171 is a shared-secret caller gate with an off-host witness court.
