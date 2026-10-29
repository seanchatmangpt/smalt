# W24 (kd-registrar) — KD-127 premise-rot re-type + KD-134 mint receipt

**Standing:** ALIVE (register edits verified on disk; kd_flip dry-run exit 0)

Context: solo

## Edits (2026-10-21)

- **KD-127 (canonical v26.10.14 + pointer v26.10.20)**: divergence + evidence
  cells re-typed to the premise-rot finding — K6's probe passed the nonexistent
  option `maxAutoRenewDurationInMs` (real: `maxAutoLockRenewalDurationInMs`);
  SDK silently ignored it, auto-renew ran at the 5-min default (~1s renewals),
  so the witnessed non-redelivery was client-side renewal, not broker failure.
  Residual real gap (credit-holding no-reflow receiver) typed as fixed by the
  KD-COVERS in-pump sweep.
- **Status**: found already flipped to CLOSED-SIMULATED at session start of the
  registrar pass — a concurrent actor ran `scripts/kd_flip.py --apply`
  (commit 05240de) between this lane's first and second register reads. The
  flip is mechanically legal: witness receipt mtime (1792565192,
  kd127-lock-sweep-witness.md) > newest KD-COVERS shim mtime (1792564898,
  lib/smalt/messaging/amqp/connection.ex), receipt verdict PASS
  (SDK deliveryCount 1->2 with receiver attached; rhea legs A/B PASS).
  Status cell left untouched (never hand-edited); this lane typed the
  premise-rot cells only.
- **KD-134 minted** (canonical + pointer): AMQP disposition/deliver_available
  dispatch is per-connection id-indexed into `outbound_deliveries`, so a
  reflow (or the KD-127 sweep re-running deliver_available) on ANY
  credit-holding link can hand a re-availed message to an idle first receiver
  while the requesting receiver starves (W21-B witnessed: fresh rx2 starves,
  idle rx1 takes the transfer). AMQP-legal; diverges from real Service Bus
  requester-delivery. Evidence: kd127-lock-sweep-witness.md ("Second, separate
  finding"). OPEN, receipt-gated.
- Pointer header updated: rows KD-01..KD-134, mint from KD-135; KD-127 mirror
  prose corrected (was "OPEN, flip-pending witness").

## kd_flip dry-run (real output)

```
$ python3 scripts/kd_flip.py ; echo "exit=$?"
exit=0
KD-COVERS covers-map: 81 KD ids from 94 files
FLIP-ELIGIBLE: 0
FLIP-PENDING-WITNESS: 0
```

UNKNOWN KD ids in KD-COVERS tokens: 0 (no UNKNOWN section printed; exit 0).

## Census (re-read from tables, ground truth)

```
$ grep -c "^| KD-" docs/jira/v26.10.14/KNOWN_DIVERGENCES.md docs/jira/v26.10.20/KNOWN_DIVERGENCES.md
docs/jira/v26.10.14/KNOWN_DIVERGENCES.md:132
docs/jira/v26.10.20/KNOWN_DIVERGENCES.md:14
```

Canonical rows KD-01..KD-134 (132 table rows: KD-08..KD-134 contiguous ids,
gaps are historical); pointer rows KD-122..KD-134 (14 rows).
