# IMPL-21 — post-upgrade real-SDK wire courts on the recycled beam

Context: solo
**Standing:** PASS

- **Date**: 2026-10-21 · **Lane**: IMPL-21 (bench) · **Repo**: /Users/sac/smalt
- **Context**: solo · **Standing**: **PASS** (all five witnesses, 0 errors)
- **Subject**: live substrate pid 85369, OTP **29.1.2**
  (`/Users/sac/.asdf/installs/erlang/29.1.2`), Elixir 1.20.4-otp-29,
  ports 9443/9444/5672/5673 UP, lock FREE — the recycled beam IMPL-20
  delivered. Never restarted in-lane.

## Recycle confirmation (bounded poll)

Bounded poll on the listening pid's beam root: pid 8877 on
`otp-28.3.1` for 8 polls (20s apart), then pid **85369 on
`/Users/sac/.asdf/installs/erlang/29.1.2`** appeared — recycle confirmed
by observation, not assumption. Probe records `substrate_otp` per row.

## Run

Probe: `/Users/sac/smalt/tmp/bench/impl21_sdk_probe.mjs` (authoritative
abbreviated run, 5 witnesses; loud typed SKIP exit 3 if substrate down —
never restarted it). Canonical-shape confirmation rides the unmodified
scvd lane scripts (emitted to their own files; rows copied verbatim into
the lane record marked `record: canonical-shape`).

```
just bench-machine
{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}
```

(the client harness is node v26.10.0; the substrate beam itself is
otp-29.1.2 as recorded per row)

## Parity table (gate: post/pre within 2x, errors=0)

| Witness | Post-upgrade (OTP 29.1.2) | Pre-upgrade baseline (OTP 28.3.1) | Ratio | Verdict |
|---|---|---|---|---|
| T1-shape cosmos put/get (canonical scvd-t1, n=160) | 1366.5 ops/s | 1646.1–2145.9 ops/s (3 baseline runs, tmp/bench/scvd-tier1.jsonl) | 0.64–0.83x | **PASS** |
| T12-shape blob put/get (canonical c128x4, n=512) | 879.7 ops/s | 1193.5 ops/s | 0.74x | **PASS** |
| T12-shape SB send/recv (canonical c128x4, n=1024) | 4511 ops/s | 4214 ops/s | 1.07x | **PASS** |
| KD155SDK deleteQueue (5 rounds create→delete→get-404) | exit 0, errors=0, get-after-delete 404 | pre-upgrade witness exit 0 (kd155-sdk-deletequeue-witness.md, OTP 28) | functional | **PASS** |
| T24 appconfig SDK set/get/CAS-412/delete-404 x50 | 50/50 cells PASS, 98.7 ops/s | baseline wire-parity row: 6-cell PASS (functional) | functional | **PASS** |

Abbreviated-probe rows (in-lane custom probe, different op-counting
conventions than the canonical lanes) all errors=0 and are recorded but
not used for the parity ratios; the first in-lane run also surfaced and
fixed a probe-side cleanup defect (double deleteQueue on an
already-deleted queue crashed the process — probe bug, not substrate).

## Honest notes

- Abbreviated (1-cycle) SB shape is attach-cost-dominated and reads 0.19x
  vs the 4-cycle baseline — recorded as a **shape artifact, not a
  regression**; the shape-matched c128x4 leg is the parity number (1.07x).
- KD155SDK note: `getQueue` on the deleted queue answers 404; the
  SDK-paged `listQueues` error remains a pre-existing, separately
  registered row (unchanged from the pre-upgrade witness).

## Result file

`/Users/sac/smalt/tmp/bench/impl21-postupgrade-sdk.jsonl` — 8 rows
(5 abbreviated-probe + 3 canonical-shape), all verdict PASS, errors=0.
Lane wrote only its own result file; scvd lane files were appended by the
canonical scripts' own runs.
