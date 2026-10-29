# BK-SUPW — cosmetic closures (W32-10 supersede + KD skip-banner retype)

**Standing:** **ALIVE** · **Context:** solo · Date: 2026-10-22 · Lane: BK-SUPW

Two cosmetic closures; no `lib/` edits, no substrate interaction.

## 1. W32-10 supersede note in the w32 receipt

`docs/jira/v26.10.20/receipts/w32-api-conformance.md` carried "W32-10 STILL OPEN"
(RE-WITNESS addendum) and "W32-10 remains a live candidate", both stale against
`docs/jira/v26.10.22/receipts/bkw3210-ns202.md` (CLOSED-NOT-A-DIVERGENCE — the 202
carries the full Azure-AsyncOperation LRO face, real-Azure parity; no KD id minted).
Landed a content-preserving SUPERSEDE addendum at the end of the receipt; the original
evidence and addenda are untouched. All 12 W32 candidates are now closed/obsolete.

```diff
--- a/docs/jira/v26.10.20/receipts/w32-api-conformance.md
+++ b/docs/jira/v26.10.20/receipts/w32-api-conformance.md
@@ (tail)
-OBSOLETE (divergences closed); W32-10 remains a live candidate.
+OBSOLETE (divergences closed); W32-10 remains a live candidate.
+
+## SUPERSEDE addendum — 2026-10-22 (lane BK-SUPW): W32-10 CLOSED-NOT-A-DIVERGENCE
+
+W32-10 (SB namespace PUT 202) is **CLOSED-NOT-A-DIVERGENCE** — the 202 carries the
+full Azure-AsyncOperation LRO face, real-Azure parity; no KD id was minted.
+See `docs/jira/v26.10.22/receipts/bkw3210-ns202.md`. All 12 candidates in this
+receipt are now closed/obsolete; "W32-10 STILL OPEN" and "live candidate" above
+are superseded as of this addendum.
```

## 2. SKIP-KD49 banner retype (smalt-cli)

Grep result: no `SKIP-KD18` banner exists anywhere in the tree (KD-18 closed
CLOSED-with-receipt via `docs/jira/v26.10.14/receipts/s2-eh-shims.md`; the old
KD-18 banner was already retired by a prior lane). The `SKIP-KD49` banners in
`smalt-cli/tests/test_servicebus.py` and `smalt-cli/tests/test_eventhub.py` already
cited the closed rows but misattributed KD-49's status: they said "KD-49
CLOSED-SIMULATED" while the register (`docs/jira/v26.10.14/KNOWN_DIVERGENCES.md`
KD-49 row) records **CLOSED-with-receipt** via `receipts/s1-amqp-shims.md`
(court NON-VACUOUS 2026-10-15, real send/receive/complete roundtrip — native, not
simulated). KD-77 remains CLOSED-SIMULATED via
`docs/jira/v26.10.16/receipts/lane9-reference-rewrite.md` (unchanged). Retyped the
header line and witness clause in both files; skip tripwire semantics untouched.

```diff
--- a/smalt-cli/tests/test_servicebus.py (same diff in test_eventhub.py)
-    "SKIP-KD49(KD-49 CLOSED-SIMULATED, KD-77 CLOSED-SIMULATED): both rows "
+    "SKIP-KD49(KD-49 CLOSED-with-receipt, KD-77 CLOSED-SIMULATED): both rows "
 ...
-    "shim landed in lib/ (witness receipts/s1-amqp-shims.md), and the "
+    "shim landed in lib/, witness receipts/s1-amqp-shims.md (court "
+    "NON-VACUOUS 2026-10-15, real send/receive/complete roundtrip), and the "
     ...
-    "'UUID' has no len()\") also closed CLOSED-SIMULATED "
+    "'UUID' has no len()\") closed CLOSED-SIMULATED "
```

Verification: `python3 -m py_compile` on both files → OK; grep on disk confirms the
retyped lines landed in both files. `__pycache__` produced by the compile was removed.

## Standing

ALIVE — both closures on disk, register-consistent, content-preserving.
