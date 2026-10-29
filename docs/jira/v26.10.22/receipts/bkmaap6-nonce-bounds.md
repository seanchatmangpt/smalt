# Receipt: BK-MAAP6 — MAA nonce-registry bounds (P6 + P5 repair)

- **Lane**: BK-MAAP6
- **Date**: 2026-10-22
- **Subject**: `lib/smalt/attestation/maa.ex` sha256 `e44eb0978d4f96af901dd9e4274166c67a94aea45397bc16ee8fa184018de160`; court `test/internal/bkmaap6_nonce_bounds_court_test.exs`
- **Standing**: **ALIVE**
- **Context**: solo

## Repairs (fixes for the two BK-MAASKEP defects)

### P6 — unbounded nonce-ETS growth → bounded three ways

The `:smalt_maa_nonces` registry is now bounded:

1. **Key-size cap at intake**: a nonce over `Maa.nonce_max_key_bytes/0` (256) is
   refused typed (`invalidparameter`, rule `maa_attestation_refusal`, andon
   leaf) BEFORE any ETS write — attacker-controlled keys can no longer mint
   arbitrarily large rows.
2. **TTL sweep** (`Maa.sweep_expired_nonces/1`): consumed rows older than
   `nonce_ttl_seconds/0` (== token TTL 7200, so a burned nonce outlives every
   token it issued) and stale `:pending` rows past a 300 s pending TTL are
   `select_delete`'d. The sweep runs opportunistically on every attest
   (compute-on-write — no sweeper process, no timer, no `Process.sleep`).
3. **Entry cap** `nonce_max_entries/0` (65 536): at the cap the intake path
   evicts the OLDEST `:consumed` row (full consumed-row scan, min-by-ts;
   `:pending` rows are never evicted — a live reservation is the replay gate).

### P5 — cross-process release window → owner-ref'd reservations

Rows are now `{nonce, owner_pid, state, ts}`. `release_nonce/1` deletes ONLY
`{nonce, self(), :pending, _}` — a nonceReplay-refused process can no longer
delete another live process's in-flight reservation. The success flip uses
`:ets.update_element/3` (state+ts only), preserving the original owner; if the
reservation was swept mid-flight, a fresh consumed row is inserted as fallback.

## Court output (embedded, this session, this tree)

```
$ MIX_BUILD_ROOT=_build-maap6 mix test test/internal/bkmaap6_nonce_bounds_court_test.exs
Result: 5 passed          # 20 consecutive solo runs: 0 failures (flake check)

$ MIX_BUILD_ROOT=_build-maap6 mix test test/internal/az2_maa_attestation_court_test.exs \
    test/internal/expl8r_court_test.exs test/internal/expl3_dataplane_repairs_court_test.exs \
    test/internal/az4_mhsm_release_policy_court_test.exs test/internal/expl5r1_court_test.exs \
    test/internal/bkmaap6_nonce_bounds_court_test.exs
Result: 47 passed         # az2 + expl8r + expl3 + az4 + expl5r1 regressions hold

$ bash scripts/shim_court/az2_maa_court.sh
[SHIM] baseline sha256(lib/smalt/attestation/maa.ex) = e44eb097...de160
[SHIM] BEFORE witness passed (shimmed MAA ATTESTS the tampered measurement — flip witnessed)
[SHIM] AFTER witness passed (landed MAA attests a valid quote)
[SHIM] RESTORE verified byte-exact (sha256 match)
[PASS] az2_maa_court: non-vacuous
```

## Court legs (Chicago: real attest/3, real ETS, real spawned processes; zero mocks, zero sleeps)

1. **P6 TTL**: 220 real attests with distinct nonces (`ts:` injected) →
   exactly 220 rows; replay inside the TTL window still refused; two real
   sweeps past the TTL (real future timestamps, not sleeps) free all 220 →
   table size 0. Second-granularity stamping means one sweep can leave a
   second-boundary straggler cohort — the court asserts the two-sweep total.
2. **P6 key-size cap**: 257-byte nonce → typed `invalidparameter` + chain
   complete andon, table size 0 (no row written); boundary nonce at exactly
   256 bytes attests and burns normally.
3. **P6 entry cap**: table filled to 65 536 with strictly age-ordered consumed
   rows in the real row shape; one more real attest → size stays ≤ cap, the
   probe nonce is present, and the uniquely-oldest row ("1") is the one evicted
   while newer rows survive.
4. **P5 owner-ref**: a live owner process's `:pending` reservation (real row
   shape, real spawned owner) survives a foreign process's nonceReplay-refused
   attest + release; a third process is still gated by it.
5. **P5 concurrency**: 50 concurrent same-nonce attests (real Tasks) → exactly
   1 ok / 49 typed `nonceReplay`, one row, flipped `:consumed` (owner
   preserved) — single burn, no cross-delete.

## Repair-law notes

- No-sleep doctrine: the TTL sweep is compute-on-write (per-attest
  `select_delete`), public `sweep_expired_nonces/1` for courts; zero
  `Process.sleep` anywhere (grep-verified on both files).
- The evict path scans consumed rows only at the hard cap (65 536) — bounded
  cost on a rare path; the per-attest sweep is a single `select_delete` pass.
- ExUnit `Task.async/await` harness used after the hand-rolled
  spawn/monitor/receive loop mis-consumed buffered `:normal` DOWNs (harness
  defect, not a module defect).

## Verdict

P6 and P5 both closed on the current tree; all BK-MAASKEP repair verdicts
(EXPL-8 P1-P4 classes) hold (47/47 regression court). Standing **ALIVE**.
KD/register row for the P6 leak class is left to the KD registrar (register
not in this lane's file lease).
