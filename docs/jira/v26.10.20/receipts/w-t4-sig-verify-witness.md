# W14-T4 — /api/sync/state sig structure verification (integrity binding)

**Standing: ALIVE** — sig-structure validation landed in
`workspace/app/api/sync/state/route.ts`, 10/10 tests pass including both
live-POST legs against a real Next server (:3100) + real substrate (:8443).
Lane: W14-T4, repo /Users/sac/smalt. Context: pair (BFF route + route.test.ts).

## Diff (owned files)

- `workspace/app/api/sync/state/route.ts`
  - Header contract: `sig` is optional-but-verified — INTEGRITY BINDING ONLY,
    NOT AUTHENTICITY (session key client-held per page load, per
    `workspace/lib/delta.ts`; server cannot verify an HMAC whose key never
    left the client; authenticity requires the BFF session).
  - `validateEntry` (exported, was private `validate`): if `sig` present it
    must be canonical unpadded base64url of 32 bytes (43 chars,
    `SIG_RE = /^[A-Za-z0-9_-]{43}$/`) AND the delta (`data`) must carry
    `signedAt`; otherwise typed per-entry refusal row
    `{ status: "error", reason: "invalid_signature" }`, entry not applied.
    Sig check is additive — `invalid_entry` checks run first.
  - LWW-by-design documented in the header contract AND at the unconditional
    branch (route.ts `ifMatch = null; // no baseVersion -> LWW-by-design`),
    per T2's finding (T2 chose doc-comment route over `requireBaseVersion`).
  - Import: `"@/lib/smalt"` -> `"../../../../lib/smalt.ts"` (relative, .ts
    extension) so `node --test` with native type stripping can import the
    module without a bundler alias. Next + TS bundler resolution accept it.
- `workspace/app/api/sync/state/route.test.ts` (new, 10 tests)
  - Pure `validateEntry` legs: well-formed 43-char sig + signedAt accepted;
    `not-base64url`, truncated (42 chars), padded (44 chars), non-string,
    and well-formed-but-missing-signedAt all -> `invalid_signature`;
    no-sig accepted (optional); empty id still `invalid_entry`.
  - Live legs (loud SKIP when `SYNC_TEST_BASE_URL` unset): real POST to a
    real Next server; well-formed sig -> `applied`; `not-base64url` ->
    `invalid_signature` row, not applied. Fetch goes through
    `assertLocalUrl` (air-gap lint rule respected).
- `workspace/tsconfig.json` — ONE LINE, disclosed per compile-freeze
  disclosure law (tsconfig is outside my owned-file list; minimal unblock):
  `"allowImportingTsExtensions": true` (requires/safe with the existing
  `noEmit: true`). Without it, TS5097 rejects the .ts extension specifier the
  `node --test` harness requires. No other tsconfig change.

## Commands + outputs

    cd /Users/sac/smalt/workspace
    SYNC_TEST_BASE_URL=http://127.0.0.1:3100 node --test app/api/sync/state/route.test.ts
    ℹ tests 10  ℹ pass 10  ℹ fail 0  ℹ skipped 0  (348 ms)

    just ws-lint    -> exit 0  (28 warnings, 0 errors — all warnings pre-existing)
    just ws-build   -> exit 0

Raw curl live witness (sig 6EwFMvZIi4xbe6XRo0ZwGTQwMfjSeINDdegjTuvv7-A, 43 chars):

    == well-formed sig ==
    {"applied":[{"id":"w14t4-curl-ok-2","etag":"\"84e1d7d51747dcf62b127a781c27cd35196224fffc99509b7a3cc9543d0dbcbd\"","status":"applied"}],"conflicts":[],"errors":[]}
    == sig not-base64url ==
    {"applied":[],"conflicts":[],"errors":[{"id":"w14t4-curl-bad-2","reason":"invalid_signature"}]}

Negative curl probe (padded 44-char sig, my first curl attempt left the
trailing `=`): refused `invalid_signature` — proves the canonical-unpadded
check fires, not a vacuous pass.

## Falsifier status

- Claim "route ignores sig entirely" — falsified as of this change: ill-formed
  sig now produces a typed per-entry refusal and the entry is NOT applied.
- T2's LWW finding — addressed by doc-comment route (explicit LWW-by-design).

## Notes / residual

- Pre-existing (not session-introduced): `workspace/test/airgap_egress.test.ts`
  fails under `node --test` (stale `../src/lib/...` import path; `src/lib`
  contains no airgap-fetch). Reported, not fixed (not in my file set).
- Pre-existing: 28 eslint warnings across workspace (0 errors).
- Live legs need the substrate (:8443/:9443) and a Next dev server on :3100;
  without `SYNC_TEST_BASE_URL` they are loud SKIPs (exit contract preserved).
