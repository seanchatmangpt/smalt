# KD-168F — KD-168 disposition completion: DO-NOT-FLIP registrar hold (false FLIP-ELIGIBLE suppressed)

Standing: ALIVE
Context: solo
Date: 2026-10-22
Lane: KD-168F

## Finding

KD-168 (MAA hardware-quote cross-binding) is typed environment-gated
hardware-typed-UNSUPPORTED (BK-11 triage,
`docs/jira/v26.10.22/receipts/bk11-kd-legacy-triage.md`): the close condition
requires a real VCEK/VCEM-signed SEV-SNP/TDX quote, which is not producible on
loopback (no /dev/sev, /dev/tdx, /dev/sev-guest on Darwin arm64 — re-confirmed
in `docs/jira/v26.10.22/receipts/kd166-witness.md` §KD-168).

Yet `scripts/kd_flip.py` (read-only) listed KD-168 as **FLIP-ELIGIBLE** with
witness `docs/jira/v26.10.22/receipts/kdp6-row.md`. Root cause: kdp6-row.md is
the KD-176 mint note — its KD-168 mention sits in KD-COVERS explanatory
context ("the BK-MAAP6 repair site carries `# KD-COVERS: KD-168`, not a KD-176
token") within WITNESS_WINDOW of the word "Disposition", it postdates the
maa.ex shim mtime (05:57:14 vs 05:53:15), and it shows a standing ALIVE — so
the picker scored it as the sole qualifying close witness. It is a mint note
about a different row, not a KD-168 close witness. FLIP-ELIGIBLE ≠ close
condition met; a flip here would have been the exact mis-flip class the tool
exists to refuse.

## Action

Registrar-convention edit (no kd_flip.py defect — the tool's DO-NOT-FLIP
registrar-hold mechanism checked first in `witness()` is the designed
suppression for environment-gated rows, and it correctly takes precedence over
both inferred and explicit `--witness` paths):

- `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` KD-168 status cell: appended a
  **DO-NOT-FLIP** registrar hold naming the reason (close condition requires
  TEE silicon unavailable on loopback; kdp6-row.md is KD-176 mint context, not
  a KD-168 close witness; flip refused even under explicit --witness).

No flip performed. The row's typed disposition (falsifier, owner, next-action
"none owed by smalt on loopback") was already complete per BK-11 and
`docs/jira/v26.10.22/receipts/kdskep-register-audit.md`; this lane added only
the suppression marker.

## Gates (embedded output)

1. kd_flip read-only after the edit — KD-168 no longer listed FLIP-ELIGIBLE:

```
$ python3 scripts/kd_flip.py
KD-COVERS covers-map: 121 KD ids from 144 files
  KD-168: [OPEN] lib/smalt/attestation/maa.ex
FLIP-ELIGIBLE: 0
FLIP-PENDING-WITNESS: 1
  KD-168: registrar hold — cross-id evidence matches are refused
```

2. Explicit-witness flip attempt refused (fail-closed, register untouched):

```
$ python3 scripts/kd_flip.py --apply --only KD-168 \
    --witness KD-168=docs/jira/v26.10.22/receipts/kdp6-row.md
  KD-168: registrar hold — cross-id evidence matches are refused
--only REFUSED: requested row(s) not FLIP-ELIGIBLE: KD-168
```

3. kd_flip self-test non-vacuous:

```
$ python3 scripts/kd_flip.py --self-test
KD-FLIP self-test: witness pinning + bold-standing non-vacuous (10 assertions)
```

4. kdflip gate court non-vacuous (exit-2 fence, exact --only flip, bold-ALIVE
   acceptance, sha-exact restore):

```
$ bash scripts/shim_court/kdflip_gate_court.sh
[PASS] kdflip gate court non-vacuous (exit-2 fence, exact --only flip, bold-ALIVE acceptance, restore sha-exact)
```

5. docs-dod:

```
$ just docs-dod-check
OK (61 doc paths) + kd-receipt-fence: checked 317 receipt cites across 6 registers -> OK
exit 0
```

## Standing

ALIVE — KD-168 stays OPEN with typed hardware-typed-UNSUPPORTED disposition,
now held DO-NOT-FLIP; the false FLIP-ELIGIBLE listing is suppressed and an
explicit-witness flip attempt is machine-refused. Re-open path unchanged: a
real VCEK/VCEM-signed TEE quote becomes producible/verifiable on this host and
the cross-binding gate refuses a tampered measurement; a future lane removes
the hold only with that witness.
