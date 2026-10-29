# BK-STAND3 — prose-only standing-less receipt resolution (13 witness-window rows)

**Standing:** PARTIAL_ALIVE — all 12 prose-only residue receipts given canonical `**Standing:**` lines derived only from each receipt's embedded evidence, content-preserving, zero fabrication; witness-window NO-STANDING 12 real rows → 0.

Context: solo

## Method

Same contract as BK-STAND2: canonical line from `scripts/receipt_index.py`'s one parser contract (BK-WPARSE), value drawn ONLY from embedded output/verdict prose already in each receipt. Six receipts had a `## Standing` section the parser could not parse (label mismatch or missing canonical form) — canonicalized in place; seven had none — appended. Evidence bodies untouched everywhere.

## Per-row derivation (embedded)

| receipt | was | now | derivation (from embedded evidence only) |
|---|---|---|---|
| v26.10.20/amqp-kd131-133-triage.md | none (label `Standing (lane)` + per-KD bullets unparseable) | ALIVE | receipt's own bullets: KD-132/133 "ALIVE-witnessed as FIXED on current code"; KD-131 ROOT-CAUSED, open pending shared-plane wire witness |
| v26.10.20/azure-emulators-deep-research.md | none (raw JSON dump) | PARTIAL_ALIVE | embedded log: "Verify done: 25 claims → 23 confirmed, 2 refuted, 0 unverified"; research artifact, no code landed |
| v26.10.20/kd69-epoch-falsifier-witness.md | none | ALIVE | Verdict section: "Falsifier FIRED on face 2" — defect witnessed live on the wire, verbatim output embedded (rg404/kdim-ifmatch precedent: witnessed refutation → ALIVE) |
| v26.10.20/migrate-enterprise-fixture.md | plain `ALIVE —` under `## Standing` | ALIVE | same evidence, canonical form: 43 pytest green + live verify PASS embedded |
| v26.10.20/powl2-wave-skeptic.md | none | ALIVE | HIGH-1 non-separable-admission refutation witnessed by executed read-only probe, embedded verbatim; remaining lanes typed UNWITNESSED inside the audited wave |
| v26.10.20/powl3-projection.md | plain `ALIVE (8/8 tests green…` | ALIVE | same evidence, canonical form: 8 tests 0 failures embedded, falsifier named |
| v26.10.20/scvd-backpressure-audit.md | `NEEDS REMEDIATION` under `## Standing (original…)` | PARTIAL_ALIVE | original audit NEEDS REMEDIATION (2 HIGH) + 2026-10-22 addendum witnesses HIGH-1/2, MED-3 REMEDIATED on tree (grep exits embedded); MED-4 observed, not re-audited |
| v26.10.20/sleepfix-gate-closure-20261021.md | `**PASS**` (no label) | PASS | gate outputs embedded: `just sleep-gate` PASS 416 files 0 unclassified; court 12/12 shim courts PASS |
| v26.10.20/smalt-migrate-wave1-audit.md | none | PARTIAL_ALIVE | all five lane suites green with embedded pytest output (37 passed; verify 6/1 loud typed skip); 5 non-blocking findings open to owners |
| v26.10.20/w6p-table-storage.md | none (post-close note + addendum) | ALIVE | addendum's on-disk verification embedded (ls + grep exit 0; literal-`tables` prefix confirmed); audited fix SUPERSEDED-BY w6bk/w6o |
| v26.10.20/ws-court-sweep-20261021.md | `**ALIVE**` (no label) | ALIVE | recovery addendum embedded: ws-lint/ws-build/ws-court all exit 0, court PASS=52 FAIL=0 SKIP=2; supersedes the pre-recovery SUSPECT |
| v26.10.22/bk7b-warnings-sweep.md | plain `PARTIAL_ALIVE —` | PARTIAL_ALIVE | same evidence, canonical form: lane files warning-free; full-repo strict compile exits 1 on in-flight/deps outside authority |

Note on counts: the raw `grep -c 'WITNESS-FAIL.*NO-STANDING'` figure of 13 (and BK-STAND2's "13 residue") includes one false match — the `bkwparse-hardening` dry-run probe line's own command text contains the pattern. Real residue rows: 12 (11 in v26.10.20, 1 in v26.10.22), all resolved above.

## Gates (embedded)

```
$ python3 scripts/witness_all.py --dry-run
  BEFORE: 13 pattern matches = 12 real NO-STANDING rows + 1 false match
          (the bkwparse-hardening dry-run probe line's own command text)
  AFTER:  0 real failures (only the probe-line false match remains)
$ python3 scripts/receipt_index.py    # rc=0
$ just docs-dod-check                 # rc=0
```

Standing: PARTIAL_ALIVE — the prose-only witness-window residue is zero; no parser widening, no evidence edited, zero fabrication.
