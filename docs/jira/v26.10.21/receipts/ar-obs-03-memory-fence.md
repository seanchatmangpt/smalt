# AR-OBS-03 — tprof memory-ceiling fence landed (v26.10.21)

**Standing:** **PARTIAL_ALIVE → fence LANDED, gate+court PASS** (cell can rise to
ALIVE once the AR-OBS-03 row's remaining scope — if any — is adjudicated by
the registrar).
Context: solo
Machine: Apple M3 Max / OTP 28.3.1 / Elixir 1.19.5 (same as VAL-OBS baseline)

## Artifacts

- `scripts/tprof_memory_profile.exs` — one real cosmos put_doc (Smalt.DataPlane
  face, live Smalt.Store ETS, self-booted, ephemeral, no shared substrate),
  profiled via `tprof:profile(fun, #{type => :call_memory, report: :return})`;
  adds `tools-*/ebin` to the code path manually (mix run gap per VAL-OBS API
  notes). Emits one `OBS03` JSON line.
- `scripts/tprof_memory_gate.py` — fail-closed wrapper; parses `alloc_words`,
  compares to `CEILING_WORDS = 200`. Ceiling derivation: VAL-OBS measured
  134 words/txn baseline → 200 = 49% headroom ((200-134)/134 = 0.4925),
  absorbing toolchain churn (OTP minor bumps, Jason internals) while tripping
  on a 2x-class regression (268 words). Exit 0 pass / 1 CEILING BREACH /
  2 environment error. `--seed` re-baselines (measured × 1.5, rewrites the
  constant). `MIX_BUILD_ROOT=_build-obsfence`.
- `justfile.d/44-obsfence.just` + one root-justfile import line —
  `just memory-gate` / `memory-gate-seed` / `memory-gate-court`.
- `scripts/shim_court/tprof_memory_gate_court.sh` — non-vacuity court.

## Green output (gate, real run)

```
$ just memory-gate
[PASS] tprof-memory-gate: 134 words/txn <= ceiling 200 (otp 28, 51 rows)
```

Measured 134 words/txn reproduces the VAL-OBS baseline exactly.

## Shim-flip evidence (non-vacuity, `just memory-gate-court`)

```
[self-check] sha256 restore-detection verified
[SHIM] baseline sha256(.../scripts/tprof_memory_gate.py) = f01726a4b52f...
[PASS] tprof-memory-gate: 134 words/txn <= ceiling 200 (otp 28, 51 rows)   <- BEFORE
[SHIM] shim applied (SHIM-COURT marker present)                            <- ceiling 200->100
[FAIL:CEILING] tprof-memory-gate: 134 words/txn > ceiling 100 (otp 28, top: [...String.replace_leading 22, Jason.Decoder.string 3, Jason.Decoder.array 2])  <- AFTER
[SHIM] AFTER witness passed (new outcome holds under shim)
[SHIM] RESTORE verified byte-exact (sha256 match)
[PASS] tprof_memory_gate_court: non-vacuous (BEFORE old-signature, AFTER new-outcome, restore verified)
```

The same real transaction (134 words) flips PASS→FAIL under the ceiling shim;
restore sha256 byte-exact. The gate can fail — it is not vacuous.

## Court robustness witness (2026-10-21, mid-run)

While concurrent lanes held `lib/smalt/data_plane/file_share.ex` mid-edit
(broken `defguardp int_in/3` guard), the court emitted
`[SKIP] could not query :code.root_dir/0 via mix` and the gate exited 2
(env error) — fail-closed SKIP/env-refusal, never a faked pass. After the
owner lane landed its fix, both gate and court returned full PASS (output
above re-verified; subject sha256 `f01726a4...e348` unchanged throughout).

## Falsifier

A ceiling mutation below the measured baseline that leaves the gate exiting 0
would refute the fence (court guards this). A real regression past 200
words/txn trips the gate in CI.
