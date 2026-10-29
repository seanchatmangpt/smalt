# FONDRUNNER court receipt

**Standing:** **PASS** — court `test/pipeline/fond_powl_runner_court_test.exs` green 7/7 on the
pinned OTP 29 / Elixir 1.20.4-otp-29 toolchain, `MIX_BUILD_ROOT=_build-bk4`.
Context: solo

## Subject

- `lib/smalt/pipeline/smalt_fond_powl_runner.erl` (gen_statem strong-cyclic runner)
- `lib/smalt/pipeline/smalt_fond_plan.erl` (plan/assert spine)
- `lib/smalt/pipeline/smalt_fond_seal.erl` (merkle seal)

Court: `test/pipeline/fond_powl_runner_court_test.exs` (7 tests).

## Command

```bash
export PATH=~/.asdf/installs/erlang/29.1.2/bin:~/.asdf/installs/elixir/1.20.4-otp-29/bin:$PATH
MIX_BUILD_ROOT=_build-bk4 mix test test/pipeline/fond_powl_runner_court_test.exs
```

Exit code: **0**.

## Output tail

```
Finished in 0.3 seconds (0.00s async, 0.3s sync)

Result: 7 passed
EXIT=0
```

## What the court proves

- **(a) Happy path**: `:smalt_fond_powl_runner.run(%{tasks: [:prep, :stage, :commit], max_retries: 10})`
  completes `{:ok, receipt}` with a 32-byte merkle receipt, `event_count = 3 steps + 3 htn_decompose
  + 3 pipeline events`, `step_count = 3`, `otp_release >= 28`.
- **(b) Nondeterministic edge (412 contingency)**: forcing 412 on every step drives the
  strong-cyclic loopback — 11 retries crashes at the bound with typed
  `fond_loop_bound_exhausted` (ledger shows 11 × `fond_412_loopback` events at seq 4..14,
  witnessed in the gen_statem crash report in the run log); a contingent (always-412-then-success)
  contingency mints `fond_412_loopback` events and still completes.
- **(c) Seal determinism**: same ledger → byte-identical merkle across two runs and across a
  fresh-process relaunch sealing the identical ledger map.
- **(d) Adversarial typed refusal**: cyclic plan input crashes at the assert
  (acyclic-spine refusal); the runner refuses unreachable/inconsistent plans at the spine
  assert rather than looping.
- **(e) Toolchain pin**: admits on the pinned toolchain, seals a fixed ledger identically,
  sentinel fingerprint is a pinned integer distinct from the 26.x-era order.

## Falsifier status

Not falsified this run: 7/7 green, exit 0, on-disk receipt at
`docs/jira/v26.10.21/receipts/fondrunner-court.md`.

---

## Skeptic re-audit (BK-115, 2026-10-21)

**Standing:** **PASS** — court extended with 3 skeptic probes
(`describe "skeptic probes (BK-115)"`, tagged `:fondrunner_skeptic`), full court
now **10/10 green, exit 0** on the pinned OTP 29 / Elixir 1.20.4-otp-29 toolchain,
`MIX_BUILD_ROOT=_build-bk115`. Original court section above preserved verbatim.

### Gaps found in the original court (what it did NOT assert)

1. **Loopback-counter liveness**: the court proved exhaustion at the bound but
   never proved the retry counter increments — a runner whose counter stays
   pinned (`retries => R`, never `R + 1`) loops the fond stage forever on any
   unbounded contingency, and no existing probe had a timeout, so a mutation
   would HANG the court instead of failing loudly.
2. **Pinned losing branch**: no probe drove a contingency that fails only a
   MIDDLE step (`:stage`) forever — i.e. no assertion that the global bound
   exhausts naming the correct `stuck_on`, that earlier steps execute exactly
   once, and that the exhaustion retries count is exactly `max_retries + 1`.
3. **Seal determinism under CONCURRENT runners**: court (c) compared sequential
   runs plus spawned sealers of a hand-built ledger; no probe ran N full
   pipelines concurrently and required byte-identical FULL receipts
   (replay idempotency beyond merkle equality: event_count, step_count, plan).

### Probes added (test/pipeline/fond_powl_runner_court_test.exs)

- **S1** finite-flake liveness: 2 loopbacks/step then success lands with exact
  ledger composition (6 loopback + 3 executed + 3 htn + 3 pipeline events).
  Not the counter-mutation falsifier (a finite flake escapes a broken counter);
  pins the bounded-flake escape law.
- **S2** pinned losing branch: `:stage`-only always-412 with `max_retries: 3`
  → `fond_loop_bound_exhausted` with `stuck_on == :stage`,
  `retries == max+1 == 4`; plus a single-step always-412 run at `max_retries: 2`
  → `stuck_on == :solo`, `retries == 3` exactly (global, not per-step, bound).
- **S3** 8 concurrent full pipeline runs → `length(Enum.uniq(receipts)) == 1`
  over FULL receipt maps (replay idempotency, not digest-only).

All probes route through `run_bounded/2` (spawn + monitor + bounded receive),
so a liveness mutation fails as `{:skeptic_timeout, pid}` in ~5s — loud, never
a hang.

### Shim court (non-vacuity of the probe set)

`SHIM-COURT` mutation of `lib/smalt/pipeline/smalt_fond_powl_runner.erl`
loopback/2: `retries => R + 1` → `retries => R` (counter never increments).

```
BASELINE sha256 052a897b555617ce17dc1478605d77345ab9519c9419df8e93471cab934b5afe
BEFORE   unshimmed skeptic probes: PASS (within 10/10 full-court run)
SHIM     perl -pi -e 's/retries => R \+ 1/retries => R/' (loopback admit clause)
AFTER    --only fondrunner_skeptic: 1/3 passed, Failed: 2
         (S2 pinned losing branch: mutated runner never exhausts → run_bounded
          timeout flip; S3 also flipped in that ordering; S1 passes under a
          finite flake, as documented on the probe)
RESTORE  sha256 052a897b555617ce17dc1478605d77345ab9519c9419df8e93471cab934b5afe
         byte-exact, fail-closed verified
```

The court CANNOT pass with a non-incrementing loopback counter: the flip is the
non-vacuity proof.

### Command

```bash
export PATH=~/.asdf/installs/erlang/29.1.2/bin:~/.asdf/installs/elixir/1.20.4-otp-29/bin:$PATH
MIX_BUILD_ROOT=_build-bk115 mix test test/pipeline/fond_powl_runner_court_test.exs
```

Exit code: **0**, `Result: 10 passed`.
