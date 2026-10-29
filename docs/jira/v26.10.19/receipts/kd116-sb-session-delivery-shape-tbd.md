# Receipt — KD-116 SB session deliveries lack settle methods

Standing: **UNKNOWN** (evidence skeleton, TBD; witnessed divergence, no fix)
Context: full
Lane: kd-registrar; no lib/ edits.

## Divergence

Session deliveries arrive and arrive in FIFO order, but the AMQP delivery
frames carry no settle methods — `complete`/`abandon`/`deadLetter` are
unavailable on received session messages, so the receiver cannot settle.

## Witnessed evidence (verbatim from the wf receipt)

`docs/jira/v26.10.19/sdk-results/wf3-ts-messaging-eventing.md`
(SUBJECT_SHA b847c020ee6b0a7ef426e27379f960228932feb0, 2026-10-19):

```
[GREEN] sb-session-fifo — received=[0,1,2,3,4] (deliveries lack settle
methods — delivery-shape divergence)
```

The cell is GREEN only because the probe degrades to receive-only; the
delivery shape diverges from real Azure where every delivery is settleable.
Sibling face of KD-115 (same receiver-dispatch engine).

## Close condition / falsifier

Session deliveries carry settle methods. Falsifier: session probe
receive → complete (settle resolves, message gone) → second receive empty.

---

## SUPERSEDED-BY addendum (2026-10-22, lane BK-SUSP3)

The UNKNOWN skeleton above is superseded: KD-116 was flipped
CLOSED-WITH-RECEIPT in the canonical register (2026-10-21) — the divergence
premise was v6-API rot (settlement works via `receiver.completeMessage`).

SUPERSEDED-BY: `docs/jira/v26.10.20/receipts/kd115-116-diagnosis.md` §4
(PASS kd116-session-settle: settled 3/3, re-receive 0 — exit-captured probe
`verification/ts/kd115.probe.cjs` receiver.completeMessage leg) + canonical
register row `docs/jira/v26.10.19/KNOWN_DIVERGENCES.md:33`
(CLOSED-WITH-RECEIPT, registrar, 2026-10-21). Original witness text untouched.

On-disk successor verification (this addendum, real):

```
$ grep -c "PASS kd116-session-settle" docs/jira/v26.10.20/receipts/kd115-116-diagnosis.md -> 2, exit=0
$ grep -c "KD-116.*CLOSED-WITH-RECEIPT" docs/jira/v26.10.19/KNOWN_DIVERGENCES.md -> 1, exit=0
```
