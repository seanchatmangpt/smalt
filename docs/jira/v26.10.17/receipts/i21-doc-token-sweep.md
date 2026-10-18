# i21-doc-token-sweep — stale `InvalidQueryParameter` token sweep (lease docs)

Standing: PASS
Context: solo (grep + docs-dod-check over docs/)
Lease: `docs/reference/egress-data-plane.md`, `docs/explanation/ggen-projection-law.md`, `docs/compliance/C4_BLOB.md`
Date: 2026-10-17

## Finding

Source truth: the token rename to `InvalidQueryParameterValue` landed in
lib/ 2026-10-17 (KD-04, fix landed per
`docs/jira/v26.10.14/KNOWN_DIVERGENCES.md:20`, witness
`docs/jira/v26.10.16/receipts/kd04-token-rename-witness.md`).
`grep -rn InvalidQueryParameter lib/ | grep -v Value` → zero matches:
`blob_storage.ex:104,120,351,354,362` and `egress_router.ex:3526,3535,3540`
all use the new name; `docs/ERROR_CODES.md:49` is regenerated to the new
token.

The "maxresults arm deliberately keeps the OLD token" reading
(`KNOWN_DIVERGENCES.md:76` cross-check prose) is the pre-rename state — the
KD-04 row itself records the rename as LANDED with flip pending kd_flip, so
prose was updated to the new name and the historical deliberate shape is
preserved only as a commented historical reference (no live claim of the old
token).

## Edits (file:line, all in lease)

1. `docs/reference/egress-data-plane.md:53` — refusal-vocabulary 400 list
   (stated as generated from `docs/ERROR_CODES.md` egress rows):
   `InvalidQueryParameter` → `InvalidQueryParameterValue`. Matches
   ERROR_CODES.md:49 exactly.
2. `docs/reference/egress-data-plane.md:83` (KD cross-links, KD-04 bullet) —
   rewritten to name the delta and its history with the deliberate-old-token
   context preserved as a comment:
   "KD-04 blob error-code token delta: source now emits 400
   InvalidQueryParameterValue (renamed 2026-10-17 across lib/, receipt
   `docs/jira/v26.10.16/receipts/kd04-token-rename-witness.md`); the
   maxresults arm briefly kept the old `InvalidQueryParameter` token as a
   deliberate post-lane-06 shape (KD register
   `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md:76`) until the KD-04 rename
   landed — flip pending kd_flip pass".

Non-lease stale sites found but NOT touched (outside lease; coordinator
routes): `docs/WIRE_PARITY.md:122,132,269`; historical window docs
(`v26.10.14/06-blob.md`, `v26.10.14/KNOWN_DIVERGENCES.md:76`,
`v26.10.15/24-sdk-docs-corpus-mining.md`,
`v26.10.16/receipts/kd04-token-rename-witness.md`,
`v26.10.17/verify-ledger/*`) — historical, left as-is.
`docs/audit/sections/aud1-blob-cosmos.md:118` already uses the new token.

## Verification (real output)

```
$ grep -rn "InvalidQueryParameter" docs/reference/egress-data-plane.md docs/explanation/ggen-projection-law.md docs/compliance/C4_BLOB.md | grep -v Value
docs/reference/egress-data-plane.md:86:  arm briefly kept the old `InvalidQueryParameter` token as a deliberate
```
(sole remaining old-token hit is the commented historical reference — intended)

```
$ just docs-dod-check; echo "exit=$?"
... (all rows OK) ...
OK    README.md
exit=0
```

`just docs-dod-check` exit 0, all 53 checks OK.
