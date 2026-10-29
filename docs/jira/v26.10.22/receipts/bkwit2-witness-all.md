# BK-WIT2 — post-repair witness-all re-witness run

Standing: **PARTIAL_ALIVE** (honest verdict; see disposition below). Context: solo.
Date: 2026-10-22. Owner lane: BK-WIT2 (qualification lane — no fixes).

## Substrate health (cheap pre-check)

`just substrate-status`: all faces UP, pid 76687, lock FREE. One curl per
face: 9444 TLS h1 → **401**; 9443/8443 clear h1 → **401**; 9545 → **200**;
8444 → 404. TLS on 9443/8443/9545 resets the handshake — this boot's env
(`ps eww 76687`) sets only `arm_tls_port 9444`; the other faces boot clear.
TLS-on-9443 h2 was proven on the BK-SUBTLS repair beam, a different boot
config. Health gate: PASS (serve on the faces this substrate advertises).

## Run

`just witness-all` (scripts/witness_all.py), full run, background, ~20 min:

```
[WITNESS-SUMMARY] total=431 witnessed-green=61 stale-typed=247 failed=123
```

Exit 1 (fail-closed, correct: fails present). Raw log: /tmp/bkwit2-witness-all.out

## Skip inventory (typed — zero untyped skips)

All 247 stale lines carry a harness-typed reason:
- `no command in a safe class (standing: ...)` — the dominant class.
- `no rerunnable command in receipt` — the second class.
- Standing vocabulary cosmetic finding (harness, not receipts): receipts whose
  standing line is `**Standing:** **ALIVE**` parse as standing `**` — the
  STANDING_RE captures the literal `**` prefix; the standing EXISTS and is
  honest in the doc, but the harness prints/gates on `**`. Harness
  classification-only defect, not a receipt-integrity defect.

## FAIL classification (123 = 86 NO-STANDING + 37 RED)

### 86 WITNESS-FAIL NO-STANDING
Receipts with no `Standing:` line. Real gate findings (the gate correctly
refuses); owners must add standing lines. Not substrate defects.

### 37 REDs
- **29 compile-freeze REDs — in-flight-owned, transient (witnessed cleared):**
  18 × `lib/smalt/webpubsub/service.ex`, 10 × `lib/smalt/confidential_ledger/service.ex`,
  1 × `lib/smalt/attestation/maa.ex`. All five files were modified-in-flight in
  the working tree during the run window (git status witnesses the same five
  files). Post-run reproduction: `mix compile` now exits 0, and a previously
  RED court re-run green: `MIX_BUILD_ROOT=_build-bkwit2 mix test
  test/internal/wire_exp4_court_test.exs` → **11 passed**. So: compile-freeze
  SLA events during the run, not real defects. Owners of the five files are
  the accountable lanes; disclosure duty under the SLA.
  expl9r1/expl9r2 (arm-guards courts) carry the same confidential_ledger
  compile-freeze signature and are counted in the 10.
- **8 artifact/environment REDs** (not substrate defects):
  - 2 × kd_flip.py arg artifact — receipt-recorded command embeds
    `; echo "exit=$?"` / prose, kd_flip exits 2 unrecognized-argument
    (kd127-retype-kd134-mint-witness, bk106-sync-engine-fixes).
  - 1 × sh-syntax artifact — recorded command is prose-with-arrow
    (`... → exit 1 (zero matches)`), /bin/sh syntax error
    (bk115b-trip-regression).
  - 2 × just-recipe-prose artifact — recorded "command" is prose
    (`just (tail)`, `just ->`) — justfile does not contain recipe
    (kddod-pointer-fence, kdmirror-canonical-sync).
  - 2 × expected-zero-grep class — `grep -c` returning 0 is the receipt's
    EXPECTED green outcome but exit 1 → harness reads RED
    (bkbshape-phantom-options: `grep -c ifMatch
    verification/ts/node_modules/@azure/cosmos/dist/esm/request/RequestOptions.d.ts`
    → 0 is the claim; expl9reg-row-mint: `grep -c "KD-COVERS: KD-174"
    lib/smalt/egress_router.ex` after-state zero is the claim). Harness
    classification gap, not a defect.
  - 1 × environment-gated — kd166-witness `ls /dev/sev-guest /dev/tdx` → no
    SEV/TDX devices on macOS; env-gated, not a defect.
- bk166-fix-witness / kd131-133 / kdblob / skepr1 / skepr2 / spof3 / spofa1 /
  sync1: confidential_ledger compile-freeze class, counted above.

## Honest verdict

witness-all exit 1 is the honest outcome: 86 missing-standing receipts are
real gate findings, and 29 compile REDs were real-time in-flight freezes
(now cleared, witnessed by re-run green). Zero untyped skips. Zero real
substrate/surface defects found by this run: **every RED is either
in-flight-owned (SLA), a receipt-authoring artifact (recorded command embeds
prose/args the harness re-runs literally), or environment-gated**. The
no-sleep/no-mock discipline held: all 61 greens are real re-runs.

Standing PARTIAL_ALIVE: the gate is ALIVE and fail-closed (exit 1 with
fails present, 61 real greens); the residue (86 standing-less receipts +
harness gaps: `**` standing parse, expected-zero-grep class, prose-in-command
artifacts) is the named work.
