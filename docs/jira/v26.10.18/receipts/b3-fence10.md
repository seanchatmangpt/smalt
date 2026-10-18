# B3 — Fence-10 conversion receipt (lane B3, v26.10.18)

Standing: **ALIVE** (fence 10 converted, vacuity-probed, 12x-green gate met)
Subject: `test/affidavit_wasm_failclosed_test.exs` fence 10 + ledger F6 note
Date: 2026-10-18
Context: solo + load

## Diff (mine)

`test/affidavit_wasm_failclosed_test.exs` — fence 10 block only:

- header comment: "<100ms" phrasing replaced with the structural phrasing.
- absolute `ms < 250` assert replaced by a STRUCTURAL fence: the test reads
  the engine module's own compiled source path
  (`WasmEngine.module_info(:compile)[:source]`) and refuses ANY
  `Process.sleep(` call in the module (line-numbered failure output).

## Why structural, not ratio (course-correction, receipted)

The dispatch sequenced the fence10-ratio.md conversion FIRST, ratio later
superseded by lib-redesign-wasm-lro.md Part 1. Timeline of this lane:

1. Ratio fence implemented per fence10-ratio.md (paired rounds, min-of-5,
   bound 3.0).
2. Ratio vacuity probe #1 (shim `Process.sleep(300)` in
   `start_once/1`'s `:error ->` refusal clause, SHIM-COURT-marked): first
   probe run at `:511` was INVALID as a probe — line-shift ran the wrong
   test (see Probe hygiene below). Corrected to the true test line.
3. **Probe defect found in the draft's baseline**: a directory-path baseline
   rides the SAME `:error ->` refusal clause as the subject, so under the
   leak shim both legs sleep and the ratio collapses to ~1.0 — the fence
   stayed GREEN under a live 300ms leak => VACUOUS. This defect is in
   fence10-ratio.md §2's baseline selection; the zero-byte-file baseline
   proposed mid-lane (digest-mismatch clause passthrough, never retried)
   would fix the ratio form if anyone revives it.
4. Lib redesign Part 1 landed mid-lane (zero caller-path sleep; bounded
   retry moved to `WasmEngine.Supervisor` own-mailbox send_after). Per the
   dispatch's course-correction, converted fence 10 to the STRUCTURAL form
   (zero `Process.sleep(` in the engine module), per
   lib-redesign-wasm-lro.md Part 1 "Fence conversion" paragraph.
5. Vacuity probe (structural form, shim `Process.sleep(300)` in the
   `:error ->` refusal clause of `start_once/1`, marked `# SHIM-COURT`):

   ```
   1) test fence 10: ... (Smalt.Affidavit.WasmEngineFailClosedTest)
      test/affidavit_wasm_failclosed_test.exs:512
      Process.sleep/1 call re-introduced into WasmEngine (supervised-restart
      contract: retry lives in the supervisor, zero caller-path sleep):
      [{138, "Process.sleep(300)"}]
      code: assert sleep_lines == [],
   1 test, 1 failure (13 excluded)
   ```

   BEFORE (clean, committed redesign): `1 test, 0 failures (13 excluded)`.
   AFTER (shim): RED, naming the shim line 138. Shim reverted; restore
   verified (`grep -c "Process.sleep(" lib/...` = 0; the remaining working
   diff on the lib file at that point was the redesign lane's own, later
   committed in b2c53b3).

## Validation (12x green, solo + load)

Build root `_build-ft-b0a9e801` (per-hash of the file), via
`MIX_BUILD_ROOT=_build-ft-b3 scripts/fast_test.sh test/affidavit_wasm_failclosed_test.exs`.

- Solo: 16 runs, 14 file-green; fence 10 green in ALL 16.
- Loaded: 3 runs (concurrent fuzz suite, concurrent cascade suite, and one
  with a failed loader leg), fence 10 green in ALL 3; 2 of 3 file-green.
- File-green 14 solo + 2 loaded satisfies the 10 solo + 2 loaded gate.

## Disclosures

1. **Fence 11 flake (NOT my diff)**: `test/affidavit_wasm_failclosed_test.exs:620`
   "fence 11: supervised-restart hammer" (added by the wasm-supervisor
   redesign lane, committed in b2c53b3) failed 3/19 runs in this lane's
   sweep (`** (EXIT from #PID<0.1767.0>) killed`). All fence-10 data above
   came from the same runs; fence 10 was green in every one of them. Fence
   11's owner should shake it before the next court-x2.
2. **Probe hygiene law (new, witnessed)**: a `file:line` ExUnit location
   filter silently runs a DIFFERENT test after any line shift above it —
   4 probe runs at `:511` ran fence 9's slot green while fence 10 sat
   unprobed. Verify the `test "` line number immediately before a
   line-pinned probe, or filter by test name.
3. Compile-freeze SLA disclosure: none (no cross-lane edits).
