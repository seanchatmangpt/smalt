# BK-WPARSE — standing-extraction contract hardening (one canonical form)

**Standing:** PARTIAL_ALIVE — parser hardening witnessed; 8 content-preserving normalizations landed; residual 26 witness-window / 256 repo-wide no-canonical-standing receipts are typed honestly (ad-hoc tokens + prose-only), owner residue.

Context: solo

## Root cause

The standing-format law had forked three ways (`Standing:`, `**Standing:**`, `**Standing:** **ALIVE**`) and TWO parsers each carried a private regex:

- `scripts/witness_all.py` `STANDING_RE` captured the emphasis literally:
  `**Standing:** **ALIVE**` yielded value `* **ALIVE** ...` whose `split()[0]`
  is `*` (the `**` capture defect — 516 receipts repo-wide parsed with a
  star-prefixed value). It also missed bullet- and heading-prefixed field
  lines (`- **Standing:**`, `## Standing:`), typing them NO-STANDING.
- `scripts/receipt_index.py` `EXPLICIT_STANDING` tolerated some bold but had
  the same bullet/heading gaps and echoed the `**` residue in the snippet.

## Fix — ONE canonical contract

`scripts/receipt_index.py` now defines the single contract; `witness_all.py`
imports it (no second regex):

```python
STANDING_LINE_RE = re.compile(
    r"^\s*(?:[-*]\s+|#+\s+)*"                       # optional bullet / heading
    r"(?:\*\*)?\s*standing\s*(?:\*\*)?\s*[:=]\s*"   # label, bold optional, : or =
    r"(.+)$", re.IGNORECASE)
```

plus `strip_emphasis` / `standing_field_value` (emphasis stripped before token
lookup). Accepted shapes: bare, bullet-prefixed, heading-prefixed, bold label,
bold value, `=` separator. NON-vacuity: the field label must literally be
"standing"; the value must carry a STANDING_TOKEN; `Status:`/`Verdict:` prose,
and prose sentences mentioning standing ("standing remains PARTIAL_ALIVE"),
never match. `extract_standing` returns the de-emphasized snippet — no `**`
residue.

## Counts (embedded)

Adversarial self-check (inline, 16 assertions): PASS — 8 variant shapes parse
with the correct first token; 6 non-vacuity probes (prose standing, Status:
field, Verdict:) REFUSED; explicit line outranks generic; bold receipt yields
`tok=ALIVE` with a snippet containing zero `**` residue.

Witness-all dry-run over the two newest windows (v26.10.20 + v26.10.22),
before → after:

```
$ python3 scripts/witness_all.py --dry-run
$ grep -c 'WITNESS-FAIL.*NO-STANDING'   # BEFORE 107  AFTER 27 -> 26 after normalization
$ grep -c 'WITNESS-STALE'               # BEFORE 262  AFTER 318 (reclassified, honest typed line)
$ grep -c 'WITNESS-DRY'                 # BEFORE 108  AFTER 140
$ grep -c 'standing: \*'                # BEFORE 516 repo-wide star-captures -> AFTER 0
```

Repo-wide census (the extractor's definition, all `docs/jira/v*/receipts/*.md`
except INDEX.md): total=1440, NO-STANDING was 488, now 256 (232 reclassified by
the hardened contract; 8 by content-preserving normalization).

## Normalized receipts (content-preserving: line break + canonical label only)

- docs/jira/v26.10.17/receipts/i21-surfaces-postfix.md
- docs/jira/v26.10.18/receipts/b8-doctrine.md
- docs/jira/v26.10.18/receipts/i26-adversarial-joe.md
- docs/jira/v26.10.18/receipts/i28-budget-e2e.md
- docs/jira/v26.10.18/receipts/i29-doctor-dod-gapcensus.md
- docs/jira/v26.10.18/receipts/i29-scratch-sweep.md
- docs/jira/v26.10.18/receipts/i29-sdk-smoke-deps.md
- docs/jira/v26.10.20/receipts/w30t2-integration-sweep.md

(Embedded `Date: … · Standing: X` metadata headers — the field clause moved to
its own canonical `**Standing:**` line; wording unchanged.)

## Typed residue (left standing-less, NO fabrication)

The 26 remaining witness-window NO-STANDING receipts are honest: 13 carry a
genuine `**Standing:**` field with an AD-HOC token outside the canonical
vocabulary (OBSOLETE, UNBUILT-for-static, COMPUTED-FROM-PUBLISHED-RATES,
REPRODUCED-AND-ROOT-CAUSED, SKETCH, UNWITNESSED, N/A, REFUTED-WITNESS,
SUSPECT); 13 carry no field line at all (prose mentions only, e.g.
scvd-backpressure-audit's "Standing superseded: NEEDS REMEDIATION →
REMEDIATED"). Widening the token list to admit ad-hoc tokens would be exactly
the vacuous widening this lane refuses; those rows are owner residue for the
receipt authors. 13 of the residue rows sit in v26.10.20.

## Gates

```
$ python3 scripts/receipt_index.py    # exit 0, all windows regenerated
$ just docs-dod-check                 # exit 0; 61 OK + kd-receipt-fence 325 cites OK
```

Note: regenerated RECEIPTS.md / receipts/INDEX.md across windows are direct
generated outputs of the parser change (deterministic from disk); they include
concurrent lanes' receipts present on disk at regen time.

Standing: PARTIAL_ALIVE — hardening + normalizations witnessed; residue typed.
