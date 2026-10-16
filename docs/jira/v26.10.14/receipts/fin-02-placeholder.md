# fin-02 — doctor_dod gap-token census: placeholder + CLOSED-stamp exclusion

## Finding (baseline, pre-fix)

`just doctor-dod` check 6 reported:

```
WARN  gap register count drift: 10 distinct live GAP tokens vs census 9
INFO  gap register sync: 2 'CLOSED 2026-10-15' stamps; 10 distinct live GAP(...) tokens
```

Diagnosis (evidence, not the brief's framing):

- The literal convention placeholder `GAP(name)` (docs/WIRE_PARITY.md:6) was
  **already** excluded by an existing guard (`scripts/doctor_dod.py`:
  `live_tokens.discard("GAP(name)")`) — it was NOT the source of 10-vs-9.
- The actual 10th token was `GAP(lro-no-failed-path)` (WIRE_PARITY.md:94): it is
  CLOSED-stamped **inline** — `` `GAP(lro-no-failed-path)` CLOSED 2026-10-15,
  arm-gateway-lens-9 `` — but not strikethrough, so the strikethrough-only strip
  (`re.sub(r"~~.*?~~", ...)`) left it in the live set.

## Decision (with evidence)

CLOSED-stamped tokens must NOT count as live, in either retirement form:

1. Strikethrough `~~GAP(x)~~` (e.g. `GAP(blob-error-envelope-json)`,
   `GAP(blob-x-ms-error-code-header-absent)` — both with 06-lane receipts).
2. Inline `CLOSED` stamp after the token (e.g. `GAP(lro-no-failed-path)` —
   closed lens-9, receipt-cited in the same row).

Lane-13 census: 5 CLOSED-with-receipt + 9 typed-UNSUPPORTED, so the check
should count live-OPEN tokens only and WARN only when open-count != 9.

## Change

`scripts/doctor_dod.py`, `check_gap_register()` — after the strikethrough strip
and the `GAP(name)` discard:

```python
live_tokens -= set(re.findall(r"GAP\([a-z0-9\-]+\)(?=` CLOSED)", live_text))
```

(lookahead on the backtick + ` CLOSED` inline retirement stamp; strikethrough
CLOSED tokens were already excluded upstream).

## Witness (post-fix)

`just doctor-dod` tail:

```
INFO  envelope/defect cross-check: all 9 expected gap tokens present
INFO  gap register sync: 2 'CLOSED 2026-10-15' stamps; 9 distinct live GAP(...) tokens in WIRE_PARITY.md (lane-13 census: 5 CLOSED + 9 UNSUPPORTED)

summary: 0 FAIL, 2 WARN (exit 0 unless FAIL fired)
```

Count-drift WARN gone. Remaining 2 WARN are out-of-lane and pre-existing
(orphan substrate lock pid=52775; 1 lane build root, 340.9 MiB, `just lane-clean`).

Standing: DONE — 0 FAIL, drift WARN eliminated at the census law (open-count
== 9), no commit per lane contract.
