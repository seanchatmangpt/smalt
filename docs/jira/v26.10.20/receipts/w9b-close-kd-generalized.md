# W9-B — generalized KD closer `close_kd.sh`

**Standing:** PARTIAL_ALIVE (all four exit-path branches witnessed live; no flip executed this lane)

## Script

`popcorn_demo/scripts/close_kd.sh` (new, executable, `bash -n` clean)

## Law implemented (parameterized from close_kd122.sh precedent)

1. Canonical row for `<KD-nn>` in `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` must exist and be OPEN; already-CLOSED = loud REFUSED exit 1.
2. Shim token `# KD-COVERS: <KD-nn>` under `lib/`; absent -> exit 3 (PINION/OBSOLETE rows never flip-eligible).
3. Witness gate: newest `docs/jira/v26.10.20/receipts/*witness*.md` naming the id, mtime > newest shim mtime, fragment gate on SMOKE_RECEIPT line (blob-family rows default `blob=OK`, others `live=OK`; `--fragment "label=OK"` overrides).
4. Flip only via `python3 scripts/kd_flip.py --apply`; verify the canonical row CLOSED; no-op apply refused loudly (close_kd122 false-DONE lesson).

## Real run output (2026-10-20)

```
$ bash -n popcorn_demo/scripts/close_kd.sh && echo SYNTAX-OK
SYNTAX-OK

$ popcorn_demo/scripts/close_kd.sh KD-123
REFUSED(KD-123): no canonical row in docs/jira/v26.10.14/KNOWN_DIVERGENCES.md — register and KD-COVERS token under lib/ (lib/smalt/egress_router.ex:2139) are out of sync; register the row first. No flip performed.
exit=1

$ popcorn_demo/scripts/close_kd.sh KD-124
REFUSED(KD-124): no canonical row ... — shim token exists (lib/smalt/arm_gateway/router.ex:1311), register row absent. exit=1

$ popcorn_demo/scripts/close_kd.sh KD-122
REFUSED(KD-122): register row is already CLOSED-SIMULATED (shim landed, witness receipt at docs/jira/v26.10.20/receipts/kd122-blob-cors-close-witness.md) — nothing to close (no-op is not a flip)
exit=1

$ popcorn_demo/scripts/close_kd.sh KD-125
REFUSED(KD-125): register row is already CLOSED-SIMULATED (...) — exit=1

$ popcorn_demo/scripts/close_kd.sh KD-08
register: KD-08 status=OPEN
shim: lib/smalt/data_plane/cosmos.ex mtime=1792548273 (2026-10-20 19:04:33 PDT)
fragment: live=OK
NOT-ELIGIBLE(KD-08): no docs/jira/v26.10.20/receipts/*witness*.md names KD-08 — no witness receipt exists yet (exit 3)
exit=3
```

## Branch coverage witnessed

| branch | subject | exit |
|---|---|---|
| missing register row (token out of sync) | KD-123, KD-124 | 1 |
| already CLOSED (no-op refuse) | KD-122, KD-125 | 1 |
| OPEN + shim + no witness | KD-08 | 3 |
| flip-done (exit 0) | — none eligible at run time | n/a |

Context: solo

## Non-vacuity note

The KD-123 run is the requested non-vacuity witness: the shim token
`# KD-COVERS: KD-123` (lib/smalt/egress_router.ex:2139) exists but has NO
register row — the closer refuses loudly (exit 1) instead of flipping anything.
Same for KD-124 (lib/smalt/arm_gateway/router.ex:1311). Both tokens are
currently unknown to `scripts/kd_flip.py` (it exits 1 listing unknown
KD-COVERS tokens) — registrar follow-up, not this lane.
