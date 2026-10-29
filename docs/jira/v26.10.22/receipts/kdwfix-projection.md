# Receipt — KD-WFIX window projection-lag repair

Standing: ALIVE
Context: solo
Date: 2026-10-22
Lane: KD-WFIX

Closed both KD-MIR2 window projection-lag findings by editing ONLY the
v26.10.22 window pointer prose
(`docs/jira/v26.10.22/KNOWN_DIVERGENCES.md`). Canonical register, lib/, and
test/ untouched. Both registers re-read fresh at edit time — KD-ATON
(KD-179) and KD-N1 (KD-178) window rows were already present, so no
collision with the concurrent registrar lanes.

Disclosure: the coordinator tick checkpoint 477d88c5 landed this lane's
window-doc and receipt edits to HEAD as in-flight snapshots (KD-WFIX named
in the checkpoint message); this lane's own commit therefore carries only
this disclosure correction — content at HEAD is byte-identical to what this
lane verified (gates below ran against this exact content pre-checkpoint).

## 1. KD-173 window status refresh (KD-MIR2 finding 2)

BEFORE (window, KD-173 section):
`Status: OPEN (registered). Disposition: owner = BK-BFFSEC follow-up lane; ...`

AFTER:
`Status: CLOSED-SIMULATED (shim landed, witness receipt at receipts/kd173c-devplane-close.md; window refresh KD-WFIX 2026-10-22 — canonical is ground truth, prior window text was stale OPEN).`
Stale Disposition/next-action prose removed; evidence line now cites both
`receipts/bkbffsec-census.md` and the witness receipt.

Grounded on disk before the edit:
- `docs/jira/v26.10.22/receipts/kd173c-devplane-close.md` exists (ALIVE,
  Context: solo; ws-court leg-5 court PASS=73 FAIL=0 SKIP=2, two runs).
- Shim verified: `// KD-COVERS: KD-173` at `workspace/lib/debug-faces.ts:28`
  (route.ts is the KD-COVERS reference site named in the old prose; the
  landed token lives in debug-faces.ts, matching the canonical row's
  CLOSED-SIMULATED face).
- kd_flip covers-map independently reports
  `KD-173: [CLOSED-SIMULATED] workspace/lib/debug-faces.ts`.

## 2. KD-177 window row added (KD-MIR2 finding 1)

Appended the full `- KD-177 —` section at the end of the window doc
(canonical had it, window did not). Content mirrors canonical row 357:
loopback-unwitnessable hardware-anchored trust CLASS row; members (a)
KD-168 MAA TEE quote, (b) KD-167 MHSM leg, (c) KD-106 SKR/MAA minting face;
census receipt `receipts/kd177-envclass.md` (verified on disk); per-member
close conditions row-authoritative; class DO-NOT-FLIP per KD-168 hold
precedent; Status OPEN — TYPED ENVIRONMENT-GATED DISPOSITION. Window row
explicitly notes it was added by KD-WFIX mirroring canonical row 357.

Window `- KD-` section count: 10 -> 11 (now 169,170,171,172,173,174,175,
176,177,178,179 — parity with canonical rows KD-170..179).

## 3. Pointer check

`Mint from KD-180 (highest minted id is KD-179 ...)` — still correct on
fresh read: highest canonical row id is KD-179
(`grep -oE "^\| KD-[0-9]+" docs/jira/v26.10.14/KNOWN_DIVERGENCES.md | sort -V | tail -1`
-> `| KD-179`), next free id KD-180. No new canonical rows landed mid-lane.
Line left unchanged.

## 4. Gates (real output)

```
$ python3 scripts/kd_flip.py            # read-only
...
FLIP-ELIGIBLE: 0
FLIP-PENDING-WITNESS: 1
  KD-168: registrar hold — cross-id evidence matches are refused
exit=0

$ python3 scripts/kd_receipt_fence.py
kd-receipt-fence: checked 329 receipt cites across 6 registers + 2 pattern docs -> OK
exit=0

$ just docs-dod-check
OK    docs/jira/v26.10.17/RECEIPTS.md
OK    README.md
kd-receipt-fence: checked 329 receipt cites across 6 registers + 2 pattern docs -> OK
exit=0
```

No spurious eligibility: FLIP-ELIGIBLE 0, KD-168 DO-NOT-FLIP hold intact.

## 5. Verdict

Standing ALIVE: both KD-MIR2 window findings closed, window now in
status-parity with canonical for all KD-169..179 rows, mint pointer verified
correct. Falsifier (from KD-MIR2): a `- KD-` section count below canonical
row count or a window status disagreeing with canonical — both now fail to
reproduce (11 sections = 11 canonical rows KD-169..179; KD-173 window
CLOSED-SIMULATED = canonical). No lib/, test/, or canonical-register edits;
only the window pointer doc + this receipt are committed.
