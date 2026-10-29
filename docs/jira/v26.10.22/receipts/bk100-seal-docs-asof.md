# BK-100 — Seal-docs as-of annotations (BK-85 propagation)

**Standing:** **PASS** — one stale-current site found and annotated; docs-dod exit 0.
Context: solo

## Premise

BK-85 (`receipts/bk85-seal-invariant.md`) falsified the trust_profile PQC
fallback's root cause: the caller never wrote the delta bytes to the guest
block, so every seal refused `{:error, :invariant_violation}`. Successful
seals are now witnessed and KD-164 is CLOSED-WITH-EVIDENCE. Task: find docs in
`docs/jira/v26.10.21/` or `v26.10.22/` that still present "no successful seal
possible" / "seal always refuses" as CURRENT state, and add dated as-of
annotations only (no history rewrites).

## Method

```
grep -rn -iE "no successful seal|seal always refuses|invariant_violation|PQC_NOT_PROVISIONED|unverified_blake3_host" \
  docs/jira/v26.10.21 docs/jira/v26.10.22
# follow-up sweep for looser phrasing:
grep -rn -iE "successful seal|seal.*refus|refus.*seal" docs/jira/v26.10.21 docs/jira/v26.10.22 | grep -v bk85-seal-invariant
```

## Sites found

| Site | Verdict | Action |
|---|---|---|
| `docs/jira/v26.10.22/receipts/spof3-affidavit-fixes.md` lines 91–97 (Observation 1: "seal invariant gate fails deterministically … always falls back to `:PQC_NOT_PROVISIONED`") | STALE-AS-CURRENT | Annotated with `[AS-OF 2026-10-21, BK-85]` block citing `receipts/bk85-seal-invariant.md` + KD-164: root cause was a caller bug, fixed; successful seals witnessed; fallback no longer fires |
| `docs/jira/v26.10.22/receipts/bk85-seal-invariant.md` | the correction itself — describes the pre-fix state as historical | none (correct as written) |
| `docs/jira/v26.10.21/KNOWN_DIVERGENCES.md` line 26 | already carries "seal refused deterministically — CLOSED-WITH-EVIDENCE (caller-bug fix)" | none (already current) |
| All other hits (`VALIDATION.md`, `SNIPPET-REVIEW.md`, `GRAPHLAW-*.md`, `gl12-*`, `ath3-*`, `w3cc-*`, `spofa-*`, `fondrunner-*`, `SYNC-CHARTER.md`, `ARCH-SYNC-MEMO.md`, `_LANES.md`) | unrelated Merkle/ledger/journal seal contexts — not the trust_profile PQC seal | none |

No sites found in `v26.10.21/` claiming the old seal state as current.

## Annotation applied

`docs/jira/v26.10.22/receipts/spof3-affidavit-fixes.md` — appended after the
observation, no original text altered:

> **[AS-OF 2026-10-21, BK-85]** This observation is historical, superseded by
> `receipts/bk85-seal-invariant.md` + KD-164: the root cause was a CALLER bug
> (delta bytes never written to the guest block), not the blake3 layout leg —
> every seal was refusing for that reason. Fixed; successful seals are now
> witnessed (shim court + KD-164 CLOSED-WITH-EVIDENCE) and the
> `unverified_blake3_host`/`:PQC_NOT_PROVISIONED` fallback no longer fires.

## Verification

```
just docs-dod-check    # exit 0 — 62 OK, 0 MISS
```

Not committed (per task).
