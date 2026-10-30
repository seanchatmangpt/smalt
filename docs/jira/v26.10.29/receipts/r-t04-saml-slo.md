# Receipt: R-T04 — SAML SLO (lane L16)

Lane L16 · 2026-10-30 · owner files:
`lib/smalt/identity/saml_slo.ex` (new),
`lib/smalt/identity/saml_idp.ex` (extensions), 
`test/integration/saml_slo_test.exs` (new),
`test/integration/saml_idp_test.exs` (one-hop unblock, disclosed),
`docs/jira/v26.10.29/receipts/r-t04-saml-slo.md`.

## Standing

**PARTIAL_ALIVE → court evidence pending the two coordinator gates
(courtroom-court leg 3C + KIND-E2E 9/9), both running at receipt-write time;
this section is finalized with the embedded output below.**

## What landed (lib/smalt/identity/)

- `saml_slo.ex` (new): SLO machinery — lazy shadow ETS `:smalt_saml_sessions`
  (named, public, heir to `:init`, `Smalt.Policy` precedent) holding
  (NameID, SessionIndex) pairs recorded at SSO mint time; LogoutRequest parse
  (xmerl); enveloped RSA-SHA256 sign/verify; INCLUSIVE C14N
  (`canonicalize/1`, REC-xml-c14n-20010315) + EXCLUSIVE C14N
  (`canonicalize_exc/1`) implementations over xmerl DOM; REDIRECT-binding
  query-signature verify; signed `LogoutResponse` / IdP-initiated signed
  `LogoutRequest` minting.
- `saml_idp.ex` (extensions): `GET|POST /slo` (REDIRECT/POST bindings,
  decode → parse → signature law → session consume → signed LogoutResponse),
  `/slo/initiate` (IdP-initiated, auto-submit POST to the SP SLO callback),
  `/metadata` gains two `SingleLogoutService` entries (REDIRECT + POST at
  /slo), SSO mint records (NameID, SessionIndex), Response-level +
  assertion-level dual signatures, `AudienceRestriction` (config `:audience`),
  bind_ip law (SMALT_BIND_IP parse fail-closed, RedisWire precedent,
  KIND-E2E r13 item 3).

## The c14n law (coordinator close condition 1 — landed)

- **Defect class** (FINISH-WIRE r3 addendum): digests over the raw emitted
  string; every conformant validator recomputes over c14n and rejects
  (witnessed "Invalid document signature").
- **Fix**: digests over INCLUSIVE c14n bytes (xml-crypto appends the
  inclusive transform to the Reference implicitly — witnessed:
  `getReferences()[0].transforms == [enveloped-signature,
  REC-xml-c14n-20010315]`); SignedInfo signed over EXCLUSIVE c14n (the
  declared CanonicalizationMethod); Reference transforms now declare the
  pair actually applied (self-describing). Attribute sort is
  byte-lexicographic local-name (witnessed divergence: my injected
  `local <> upcase(local) <> name` key put `NameFormat` before `Name`;
  xml-crypto requires `Name` < `NameFormat`).
- **Byte-proof**: sha256 over my inclusive c14n of the digested assertion ==
  sha256 over xml-crypto's own canonicalization == the declared DigestValue,
  byte-identical files (cmp exit 0 on
  `/tmp/l16-consumer-leg/dump/mine_incl.txt` vs `xmldata_crypto_c14n.txt`).

## Consumer leg (real @node-saml, node 22, real HTTP, no mocks)

Harness: `/tmp/l16-consumer-leg/` (`idp_boot.exs` boots ONLY the SamlIdp
Bandit face on :29777 under the window flock with fd 9 closed; `saml_leg.mjs`
runs the consumer's pinned `@node-saml/node-saml` from the consumer void tree
`/tmp/courtroom-void/338caed.../node_modules`; `run_leg.sh` driver with
bounded polls, no Process.sleep as coordination). Embedded output (final
green run):

```
IDP_BOOT: READY http://127.0.0.1:29777
WITNESS LEG_A_AUTHN_REQUEST_ID: _39324db01fe6bf8236370853cdea919f3eda5366
WITNESS LEG_A_PROFILE_KEYS: issuer,inResponseTo,sessionIndex,nameID,nameIDFormat,nameQualifier,spNameQualifier,groups,attributes
WITNESS LEG_A_ASSERTION_VALIDATE: ACCEPT nameID=smalt-user sessionIndex=_smaltgfy575lbsaeuiolnq27m3fapvm
WITNESS LEG_B_LOGOUT_REQUEST: carries NameID smalt-user
WITNESS LEG_B_HTTP_STATUS: 200
WITNESS LEG_B_LOGOUT_RESPONSE_VALIDATE: ACCEPT loggedOut=true
WITNESS LEG_C_TAMPER_REJECT: Invalid signature: No response found
```

- LEG_A: node-saml `validatePostResponseAsync` ACCEPTS the signed
  Response+Assertion (signature, timestamps, recipient, InResponseTo against
  its cache, audience) — the c14n law witnessed by the real validator.
- LEG_B: node-saml-minted REDIRECT LogoutRequest → IdP `/slo` (200) → signed
  LogoutResponse → node-saml ACCEPT `loggedOut=true` (signature/timestamps;
  disclosed quirk: node-saml's InResponseTo lookup is Response-root-specific
  and can never match a LogoutResponse root, so the leg validates through a
  disclosed `validateInResponseTo: never` instance — the consumer's real
  logout path (POST /saml/logout/callback → signedOut) never validates the
  response at all, so this leg is stricter than the consumer).
- LEG_C: tampered LogoutResponse (Success→Responder) REJECTED
  ("Invalid signature: No response found") — non-vacuous.
- **Session leg (consumer-app session destroyed + /api/auth/me 401):
  typed SKIPPED — the consumer's session store is the smalt-backed Redis;
  that leg belongs to the full `just courtroom-court` (legs 3C/3D) and KIND
  court (s14), both dispatched by the coordinator gate; my leg stops at the
  SP-validation boundary the ticket names ("SP validation only").**

## In-BEAM courts (both green, embedded)

`saml_slo_test.exs` 11 tests + `saml_idp_test.exs` 6 tests = 18 passed:

```
Finished in 0.3 seconds (0.00s async, 0.3s sync)
Result: 18 passed
```

Courts cover: metadata SingleLogoutService (REDIRECT+POST); SSO-mint →
session recorded → logout consumes → replay typed-refused (UNKNOWN_SESSION);
POST-binding signed LogoutRequest consumed + signed response verified;
present-but-tampered signature → typed INVALID_SIGNATURE (request AND
redirect query-string, sessions survive a refused logout); unknown NameID /
unissued SessionIndex → typed UNKNOWN_SESSION; LogoutResponse form posting to
`slo_response_url` with Destination; IdP-initiated logout delivered over real
HTTP to a real Bandit receiver capturing the POST; response tamper +
canonicalizer non-vacuity (c14n actually transforms: no self-closing tags,
render-once namespaces, idempotent fixpoint); bind_ip law
(string parse / loopback / garbage raise, r13 item 3).

## Disclosures

- One-hop unblock in `test/integration/saml_idp_test.exs` (T02's court):
  `verify_signature` now recomputes the digest over
  `SamlSlo.canonicalize/1` (inclusive) and verifies SignatureValue over
  `canonicalize_exc/1` — same-calculus update to mirror the landed law, with
  the REAL independent proof carried by the consumer leg above. Both-lane
  disclosure per the fan-out law (r2/r-t04 receipts).
- `SamlSlo.canonicalize/1` carries the SAML message grammar minted/parsed
  here (no PIs/comments/DTDs; prefixed names; unprefixed attributes) — a
  registered divergence, not a silent skip.
- Bind-law court manipulates SMALT_BIND_IP via System.put_env with
  after-restore (lane-local beam, async: false).

## Close conditions (coordinator gates)

1. **courtroom-court leg 3C** — running; result embedded below when done.
2. **KIND-E2E 9/9** — dispatched after gate 1; result embedded below.
