# KD-62 — user-delegation-key admission seam witness (W13-F)

- **Date**: 2026-10-20
- **Lane**: W13-F (continuation; prior run died on API 429 before landing)
- **Standing**: PARTIAL_ALIVE (route + both faces witnessed on the live wire
  on a lane-private substrate boot of the edited tree; the shared 8443
  substrate predates the edit — live flip needs the next substrate recycle)
- **Context**: solo
- **KD register row**: `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` KD-62
  (row text re-read this session; close condition admits a
  "typed-UNSUPPORTED admission seam")

## Diff

- `/Users/sac/smalt/lib/smalt/egress_router.ex` — surgical: the existing
  `post "/:account"` arm (comp=batch) gained a `comp=userdelegationkey`
  branch (cond, inside `blob_route`); helpers `udk_window/1`,
  `udk_account_key/1`, `udk_string_to_sign/3` added adjacent. No other arm
  touched; no shared infra edited. `# KD-COVERS: KD-62` marker in the arm.
- `/Users/sac/smalt/test/integration/kd62_udk_witness_test.exs` — new
  plug-conn witness court (4 tests).

## Envelope shape (as registered)

`signedObject` {account, service="b", version="2021-12-02"}, `tenant`,
`user`, `delegatedUser`, `issuedTo`, `value`, `expiry` — backed by real
service metadata: `value` = base64 HMAC-SHA256 over the UDK string-to-sign
`account\nb\n2021-12-02\nstart\nexpiry`, keyed with the configured
`blob_account_key`, else the deterministic per-account dev key in the
`scripts/dev_env.sh` derivation shape (sha256(account <> "smalt-dev-sb"),
base64). Signed window from the Azure `<Start>/<Expiry>` body, default
[now, now+1h]. Body read through the KD-108 `acl_body/1` raw-cache seam
(form-encoded Content-Type is consumed by the egress Plug.Parsers — the
same seam the KD-108 arm documents; real Azure clients send
`application/xml` here).

## Verification ladder (real output)

1. **Compile** (`MIX_BUILD_ROOT=_build-w13f mix compile`): clean; only the
   pre-existing `Smalt.DataPlane.Cosmos.effective_ttl/2` warning.
2. **Plug-conn court**:
   `MIX_BUILD_ROOT=_build-w13f mix test test/integration/kd62_udk_witness_test.exs`
   → `4 tests, 0 failures`:
   - envelope fields + independent recomputation of `value` (test rebuilds
     the dev key and the HMAC, asserts byte equality),
   - default window [now, now+1h] on empty body,
   - unknown comp stays typed 404 RouteNotFound,
   - SAS-only URI (sig=, no x-ms-version) → typed 401/403, never
     MissingXMsVersion.
3. **Live wire** (lane-private substrate, ports 39710-39715, booted from
   `_build-w13f` with the edit; token from the lane STS, then):
   - `POST /acct-kd62?comp=userdelegationkey` (x-ms-version 2023-11-03,
     Content-Type application/xml, signed window in body) → **HTTP 200**:
     envelope with `signedObject: {account: acct-kd62, service: b,
     version: 2021-12-02}`, `expiry: 2026-10-20T02:00:00Z` (the signed
     window from the request body, honoured), `value:
     YYtQI1e/3P+xIIGCBtTyheArHBr2tx9UNoEnNM3yp/A=` — exact JSON on disk:
     `tmp/udk_w13f.json`.
     `YYtQI1e/3P+xIIGCBtTyheArHBr2tx9UNoEnNM3yp/A=`).
   - **Independent HMAC recomputation (python3, hashlib/hmac)**:
     `expected: YYtQI1e/3P+xIIGCBtTyheArHBr2tx9UNoEnNM3yp/A=` — byte-equal
     to the wire `value`. The envelope key material is real, not a stub.
   - SAS-only URI (`sig=AAAA%3D%3D&se=2099-01-01...`, no x-ms-version) →
     **HTTP 401**
     `{"error":{"code":"AuthenticationFailed","message":"MissingBearerToken"}}`
     — the K1 typed refusal class, never MissingXMsVersion. KD-62's
     falsifier ("SAS URI without x-ms-version → typed admission decision,
     never MissingXMsVersion") holds on the wire.
   - Unknown comp → **HTTP 404 RouteNotFound** (typed, fail-closed).

## Standing detail / boundaries

- The SAS **signature-verification face stays typed**: this is the
  registered "typed-UNSUPPORTED admission seam" — no sig= HMAC admission
  change beyond K1's existing typed verification (Smalt.Auth.Sas). SAS-only
  URIs are refused typed at the auth layer before this arm.
- The shared 8443 substrate was booted before this edit and still answers
  401 on the new route's envelope face (observed: POST with bearer →
  401 MissingBearerToken challenge... actually observed 401 at the auth
  layer with the pre-edit tree) — **live flip lands at the next substrate
  recycle**; the plug-conn court + the lane-private live boot above are the
  witnesses of the edited tree.

## Falsifier status

KD-62 falsifier exercised on the live wire: SAS-only URI returned the typed
admission decision (401 challenge class), MissingXMsVersion nowhere in the
response. Route face: 200 envelope with independently recomputed real HMAC.
KD-62 remains OPEN in the register (register flip is receipt-gated and
coordinator-owned; this receipt is the evidence row for that flip).
