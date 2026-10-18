# Fence-10 rewrite draft: absolute 250ms bound → relative ratio fence

Standing: DRAFT (no test edits — frozen tree; this is the ERRC-Reduce conversion plan)
Subject: `test/affidavit_wasm_failclosed_test.exs` fence 10 (assert at ~line 557)
Date: 2026-10-18

## 1. Residual fence 1 — fuzz atom measurement fence: already dropped (verified)

The atom_count window measurement fence in `test/amqp/fuzz_test.exs` (formerly
line 561, FLAKE_LEDGER row F6) was retired in commit **`885c451`**
("fix(fences): soak-C closure — error-codes regen, shacl sweep timeout, wave receipts")
via the in-place retirement comment now at `test/amqp/fuzz_test.exs:606-613`
("Measurement fence retired (2026-10-18, i22 forensics — mechanism lane 2)").

Replacement proof already in place (no reference gap):

- structural asserts: `map_size(src) == 5001` + every decoded key `is_binary/1`
  (fuzz_test.exs:595-604) — race-free zero-atom-minting proof;
- 50k-key scale fence (fuzz_test.exs:614-650) — same decode path, serial-friendly.

Remaining references are historical receipts/ledger rows only (`FLAKE_LEDGER.md`
F6 row cites the retired line as OPEN-ROTATING with a NOT-REPRODUCIBLE
stand-down; `docs/jira/v26.10.17/receipts/i22-fuzz-atom-fix.md`); no live code
references the removed `atom_count` window assert. Nothing to convert — this
entry documents the drop. Suggested follow-up (out of scope here): mark the F6
ledger row RETIRED-CONVERTED so the census prose count tracks the table.

## 2. Residual fence 2 — fence-10's absolute 250ms bound → ratio conversion

### Current state (affidavit_wasm_failclosed_test.exs:545-558)

```elixir
# bogus-path artifact refusals: typed AND fast (no retry sleep leaked).
# ... 250ms still fences the regression exactly: one leaked sleep => >=250ms => RED.
Enum.each(bogus, fn {i, r, ms} ->
  assert {:error, :engine_unavailable} = r, ...
  assert ms < 250, "artifact refusal #{i} took #{ms}ms — retry sleep leaked onto refusal path"
end)
```

Prior history: the 100ms absolute bound was a PERSISTENT-FLAKE under parallel
scheduler load (clean refusal witnessed at 129ms, court attempt 3); 250ms fixed
the flake by hugging the retry constant (`@start_retry_delay_ms 250`,
`lib/smalt/affidavit/wasm_engine.ex:90`). An absolute bound equal to the leaked
operation's own cost is the weakest possible placement: it fences exactly the
first leaked sleep and nothing above/below, and stays machine- and load-bound.

### Precedent pattern (in-repo, `test/amqp/fuzz_test.exs`)

Two landed relative fences to copy:

- **lens-2 bare-array** (fuzz_test.exs:1489-1514): array-decode vs plain-list
  decode at the SAME item count, same run, **min-of-5**, bound 3.0. Clean
  measured <= 1.3; quadratic mutant 22.9-36.1. "Bound 3.0 sits 2.3x over clean,
  7.6x under mutant."
- **lens-2 map** (fuzz_test.exs:1520-1554, pattern lines 1535-1548): paired
  rounds — each round times subject then baseline **back-to-back** so fleet-load
  jitter hits both legs co-monotonically, `Enum.min` of the per-round ratios.
  Clean ~1.12, probe-then-retry mutant ~1.7, bound 1.4.

Both cite the same law the fence-10 comment already states: fences measure
DURATION RATIO of the suspect path vs an independent clean baseline, not
absolute ms.

### Draft conversion (drop-in replacement for the `Enum.each(bogus, ...)` block)

Keep the typed-error assert verbatim. Replace the absolute ms assert with a
paired-round ratio against an **independent, sleep-free-by-construction
baseline on the same call surface**:

```elixir
# Relative fence (machine- and load-independent, replaces the absolute 250ms
# bound; per the fuzz_test.exs lens-2 ratio precedent). Subject: bogus-path
# start (artifact_path resolves, read_admit refuses). Baseline: start_link with
# NO :path opt — artifact_path/1 fails on a pure pattern match before any I/O
# or retry logic, so the baseline path is sleep-free by construction and can
# never absorb the regression we are fencing. Paired rounds, min-of-5: under
# 10-way parallel load both legs inflate co-monotonically, and the min of the
# per-round ratios sheds scheduler noise (the exact channel that flaked the
# old 100ms absolute bound).
timed = fn f ->
  t0 = System.monotonic_time(:millisecond)
  _ = f.()
  System.monotonic_time(:millisecond) - t0
end

subject_f = fn -> WasmEngine.start_link(path: missing) end
baseline_f = fn -> WasmEngine.start_link(bogus_opt: :x) end

ratio =
  for _ <- 1..5 do
    # interleave subject/baseline inside the same loaded cycle
    s = timed.(subject_f)
    b = timed.(baseline_f)
    s / max(b, 1)
  end
  |> Enum.min()

assert ratio < 3.0,
       "refusal/baseline ratio #{Float.round(ratio, 2)} — retry sleep leaked " <>
         "onto the artifact-refusal path"
```

(If `start_link` rejects unknown opts entirely, make the baseline a
zero-byte-file path or similar always-fast typed refusal — the requirement is
only: same public surface, guaranteed to return before
`start_with_retry/2`'s `Process.sleep`, measured back-to-back with the subject.)

### Regression-math: what the ratio still fences

The fenced failure class is unchanged: **a leaked retry sleep on the artifact-
refusal path**. Mechanism (`lib/smalt/affidavit/wasm_engine.ex:96-105`): the
only sleep on the start path is `Process.sleep(@start_retry_delay_ms)` (250ms)
inside `start_with_retry/2`, entered only when `start_once/1` returns
`{:error, :engine_start_failed}`. If a refactor makes an artifact refusal route
through that clause:

- `Process.sleep/1` never returns early ⇒ subject leg >= 250ms, deterministically.
- The baseline leg is a pure pattern-match failure: single-digit ms unloaded;
  even loaded it inflates by the same co-monotonic scheduler factor as the
  subject's *clean* state, and from a base of ~1-5ms it cannot plausibly reach
  the ~80ms+ needed to mask a leak at bound 3.0 (that would be a 15-80x
  scheduler inflation of a pure function call — not a witnessed regime; the
  worst witnessed clean-refusal inflation was 129ms from single-digit ms on a
  path doing far more work than the baseline).
- Worst-case masking arithmetic: RED requires any subject round / min-baseline
  > 3.0. Leak ⇒ every subject round >= 250ms ⇒ RED unless min-baseline > ~83ms.
  Margin: clean ratio measured expectations ~1-3 (subject does one file stat +
  read + digest check vs the baseline's pure failure), mutant ratio >= 250/b.

So the ratio fence keeps exactly the class the 250ms bound kept ("one leaked
sleep => RED") while removing the load-sensitivity that forced the bound up to
the retry constant in the first place.

### Vacuity probe (required before landing — prove the ratio fence REDs)

Shim-court style, on a SCRATCH COPY (frozen tree — do not edit in place):

1. `cp lib/smalt/affidavit/wasm_engine.ex /tmp/wasm_engine.shim.ex` (or copy the
   whole test file to `test/scratch_fence10_probe.exs`); apply the shim:
   insert `Process.sleep(300)` into the artifact-refusal return path of
   `start_once/1` (marker the edit `# SHIM-COURT`).
2. Run the converted fence against the shimmed subject.
3. Expected BEFORE (clean): ratio ~1-3, GREEN. Expected AFTER (shimmed):
   subject >= 300ms vs baseline single-digit ⇒ ratio >= ~30 >> 3.0 ⇒ RED.
4. A run where the shimmed subject still passes = the fence is vacuous — do
   not land the conversion.

## 3. Receipt block (fill at landing, frozen here)

- conversion diff: test/affidavit_wasm_failclosed_test.exs (fence 10 block only)
- vacuity probe: BEFORE green / AFTER red receipt in docs/jira/v26.10.18/receipts/
- ledger: FLAKE_LEDGER F6 row → RETIRED-CONVERTED (same commit)
