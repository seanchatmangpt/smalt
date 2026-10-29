# JA-R1: Silent-violation fixes (V1-V4 from ja2-let-it-crash-audit)

Repo: `/Users/sac/smalt` · Branch: `main` · Date: 2026-10-21 · Context: solo · Lane: JA-R1 (owns `planes.ex`, `egress_router.ex`, `arm_gateway/router.ex`, `affidavit/seal.ex`, `security/ledger_writer.ex` only)

## Standing
**Standing:** ALIVE

**ALIVE** — all 4 violations fixed, compile exit 0, 19/19 targeted tests pass, refusal-path behavioral probes executed against real beams.

## Per-fix diff summary

### V1 — `lib/smalt/planes.ex` (atomize fail-open)

`parse_csv/1` no longer atomizes before validation. New `validate_name/1`
(string-domain check against `@known_strings`, derived from `@known`) raises
`InvalidPlane` with the raw string — no `String.to_atom/1` anywhere on the
path. `atomize/1` deleted. Known planes byte-identical
(`SMALT_PLANES=control,data,identity` -> `[:control, :data, :identity]`).
`SMALT_PLANES=bogus_plane` -> `Smalt.Planes.InvalidPlane` raised with
`{:invalid_plane, "bogus_plane"}`.

**Behavioral probe (real beam, 1.20.4-otp-29, `-pa _build-lane-r1/dev/lib/smalt/ebin`):**

```
$ SMALT_PLANES=bogus_plane_AAA elixir -pa .../ebin -e '...try resolve() rescue e -> {:refused, e.plane} end...'
{:first, {:refused, "bogus_plane_AAA"}, 100}   # 100 atoms = erl_eval/machinery, same in :all probe
{:second, {:refused, "bogus_plane_AAA"}, 0, ...} # delta 0 across a full refusal — refusal mints ZERO atoms
```

### V2 — `lib/smalt/egress_router.ex` `safe_subrouter_call` (silent benign fallthrough)

Rescue stays narrowed to `FunctionClauseError` (the only expected class —
anything else already propagated). The fallthrough is no longer silent:
`Logger.warning("egress subrouter #{inspect(m)} unmatched route — falling through")`.
Witnessed firing in the test slice: `19:45:34.427 [warning] egress subrouter
Smalt.Egress.ObservabilityRoutes unmatched route — falling through`. No
`telemetry` idiom nearby (router uses Logger everywhere); Logger is the
surface. All other exception classes still re-raise untouched.

### V3a — `lib/smalt/arm_gateway/router.ex` `affidavit_engine_seal` (silent catch-alls)

`rescue`/`catch :exit` now log via the module's existing `Logger.error`
idiom (same file: line 140 crash-500 logger) before returning the unchanged
`{:error, :engine_unavailable}` fail-closed envelope. No `:telemetry.execute`
idiom in the vicinity — Logger only, per instruction.

### V3b — `lib/smalt/affidavit/seal.ex` `call_export` (silent catch-alls)

Added `require Logger`; rescue/`catch :exit`/`catch :throw` each log
`Logger.error("affidavit seal: engine ... -> :engine_unavailable (...)")`.
Envelope unchanged; the module-not-loaded steady-state case (`call_engine/2`)
intentionally stays quiet (documented in code comment).

### V4 — `lib/smalt/security/ledger_writer.ex` sign rescue (silent swallow)

Added `require Logger`. The typed `throw({:ledger_sign_refused, ledger})`
refusal + counter compensation is unchanged; a `Logger.error` now precedes
the throw naming the ledger and the typed refusal.

## Verification commands + exits

Toolchain: asdf elixir 1.20.4-otp-29 (homebrew mix is 1.19.5 and refuses;
repo pins elixir 1.20.4-otp-29 / erlang 29.1.2 in `.tool-versions`). Lane
build root `MIX_BUILD_ROOT=_build-lane-r1` (fresh full build, no shared
`_build` collision with concurrent lanes).

```
$ mix compile                       -> exit 0 ("Generated smalt app"; 52 warnings all pre-existing, ZERO in the 5 owned files)
$ mix test test/internal/impl6_process_label_test.exs \
         test/integration/blob_xml_error_test.exs \
         test/internal/wasm_nif_lifecycle_test.exs
-> exit 0, "Result: 19 passed" (planes selection, egress blob wire face, typed
   engine_unavailable contract)
```

No `test/planes_test.exs` / `test/egress_router_test.exs` exist; this is the
smallest slice covering the owned modules. No sleeps, no mocks.

## Environment disclosure

Mid-verification, another lane's in-flight edit to `lib/smalt/store.ex`
(+122 lines, unclosed delimiter) broke the shared compile twice (transient);
both times resolved by the owning lane within the compile-freeze SLA — no
fix applied by this lane, no file outside my 5 touched. Lane build root
`_build-lane-r1` left in place for the coordinator to reclaim
(`just lane-clean`).

## Falsifiers

- V1: `SMALT_PLANES=<unknown>` must raise InvalidPlane naming the string and
  mint no atom (probe above shows delta 0 on the refusal path).
- V2: an unmatched subrouter route must emit the warning (witnessed) while
  non-FCE exceptions still propagate.
- V3/V4: any engine crash/exit/throw or sign failure must reach the log at
  error level while returning the identical typed refusal as before.
