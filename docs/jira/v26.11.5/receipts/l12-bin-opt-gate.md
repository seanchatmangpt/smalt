# L12r — bin_opt gate + shim court (aq-architecture-spec §4)

Standing: ALIVE

Lane: L12r (retry of L12, died clean). Repo: /Users/sac/smalt. Spec:
`docs/jira/v26.11.5/aq-architecture-spec.md` §4 @ 25dd40df.

## Files (lease: exactly these four paths)

- `scripts/bin_opt_gate.sh` — scoped bin_opt_info warning-class gate
- `scripts/shim_court/bin_opt_court.sh` — non-vacuity shim court
- `justfile.d/62-bin-opt.just` — `just bin-opt` / `just bin-opt-court`
- `justfile` — one import line appended

## Premise-rot finding (measured, load-bearing)

The spec's pinned warning classes are extinct on the pinned toolchain
(Elixir 1.20.4-otp-29 / OTP 29.1.2, asdf). Measured probes
(`/tmp/bintest/probe*.ex|.erl`):

- `no match .* could be optimized` / `optimization .* is not possible` —
  never emitted on OTP 29 for any probe (clean chain, return-of-binary,
  match-on-call-result, `binary:part` mid-chain, size-resize).
- OTP 29 emits instead: `NOT OPTIMIZED: ...`, `BINARY CREATED: ... doesn't
  support context reuse` (FAIL classes), `OPTIMIZED: match context reused`
  (positive), and `BINARY CREATED: binary is [used in a term that is]
  returned from the function` — the last two are BENIGN: the spec-required
  parse shape `def parse(<<t, rest::binary>>), do: {t, rest}` itself emits
  `BINARY CREATED: ... returned from the function`, so gating on all
  BINARY-CREATED would be red on lawful code.
- Gate header pins R1–R4 (spec classes) + F1/F2 (OTP29) + B1/B2 (benign
  vocabulary); unclassified scoped bin_opt diagnostics FAIL CLOSED; scoped
  non-bin_opt compiler warnings are SKIP (other gates' surface).

## Court verdict: FLIPPED (non-vacuous)

`just bin-opt-court` (exit 0):

```
[self-check] sha256 restore-detection verified
[SHIM] baseline sha256(...bin_opt_court_fixture.ex) = eb9041ee1f01cff404167cacca878e0d2f8459bd583af8022e7d05ab2308eb8c
[SHIM] BEFORE witness passed (old signature holds)
[SHIM] shim applied to ... (SHIM-COURT marker present)
[SHIM] AFTER witness passed (new outcome holds under shim)
[SHIM] RESTORE verified byte-exact (sha256 match)
[PASS] bin_opt_court: non-vacuous (BEFORE old-signature, AFTER new-outcome, restore verified)
```

Shim: injected `<<type, rest::binary>> = bin` followed by
`:binary.part(bin, 0, 2)` on the same binary (measured to emit
`BINARY CREATED: ... doesn't support context reuse`) → gate exit 0 → 1.
A gate that accepts the shim exits 1 as VACUOUS GATE; it did not.
No `Process.sleep` anywhere: compile waits are blocking subprocesses.

## Gate verdict on the live AoQ surface

`just bin-opt` (exit 0):

```
SUMMARY scoped_fail=0 scoped_benign=3 scoped_other=29
bin_opt gate: PASS (zero scoped FAIL-class warnings)
```

Gate design: warm `mix compile` into a DEDICATED build root
(`tmp/bin-opt/build`, never shared `_build`; warm failure is a loud WARN,
non-fatal under concurrent-lane mid-compile), then `ERL_COMPILER_OPTIONS=
bin_opt_info elixirc` per scope file (default `lib/smalt/aoq`, overridable
via `BINOPT_SCOPE` — the court uses a scratch fixture scope, so the court
never touches `lib/`), fresh beams dir per run, path-attributed scoped
classification, receipt in `tmp/bin-opt/` (scratch).

## Collision disclosures

1. Lane C1 overwrote `scripts/bin_opt_gate.sh` mid-flight with its own
   version (17:16, "lane C1" header) pinning ONLY the extinct legacy regexes
   and compiling the fixed project surface (`mix compile --force` — a scratch
   shim could never flip it). Restored the L12r implementation; the flip
   witness above is against the L12r gate. C1's regex set is provably
   vacuous on OTP 29 (premise rot, measured above).
2. Coordinator `wip` commits swept the lease files
   (8519f40a, 7ca1f67a, 16d60a77); on-disk content == committed, clean.
3. Concurrent lanes' in-flight `lib/smalt/aoq/*` (worker.ex compile error,
   listener.ex missing Plug alias) were observed mid-wave; the gate's warm
   phase degrades to WARN under such breakage and the scope compile still
   fails loud (`[FAIL:COMPILE]`), which was witnessed during the wave.

## Environment notes

- Toolchain pinned in-gate to asdf 1.20.4-otp-29 / OTP 29.1.2 (repo pin);
  Homebrew 1.19.5 mixes refuse (`~> 1.20`).
- `rg` not used (grep/awk/python3 only) — rg fail-loud guard not applicable.
- `MIX_BUILD_ROOT` lane law: gate uses its own `tmp/bin-opt/build` scratch
  root by design; no shared `_build` contact from this lane.
