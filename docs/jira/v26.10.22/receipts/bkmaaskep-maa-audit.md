# Receipt: BK-MAASKEP — MAA repair adversarial audit

- **Lane**: BK-MAASKEP (read-only skeptic audit; only this receipt written)
- **Date**: 2026-10-22
- **Subject**: `lib/smalt/attestation/maa.ex` (sha256 `63425bdb08e67ab5596a9e158db9f8da99d19057b1fc803dedd59b68b8e0597f` at probe time), `lib/smalt/sync/store.ex` (heir idiom reference)
- **Standing**: **ALIVE** (was PARTIAL_ALIVE — P5/P6 resolved 2026-10-22 by BK-MAAP6 + BK-MAA2, resolution pointers in the findings sections below; original audit text preserved as-written)
- **Context**: solo

## Status note (in-flight vs landed)

The EXPL8-R lane's receipt `docs/jira/v26.10.22/receipts/expl8r-repairs.md` is **NOT landed**
(absent on disk; maa.ex carried in the v26.10.22 in-flight snapshots per tick checkpoints
70405ff6/ef958eaa). This audit is of the **current tree state** (in-flight EXPL8-R repairs as
present in the working tree).

## Probe harness

Scratch probe `tmp/bkmaaskep_probe.exs` wrapped as a throwaway ExUnit file
(`mix test tmp/bkmaaskep_probe_test.exs`, ephemeral-port self-boot; substrate was holding the
fixed ports so `mix run` was not usable). Real `Smalt.Attestation.Maa.attest/3` calls, real
ETS, real spawned processes. No mocks.

## (1) Repair verification — all four hold

| # | Claim | Probe | Result |
|---|---|---|---|
| 1 | Nonce replay window survives attestor-process death | P1: attest inside a spawned process (Bandit request-process class), creator exits, table still alive via `heir: Process.whereis(:init)` → heir pid `#PID<0.0.0>` alive, replay of the consumed nonce → `nonceReplay` refusal | **PASS** |
| 2 | Hostile policy cannot forge iss/exp | P2: `issue(iss="https://evil.example/")` in params policy → typed `reserved_claim:iss` refusal (parse-time); envelope defaults also win the issue_token merge | **PASS** |
| 3 | Unparseable rules refuse typed (no widening) | P3a: SevSnpVM evidence vs Tpm-only policy → `authorization_denied:type`; P3b: Tpm-only + unparseable rule `c:[type=="Tpm" =! permit();` → 400 typed refusal (bad_rule family), never a widened admit | **PASS** |
| 4 | Failed attest does not burn the nonce | P4: valid quote + mismatching runtime measurement → `invalidmeasurement`; immediate retry with same nonce + corrected runtimeData → token issued | **PASS** |

## (2) New defect classes hunted

### P6 — CONFIRMED: nonce registry is unbounded ETS (no TTL, no sweep) — **RESOLVED (BK-MAAP6 + BK-MAA2)**

> **Resolution (2026-10-22)**: repaired by BK-MAAP6
> (`receipts/bkmaap6-nonce-bounds.md`, standing ALIVE) — three-way bound:
> 256-byte key cap at intake (typed refusal before any ETS write), opportunistic
> TTL sweep (`sweep_expired_nonces/1`, consumed past token TTL / stale pending
> past 300 s), and a 65 536-entry cap evicting the oldest `:consumed` row
> (never `:pending`). Adversarially re-verified by BK-MAA2
> (`receipts/bkmaa2-p5p6-close.md`): 300 distinct attests → 300 rows → sweep
> to 0; oversized nonce refused with the table still absent; stale-pending
> swept / live-pending never evicted. Standing **ALIVE**.

P6: 200 successful attests with distinct nonces → `ets_size_before_after_200: {0, 200}` —
every consumed nonce row persists forever. The table is `:public :set` with `heir: :init`, so
it survives process death AND has no eviction path: monotonic growth for the life of the VM.
On a long-lived substrate this is a slow memory leak keyed by attacker-controlled strings
(nonce is raw client input, arbitrary size — rows can be large too). Repair direction: TTL
sweep (`send_after`-driven `match_delete` on consumed timestamps older than the token TTL,
SCHEDULING-class) or LRU cap. Not blocking the repair verdicts above; a real leak row for the
KD register.

### P5 — no double-issue under concurrency (pass, with a latent window documented) — **RESOLVED (BK-MAAP6 + BK-MAA2)**

> **Resolution (2026-10-22)**: the latent window (release_nonce keyed on nonce
> only) was repaired by BK-MAAP6 (`receipts/bkmaap6-nonce-bounds.md`): rows are
> owner-ref'd `{nonce, owner_pid, state, ts}` and `release_nonce/1` deletes
> only the caller's own `:pending` row. Adversarially re-verified by BK-MAA2
> (`receipts/bkmaa2-p5p6-close.md`): self-release works (failed attest releases
> its own reservation, nonce re-usable), foreign/refused process cannot delete
> a live owner's pending reservation, consumed row survives the owner's own
> retry, and 100-way concurrent attests over 20 nonces → exactly 20 issues
> (1 burn per nonce). Standing **ALIVE**.
>
> One new defect found during re-verification (F1, fixed by BK-MAA2): the
> BK-MAAP6 `release_nonce/1` was an unguarded `:ets.match_delete` — on a fresh
> VM an oversized nonce is refused BEFORE the nonce table exists, so the
> attest/3 else-path release crashed with ArgumentError instead of the typed
> refusal (witnessed). BK-MAA2 added the `:ets.whereis` guard (idempotent
> no-op on a closed table, same idiom as `sweep_expired_nonces/1`); the
> oversized-nonce-typed-refusal leg now passes with the table absent.

50 concurrent attests sharing one nonce: 1 ok / 49 `nonceReplay`, ETS size 1 (single burn).
No double-issue reproduced. Latent window noted for the register, not a witnessed defect:
`release_nonce/1` does `:ets.match_delete(@nonce_table, {nonce, :pending})` keyed on the nonce
only — a process refused as `nonceReplay` while another process's reservation is still
`:pending` would delete the *other* process's reservation, letting a third attempt re-reserve
the same nonce before the winner flips it to consumed. The flip window (insert_new →
`issue_token`'s `:ets.insert` consumed) is microseconds wide; 50-way concurrency did not hit
it. The row ownership is not tracked (no owner-ref in the row), so the release cannot
distinguish self vs foreign reservation.

### Heir idiom correctness (SPOF-B pattern, sync/store.ex:110-123)

Same 3-tuple idiom (`heir = Process.whereis(:init) || self()`, `heir: heir` in
`:ets.new` opts), same rescue-ArgumentError on the create race. Matches the sync/store.ex
shadow-table law; probe P1 witnesses the transfer end-to-end. One idiom divergence: maa.ex
checks `:ets.whereis(@nonce_table) == :undefined` while store.ex checks
`:ets.info(@table) == :undefined` — equivalent for this purpose.

## (3) Fresh court runs (this session, this tree)

- `mix test test/internal/az2_maa_attestation_court_test.exs test/internal/expl8r_court_test.exs` — **18 passed, 0 failed**
  (exact command: `mix test test/internal/az2_maa_attestation_court_test.exs test/internal/expl8r_court_test.exs`)
- `bash scripts/shim_court/az2_maa_court.sh` — **PASS, non-vacuous**: baseline sha256
  `63425bdb…597f`; BEFORE witness (shimmed MAA ATTESTS tampered measurement — flip witnessed);
  AFTER witness (landed refuses); RESTORE byte-exact.
- `mix test test/internal/expl3_dataplane_repairs_court_test.exs test/internal/az4_mhsm_release_policy_court_test.exs test/internal/expl5r1_court_test.exs` — **24 passed, 0 failed**

## Verdict

All four EXPL-8 repair claims are ALIVE on the current tree (in-flight, EXPL8-R receipt not
yet landed). Standing PARTIAL_ALIVE: P6 (unbounded nonce-ETS growth) is a confirmed leak on
the repaired surface and should get a KD/register row when EXPL8-R lands.

> **Update (2026-10-22, BK-MAA2)**: P5/P6 both RESOLVED — see the resolution
> pointers in the findings sections. Full MAA-related suite fresh on the
> resolved tree: `mix test test/internal/az2_maa_attestation_court_test.exs
> test/internal/bkmaap6_nonce_bounds_court_test.exs test/internal/expl8r_court_test.exs
> test/internal/expl3_dataplane_repairs_court_test.exs test/internal/az4_mhsm_release_policy_court_test.exs
> test/internal/expl5r1_court_test.exs` — **47 passed, 0 failed**; az2_maa shim
> court non-vacuous over the resolved subject (baseline sha256
> `7455f8cd…70e0`, restore byte-exact).
