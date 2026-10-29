# KD-FLIPFIX — kd_flip --apply selection fence + bold-standing acceptance

Standing: ALIVE
Context: solo
Date: 2026-10-22 · Lane: KD-FLIPFIX · Repo: /Users/sac/smalt

## Defects closed (from KD-166F incident, receipts/kd166-fix-witness.md)

1. `--apply` had no per-id selection: it flipped EVERY row whose witness
   receipt postdated its shim, including environment-gated-UNSUPPORTED
   KD-168 (restored byte-manually twice; any future bare `--apply` would
   re-break it).
2. `shows_pass/2` regex `[Ss]tanding:\s*ALIVE\b` rejected bold markdown
   (`Standing: **ALIVE**`, `**Standing:** ALIVE`) on formatting alone.

## Fix landed (scripts/kd_flip.py)

- `--only KD-nn[,KD-nn...]`: with `--apply`, flips ONLY the named rows
  (all named rows must be FLIP-ELIGIBLE, else REFUSED exit 1). Without
  `--only`, a bare `--apply` auto-applies only when exactly ONE row is
  eligible; with >1 eligible it prints the would-flip list and exits 2
  requiring explicit selection (fail-closed against side-effect flips;
  single-row convenience preserved).
- `shows_pass` standing regex now accepts bold variants:
  `(?:\*\*)?[Ss]tanding(?:\*\*)?:\s*\**\s*ALIVE\b`.
- `KD_FLIP_ROOT` env override so courts point the real tool at a fixture
  tree (no mocks).

## Court (non-vacuity)

`scripts/shim_court/kdflip_gate_court.sh` (wire via `just shim-court kdflip_gate`):

```
[FIXTURE] register fixture built (baseline sha 64b7dd5c65cb...)
[BEFORE] bare --apply exit 2 with would-flip list; register byte-unchanged
[AFTER] --only KD-901: rc=0, exactly KD-901 flipped; KD-902/KD-903 still OPEN
[AFTER] --only KD-903: bold-ALIVE receipt flipped the row (no PASS token in receipt); KD-902 still OPEN
[RESTORE] fixture register restored sha256-exact
[PASS] kdflip gate court non-vacuous (exit-2 fence, exact --only flip, bold-ALIVE acceptance, restore sha-exact)
exit 0
```

Fixture: three OPEN rows (KD-901/902/903), one KD-COVERS shim, three
post-shim receipts; KD-903's receipt is bold-ALIVE with NO literal "PASS"
token anywhere, so only the standing line can qualify it (old regex would
have left it FLIP-PENDING and the flip refused). Restore sha256 byte-exact.
The canonical register is never touched (KD_FLIP_ROOT temp tree).

Self-test also extended (`--self-test`, 10 assertions, exit 0): both bold
standing variants accepted with no plain PASS token; bold non-ALIVE
standing still refused.

## Read-only sweep post-fix (canonical tree, embedded, unedited)

```
FLIP-ELIGIBLE: 0
FLIP-PENDING-WITNESS: 0
WITNESS-AMBIGUOUS: 2 (KD-168, KD-172 — flip refused, disambiguation required)
exit 0
```

KD-168 row re-read on disk post-sweep: status cell still `OPEN — TYPED
DISPOSITION ... environment-gated (hardware-typed-UNSUPPORTED)`. Note: the
pre-existing AMBIGUOUS gate (BK-55) already refused bare --apply for
KD-168/KD-172; the --only selection fence now closes the remaining
multi-eligible flip class and gives explicit per-id control.

## Standing

ALIVE: tool fixes landed, court exit 0, self-test exit 0, canonical
register untouched, KD-168 OPEN verified post-sweep.
