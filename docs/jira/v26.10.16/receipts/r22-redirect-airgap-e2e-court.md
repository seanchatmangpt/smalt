# Receipt — R22 (redirect:"error" air-gap + e2e court)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 repair wave)
- **Standing:** PASS
- **Date:** 2026-10-15 (witnessed by W1 wave-2 docs lane)

## Subject files

- `workspace/lib/copilot/session-ledger.ts` (`guardedFetch` now defaults
  `redirect: 'error'` on every egress attempt and air-gap checks via
  `assertLocalUrl` before any fetch; every attempt ledgered in request order
  with post-settle outcome patching excluded from the hash)

## Defect

`assertLocalUrl` validated only the initial URL: an off-host 30x
`Location` could carry the read off-host, defeating the air gap; ledger
entries were appended only after a successful fetch, so refused/failed
attempts were unaudited.

## Fix

`guardedFetch` (workspace/lib/copilot/session-ledger.ts): ledger the attempt
BEFORE any check, `assertLocalUrl(url)` before egress (throw → outcome
`refused-airgap`), `fetch(input, { redirect: 'error', ...init })` so a 30x
cannot follow off-host, outcomes patched after settle (`ok` /
`refused-airgap` / `fetch-error`).

## Verification (2026-10-15, W1 wave-2 docs lane, unedited output)

```
$ just ws-court
...
[PASS] composition: panel component type-surface — tsc --strict --noEmit clean over components+app+lib
[PASS] live: ARM read-only probe — GET http://127.0.0.1:9443/subscriptions?api-version=2020-01-01 -> 200 (...)

# court verdict
# PASS=42 FAIL=0 SKIP=1
# SKIP: composition: panel rendering: DOM/Web Serial rendering is not executable in node — witnessed instead at the type layer below
```

42 PASS / 0 FAIL / 1 SKIP (loud, typed skip), exit 0.
