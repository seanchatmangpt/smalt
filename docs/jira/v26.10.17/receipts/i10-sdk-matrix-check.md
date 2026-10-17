# i10 — sdk-matrix read-only check

Standing: PASS

Lane I10, lease `test/sdk-smoke/`, `scripts/sdk_coverage.py` consumers.
Read-only check — no substrate booted, no ports touched, no git.

## Command + exit

```
$ just sdk-matrix
python3 scripts/sdk_coverage.py
...
GATE: OK — every cell pass / registered / sim-pass / missing-registered
EXIT=0
```

Two windows rendered (windows = `docs/jira/v*/KNOWN_DIVERGENCES.md`):
v26.10.14 and v26.10.16. Both `GATE: OK`, exit 0, zero findings lines
(`grep -i finding` over output: no matches). No substrate boot needed —
`scripts/sdk_coverage.py` is filesystem + census-receipt based.

## v26.10.14 window (real output)

```
divergence register: 94 KD rows loaded
appconfig        ground=ok  TS=PASS  PY=PASS
cells PASS: 6
MISSING=0 UNREGISTERED-GAP=0 REGISTERED-DIVERGENCE=10 SIM-PASS=0 CLOSED-RECEIPT=8
```

## v26.10.16 window (real output)

```
divergence register: 94 KD rows loaded
appconfig        ground=ok  TS=PASS  PY=PASS
servicebus       census CRC: registered=11 registered_total=14 +3 (test/sdk-smoke/sb-extra.probe.cjs) receipt_claim=11 header=11 -> OK
cells PASS: 14
MISSING=0 UNREGISTERED-GAP=0 REGISTERED-DIVERGENCE=5 SIM-PASS=0 CLOSED-RECEIPT=5
kd-annotation cells: SIM-PASS=5 REGISTERED-DIVERGENCE=2 MISSING=0
  kd-cell servicebus/ts: SIM-PASS (KD-45 CLOSED-SIMULATED)
  kd-cell eventhubs/ts: SIM-PASS (KD-53, KD-76 CLOSED-SIMULATED)
  kd-cell eventhubs/py: SIM-PASS (KD-70, KD-71 CLOSED-SIMULATED)
  kd-cell servicebus/py: SIM-PASS (KD-77 CLOSED-SIMULATED)
  kd-cell arm/ts: SIM-PASS (KD-91 CLOSED-SIMULATED)
  kd-cell blob/ts: REGISTERED-DIVERGENCE (KD-92 OPEN)
  kd-cell cosmos/ts: REGISTERED-DIVERGENCE (KD-93 OPEN)
capability cells: PASS=4 PASS-PARTIAL=3 UNREGISTERED-GAP=0 MISSING=0
GATE: OK
```

## Appconfig row + KD cells

- appconfig row renders in BOTH windows: `ground=ok TS=PASS PY=PASS`.
- KD annotation cells render (5 SIM-PASS + 2 OPEN REGISTERED-DIVERGENCE
  in the v26.10.16 window); capability cells render (4 PASS + 3
  PASS-PARTIAL).

## Deferral note (required by task)

`sdk-matrix-md` regen (rewriting `docs/jira/v*/SDK_MATRIX.md`) is deferred
to the WO-5 fin-sweep at final SHA: it needs
`docs/jira/v26.10.17/KNOWN_DIVERGENCES.md` to exist (coordinator
`kd_flip --apply` / register landing). As of this receipt that file does
not exist, so `discover_windows()` renders only v26.10.14 and v26.10.16 —
the v26.10.17 window cannot render yet. This check confirms the gate is
green on the existing windows and leaves the .md regen to the fin-sweep.
