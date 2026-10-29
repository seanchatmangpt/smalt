# KD-177 — Environment-gated hardware-anchored trust class row (census + mint)

**Standing**: PARTIAL_ALIVE (class row registered; members' typed dispositions unchanged)
**Context**: solo
**Date**: 2026-10-22
**Lane**: KD-177
**Files**: `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` (canonical register, one new row), `docs/jira/v26.10.22/KNOWN_DIVERGENCES.md` (pointer), this receipt

## Task

Census the machine-attestation surfaces whose hardware legs loopback cannot
witness; determine whether KD-168's row already carries the class or a new
row is owed; mint accordingly; run registrar gates.

## Census (embedded output)

Dispatch premise: "DKLS-PRIME work landed v26.10.22 — machine attestation
surfaces loopback cannot witness (grep docs/jira/v26.10.22/receipts/ for
dkls/kldrm/cert-mint attest receipts)."

```
$ grep -rln -iE "dkls|kldrm|cert-mint|certmint" docs/jira/v26.10.22/ docs/reference lib/ scripts/ workspace/ 2>/dev/null
docs/jira/v26.10.22/PRD.md        # sole hit: COURT-CERT-OBS row — TLS cert-mint
                                  # defect fix in the cert court (RSA modulus/
                                  # exponent swap), NOT machine attestation
$ grep -rln -iE "dkls|kldrm" docs/jira docs/ lib/ receipts/ scripts/ workspace/
(no project-source hits; only v26.10.18/burn python vendor matches)
```

**The DKLS-PRIME/KLDRM premise does not verify on disk** — no dkls/kldrm
attest receipts exist in this window. The honest census instead grounds on
the attestation receipts that DO exist and carry loopback-unwitnessable
hardware legs:

```
$ grep -n -iE "UNSUPPORTED|no HSM|SNP/TDX|/dev/sev" docs/jira/v26.10.22/receipts/az2-maa-attestation.md docs/jira/v26.10.22/receipts/az2b-maa-receipt.md docs/jira/v26.10.Typed limits in az4
az2-maa-attestation.md:48:## TEE honesty (typed UNSUPPORTED, with falsifier)
az2-maa-attestation.md:52:UNSUPPORTED — falsifier: such a quote cannot be produced on this machine by
az2-maa-attestation.md:53:construction (no SNP/TDX firmware, no AMD PSP, no TDX module)
az2-maa-attestation.md:106:typed UNSUPPORTED; falsifier = a real VCEK-signed quote cannot be produced
az2b-maa-receipt.md:62:Real SEV-SNP/TDX hardware quote production = UNSUPPORTED on this machine (no
az4-mhsm-policies.md:104:- FIPS-level hardware isolation: **UNSUPPORTED** — no HSM silicon at
az4-mhsm-policies.md:3:  ... **UNSUPPORTED** (FIPS-level hardware isolation — no HSM silicon at
az4-mhsm-policies.md:107:- MAA evidence MINTING on release remains typed-UNSUPPORTED (KD-106 face,
az4b-mhsm-receipt.md:90:- FIPS-level hardware isolation: no HSM silicon at loopback
```

### What landed vs what witnesses could NOT witness

| Surface | Receipts | Claimed | Loopback could NOT witness |
|---|---|---|---|
| MAA attest protocol face (KD-168) | `az2-maa-attestation.md`, `az2b-maa-receipt.md` | protocol-real attest shape, measurement cross-binding, SKR leg, 7/7×2 court + non-vacuous shim court | VCEK/VCEM-signed SEV-SNP/TDX quote production/validation (no SNP/TDX firmware, AMD PSP, TDX module; Darwin arm64, no /dev/sev) |
| MHSM release-policy face (KD-167) | `az4-mhsm-policies.md`, `az4b-mhsm-receipt.md` | policy evaluation on RELEASE, typed 403 violation, 4/4 court | FIPS-level hardware isolation (no HSM silicon; real MHSM pool not provisionable) |
| SKR/MAA evidence minting on release (KD-106 face) | `az4-mhsm-policies.md` (typed limits) | envelope contract face CLOSED-SIMULATED | MAA evidence minting at release time (typed-UNSUPPORTED, unchanged) |

## Verdict: class gap vs KD-168 extension

KD-168's row is the MAA-TEE-quote single-surface member. The class —
hardware-anchored trust that loopback cannot witness — spans three register
members (KD-168, KD-167's hardware-isolation leg, KD-106's minting face)
typed only per-receipt, with no row carrying the shared disposition.
**Minted KD-177** as a registration-only class row in the canonical
register (not a KD-168 cell extension — KD-168 stays the member row with
its DO-NOT-FLIP hold intact).

## Row

KD-177 — Environment-gated hardware-anchored trust surfaces —
loopback-unwitnessable class row. Per-member close conditions remain
row-authoritative; class falsifier: any hardware leg becomes
producible/verifiable on-host → member row flips via its own close
condition, then this row closes registrar-typed. DO-NOT-FLIP as a class
(KD-168 hold precedent). Owner: az2/az4 attestation lanes.

## Gates

```
$ python3 scripts/kd_flip.py            # read-only, PRE-mint
FLIP-ELIGIBLE: 0
FLIP-PENDING-WITNESS: 2
  KD-168: registrar hold — cross-id evidence matches are refused
  KD-174: no post-shim receipt newer than shim mtime (2026-10-22T06:02:17)
$ python3 scripts/kd_flip.py            # read-only, POST-mint
FLIP-ELIGIBLE: 0  (no new spurious eligibility)
```

Post-mint run and docs-dod-check output (verbatim):

```
$ python3 scripts/kd_flip.py 2>/dev/null | tail -5        # POST-mint
FLIP-ELIGIBLE: 0
FLIP-PENDING-WITNESS: 2
  KD-168: registrar hold — cross-id evidence matches are refused
  KD-174: 2 post-shim receipt(s) mention KD-174 but carry no close evidence (mention-only class refused): /Users/sac/smalt/docs/jira/v26.10.22/receipts/bkkfkskep-kafka-audit.md, /Users/sac/smalt/docs/jira/v26.10.22/receipts/kd177-envclass.md
$ just docs-dod-check 2>&1 | tail -2
OK    README.md
kd-receipt-fence: checked 318 receipt cites across 6 registers -> OK
```

Gate notes: no new spurious FLIP-ELIGIBLE (0 pre- and post-mint); KD-168
DO-NOT-FLIP hold intact. The kd_flip mention-only flag on this receipt
(KD-174) is the designed cross-id refusal firing on the verbatim pre-mint
gate output embedded above — not an eligibility claim; same class as the
pre-existing bkkfkskep flag. docs-dod-check exit 0 (318 cites OK, +1 for
this receipt chain).
