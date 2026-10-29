# Receipt: w6ak — Blob Lease Family Audit (v26.10.20)

- **Lane**: w6ak (close-out w6ak2)
- **Date**: 2026-10-20
- **Standing**: ALIVE (module tier; real Store, real state assertions)
- **Subject**: `lib/smalt/data_plane/blob_storage.ex` @ sha256 `7b4a1b67fda295de…`
- **Context**: solo

## Scope

Adversarial audit of the container LEASE family against real Azure Blob Lease
REST parity. Receipt-only close-out: no code changes this close-out (both fixes
were landed by w6ak proper).

## Defects found + fixed (by w6ak, verified on disk this close-out)

- **D1 — x-ms-lease-break-period ignored**: break on a finite lease answered
  `LeaseTime = raw remaining` where Azure mandates `min(period, remaining)`.
  Fix verified on disk at `blob_storage.ex:2331-2341` (break clause): parses the
  header (0..60s), `LeaseTime = min(p, lease_remaining)`.
- **D2 — acquire duration unbounded**: any n>0 admitted (5s lease → 201);
  Azure requires −1 or 15..60 s. Fix verified on disk at
  `blob_storage.ex:2407-2424` (`lease_duration/1`): −1 → :infinity,
  15..60 → n, else typed 400 `InvalidHeaderValue`.

## Matrix results (real output, re-run this close-out)

Runner: `ERL_LIBS=$PWD/tmp/w6ak_lib elixir -pa tmp/w6ak_ebin -e
'Code.require_file(...)'` (frozen lib copy + fresh BlobStorage beam; no new
build roots; tmp scratch cleaned).

### tmp/w6ak_legs2.exs — D1 decisive legs

```
L4B_BREAK_PERIOD_FINITE PASS (LeaseTime=30=min(30,60), parity)
L4B_RELEASE PASS
L9_BREAK_NOLEASE_ID PASS
L9B_BREAK_NOLEASE_ID PASS
L9C_RENEW_NOLEASE_ID PASS
W6AK LEGS2 COMPLETE
```

### tmp/w6ak_witness.exs — 12-leg matrix (default-immutable seed container)

```
SEED {…, "immutable" => true, "retention_days" => 1095}
L1_ACQUIRE201 PASS (id len 36)
L2_SECOND_ACQUIRE PASS
L3_RENEW_WRONG_ID PASS
L4_BREAK_PERIOD PASS (202, x-ms-lease-time=0; infinite lease -> pinned 0)
L5_RELEASE_WRONG_ID PASS
L6_RELEASE_CORRECT_ID PASS
L7_RENEW_NOLEASE PASS
L8_DURATION_5S PASS (400 InvalidHeaderValue, parity)
L9_BREAK_NOLEASE PASS
L10_UNKNOWN_CONTAINER PASS
L11_DELETE_LEASED {…409 "ContainerLocked" WORM…} — PINNED (see below)
L12_DELETE_WITH_MATCHING_ID {…409 "ContainerLocked" WORM…} — PINNED (see below)
W6AK AUDIT MATRIX COMPLETE
```

### tmp/w6ak_legs4.exs — same lease-gate legs on a NON-immutable container

```
L11N_DELETE_LEASED PASS (409 ContainerLeased, lease gate proven)
L12N_DELETE_WITH_MATCHING_ID PASS (202)
W6AK LEGS4 COMPLETE
```

## Per-leg verdicts

| Leg | Verdict |
|---|---|
| L1 acquire 201 | PASS |
| L2 second acquire 409 LeaseAlreadyPresent | PASS |
| L3 renew wrong id | PASS |
| L4 break infinite → LeaseTime 0 | PINNED (KD-108 class) |
| L4B break finite w/ period 30 → 30 | PASS (D1 proof) |
| L5 release wrong id | PASS |
| L6 release correct id 200 | PASS |
| L7 renew no-lease | PASS |
| L8 duration 5s → 400 InvalidHeaderValue | PASS (D2 proof) |
| L9/L9B/L9C no-lease id discipline | PASS |
| L10 unknown container 404 | PASS |
| L11/L12 delete-container lease gate | PASS via L11N/L12N; main-witness
ContainerLocked is the default-immutable WORM gate answering first — pinned
behavior (observed in the KD-108 receipt) |

## Coverage note

Blob-level non-snapshot `?comp=lease` remains the pinned
`GAP(blob-comp-lease-absent)` in `docs/WIRE_PARITY.md` — unchanged, not minted.

## Falsifier

Green under a broken break-period (LeaseTime ≠ min(period, remaining)) or a
5s-duration 201 would be vacuous. Re-run: `ERL_LIBS=$PWD/tmp/w6ak_lib elixir
-pa tmp/w6ak_ebin -e 'Code.require_file("tmp/w6ak_witness.exs")'` (plus
legs2/legs4).

## Context note

Matrix ran against a container seeded default-immutable (`immutable: true`,
1095-day retention) — the L11/L12 readings there are the pinned WORM gate, not
a lease defect; the legs4 container (non-immutable) isolates the lease gate and
both legs PASS there. Intermediate script `tmp/w6ak_legs3.exs` was superseded
by `legs4` (corrected state ordering) and is retained only for the audit trail.
