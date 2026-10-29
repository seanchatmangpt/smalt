# KD-114 — SharedKey admit close witness (W20-B)

**Standing:** PASS — blob SharedKey admit landed, wired, and witnessed on the
real official SDK over the TLS twin; the KD-114 DO-NOT-FLIP hold can be
lifted by the coordinator/registrar on this receipt.

- Date: 2026-10-20
- Lane: W20-B (writer lane)
- Subject: /Users/sac/smalt @ main 421f6ab + this lane's uncommitted diff
- KD register row: KD-114 (blob channel divergence — SharedKey refused
  401 MalformedBearerHeader; no SharedKey admit path existed in lib/smalt)
- Files this lane touched:
  - `lib/smalt/auth/shared_key.ex` (new — `Smalt.Auth.SharedKey`:
    2021-12-02 blob-service SharedKey StringToSign, HMAC-SHA256 over the
    DECODED per-account key, constant-time compare, fail-closed refusals)
  - `lib/smalt/auth/bearer.ex` (admission dispatch: a SharedKey-scheme
    Authorization header routes to `Smalt.Auth.SharedKey.verify/1`, tagged
    `# KD-COVERS: KD-114`; every non-SharedKey shape takes the unchanged
    bearer path — bearer and Cosmos resource-token behavior unchanged)
  - `lib/smalt/egress_router.ex` (disclosed minimal seam:
    `udk_account_key/1` now delegates to public
    `Smalt.EgressRouter.account_key/1` — single per-account key
    derivation, no dual truth; UDK mint behavior unchanged)
  - `test/integration/blob_sharedkey_test.exs` (new Chicago court)
  - `verification/ts/kd114-sharedkey.probe.cjs` (new real-SDK probe)
  - this receipt (new)
- Other dirty tree paths belong to concurrent lanes, not this lane's diff.

## Chicago court (in-process, real plug + real router + real ETS store)

Command:

```
MIX_BUILD_ROOT=_build-w20b mix test test/integration/blob_sharedkey_test.exs
```

Actual output (final run, 2026-10-20):

```
Finished in 0.1 seconds (0.00s async, 0.08s sync)
3 tests, 0 failures
```

Legs:

1. valid SharedKey round trip — PUT create container 201, PUT blob 201,
   GET blob 200 byte-equal. The signature is built by an INDEPENDENT
   spec-side helper inside the test, not by the module under test.
2. tampered signature -> 401 typed `AuthenticationFailed`.
3. wrong account key -> 401 typed `AuthenticationFailed`.

## Real-SDK probe (official @azure/storage-blob, real transport, no mocks)

Command (substrate recycled first so the beam ran the new code; pid 9849):

```
NODE_EXTRA_CA_CERTS=.smalt/tls/ca-cert.pem node verification/ts/kd114-sharedkey.probe.cjs
```

Actual output (2026-10-20, https://127.0.0.1:9444):

```
[step] sharedkey-service-client
[step] create-container
PASS sharedkey.create-container.201
[step] upload
PASS sharedkey.put.2xx
[step] list
PASS sharedkey.list.includes-blob
[step] download
PASS sharedkey.download.byte-equal
[step] get-properties
PASS sharedkey.get-properties.2xx
[step] tampered-leg
PASS sharedkey.tampered-refused.401
SUMMARY pass=6 fail=0
exit=0
```

The tampered leg is a real wrong-key signature on the wire via the official
`StorageSharedKeyCredential` (SDK v12 does not route through an
instance-overridable HMAC hook, and a padding-adjacent char flip is a no-op
class — both tried, both discarded; wrong-key credential is the honest
tamper).

Garbage-signature curl cross-check on the same beam:

```
PUT /popcorn/kd114-curl-probe?restype=container  Authorization: SharedKey popcorn:QUJDREVGRw==
-> 401 {"error":{"code":"AuthenticationFailed",
        "message":"The MAC signature found in the HTTP request is not the same as any computed signature."}}
```

## S17-A probe rerun (original falsifier, correct key supplied)

`SMALT_SB_SHARED_KEY=<per-account dev key> NODE_EXTRA_CA_CERTS=.smalt/tls/ca-cert.pem
node verification/ts/kd114.probe.cjs`:

```
PASS bearer.list.includes-blob
PASS bearer.download.byte-equal
NOTE sharedkey leg: ADMITTED (unexpected per lib survey)
SUMMARY pass=2 fail=0  (exit 0)
```

The SharedKey leg flipped from refused (401 MalformedBearerHeader) to
ADMITTED. The NOTE text is S17-A's original wording — it predates the admit
path and is now stale; the close probe (kd114-sharedkey.probe.cjs) is the
authoritative SharedKey witness.

With no key env set (probe default "ws8sharedkey") the same leg refuses
typed:

```
NOTE sharedkey leg refused (typed): The MAC signature found in the HTTP
request is not the same as any computed signature. statusCode=401
```

— the typed wrong-key refusal, witnessed from the original probe surface.

## Honest negatives and scope

- SAS leg: still refused (401). The SAS query-token flow verifies inside the
  egress router AFTER the auth plug, and a SAS-only URI (no Authorization
  header) is refused by the bearer plug first. KD-114's close condition as
  written for this lane was the SharedKey leg; SAS admit is unchanged
  behavior (candidate follow-up for the registrar, not claimed here).
- Full offline suite on the lane build root: 200 tests, 14 failures — all
  14 in surfaces this lane did not touch (internal-tier census allowlist,
  KD-115 credit-first, cluster join, cosmos analytical-TTL, sb_topic_fanout,
  cosmos_sql_raise). Classified pre-existing / concurrent-lane: census
  drift lists internal-tier files owned by other lanes (kd115 file was
  dirty before this session per initial git status); every failure is
  outside lib/smalt/auth + blob face. Lane-owned surfaces green: my court
  3/3, blob_k1_rows + healthz_cors neighbors 12/12.
- Probe tamper forensics (disclosed): two discarded tamper attempts
  (instance-hook override — hook never invoked by the SDK pipeline; last
  char flip — lands on base64 padding). The final wrong-key leg is the one
  that genuinely puts a bad signature on the wire.

## Registrar handoff

The KD-114 DO-NOT-FLIP hold can now be lifted: SharedKey admit is landed,
court-verified, and witnessed live on the official SDK (6/6 probe, 3/3
court, typed refusals on tamper and wrong key). Flip should proceed via
`scripts/kd_flip.py --apply` gated on this receipt (it postdates the lane's
lib changes).
