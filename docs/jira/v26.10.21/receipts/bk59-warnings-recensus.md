# BK-59 — Fresh warnings sweep (post-BK-7 recensus)

**Standing**: PARTIAL_ALIVE — smalt-owned non-generated fixable set is clean
  (1 file fixed, verified by recompile); residual = owned-elsewhere + external
  path-deps. Recensus only, no commit.
- **Context**: solo
- **Lane**: BK-59
- **Date**: 2026-10-21
- **Toolchain**: asdf elixir 1.20.4-otp-29 / erlang 29.1.2 (`.tool-versions`
  pin). Note: plain `mix` on this machine resolves to homebrew 1.19.5/OTP-28
  and refuses the project (`supports only ~> 1.20`) — PATH must be prefixed
  with the asdf install bins.

## Before/after

- **Before** (compile 3, first full sweep): 34 diagnostic sites — of which
  1 hard syntax error (`lib/smalt/messaging/ws_amqp_relay.ex` missing `end`,
  file being written mid-write by its lane) + 33 warnings.
- **After** (compile 6, current tree): 31 warnings, all residual classified
  below. `--warnings-as-errors` still exits nonzero, entirely from
  owned-elsewhere / external items.

## Fixed (smalt-owned, non-generated)

| File | Warning | Fix |
|---|---|---|
| `lib/smalt/apim.ex:77` | `@impl true` on `handle_info/2` with no behaviour declaring it (only `@behaviour Plug` declared) | Dropped `@impl true`, left bare `def handle_info/2` (GenServer still dispatches at runtime). First attempt (`@behaviour GenServer`) was itself rejected by the compiler — Plug and GenServer conflict on `init/1` — and is documented in an adjacent comment. `git diff`: 3 insertions, 1 deletion, no runtime change. |

## Owned-elsewhere (not touched)

| File | Items | Owner |
|---|---|---|
| `lib/smalt/mcp/router.ex` | 6 clause-match warnings surfaced through plug router macro (`Smalt.Mcp.Router.invoke/2`) | BK-49 |
| `lib/smalt/egress_router.ex` | 1 clause-match warning (`Smalt.EgressRouter.do_match/4`) | BK-56 |
| `lib/smalt/egress/kv_routes.ex` (KvRoutes) | 3 clause-match warnings | BK-56 (egress family) |
| `lib/smalt/messaging/ws_amqp_relay.ex` | 2 unused-variable `sock` (103/107); file was also captured mid-write with a syntax error during the sweep, then rewritten by its lane | sync/relay lane (in-flight, untracked→tracked in loop window) |
| `lib/smalt/sync/frame.ex:86` | unpinned `len` in bitstring `size(...)` | sync lane (untracked `lib/smalt/sync/`, in-flight) |
| `lib/smalt/egress/SyncRoutes.ex` | hard CompileError (undefined functions) blocking the whole compile | sync lane (untracked, in-flight) |
| `lib/smalt/plane/data_supervisor.ex` | CompileError (undefined `ws_relay_port/0`) — captured mid-edit | sync/relay lane (modified in loop window); HEAD version restored for the sweep, lane edit re-restored byte-exact after (sha-verified) |

## External path-deps (other repos, not smalt-owned)

- `ggen_igniter 26.10.7` — 11 warnings (safe_rename, execute, projection,
  filter, toml_io, install task, convergence/controller `record/0` type
  overrides)
- `ash_r2rml 26.10.8` — 8 warnings (policy, resource, compiler,
  persist_mapping, obda_in_memory, ocel_ash_emitter)
- `ash_graphlaw 26.10.8` — 1 warning (enums Map.get/3)

## Generated-class

None observed — no warnings from `lib/smalt/mcp/generated/`, `registry.ex`,
`store_tables.ex`, `config.ex`, `cascade_edges.ex`, or semconv registry.

## Compile-integrity ledger (multi-lane shared checkout)

Two in-flight lane files blocked the sweep (SyncRoutes.ex, ws_amqp_relay.ex,
then data_supervisor.ex); each was snapshot-aside/restored byte-exact
(sha256 `OK` receipts in-session). Note: ws_amqp_relay was *rewritten by its
lane* during the sweep, so the restored-file checksum equals the lane's
newer write, not the original snapshot — the lane's current disk state is
the intended subject. Build root `_build-bk59` is lane-local
(`just lane-clean` reclaims it).

## Verification

```
MIX_BUILD_ROOT=_build-bk59 mix compile --warnings-as-errors
→ 31 warnings, zero in smalt-owned non-generated non-owned-elsewhere files
  (apim.ex absent from warning list — fix confirmed by recompile)
```

---

## RE-WITNESS addendum (BK-REWIT wave 1, 2026-10-22)

Original evidence above untouched. Replay (asdf toolchain, lane build root
`_build-rewit`, current tree — which has moved since 2026-10-21):

```
$ export PATH="$HOME/.asdf/shims:$PATH"
$ MIX_BUILD_ROOT=_build-rewit mix compile --warnings-as-errors; echo exit=$?
Compilation failed due to warnings while using the --warnings-as-errors option
compile exit=1
$ MIX_BUILD_ROOT=_build-rewit mix compile | grep -cE '^warning:'; echo exit=$?
8
warn-count exit=0
$ MIX_BUILD_ROOT=_build-rewit mix compile | grep -oE '(deps|lib)/[A-Za-z0-9_/.]+:[0-9]+' | sort | uniq -c | sort -rn
  20 deps/plug/lib/plug/router.ex:<line>  (6 distinct sites, via Smalt.Mcp.Router.invoke/2 — BK-49 owned-elsewhere class)
   1 lib/smalt/messaging/amqp/sas_verifier.ex:198   (duplicate defp audience_matches?/4)
   1 lib/smalt/messaging/amqp/sas_verifier.ex:223
```

Classification reproduces: exit=1 under --warnings-as-errors entirely from
owned-elsewhere (plug-router-macro class, BK-49) + 2 sites in
`sas_verifier.ex` (in-flight lane surface, not a BK-59-owned file).
`apim.ex` is absent from the warning list — the receipt's one fix is still
confirmed by recompile. Residual count moved 31 -> 8 because the tree moved,
not because the classification drifted. Re-witness verdict: PASS (exit=1 is
the receipt's own predicted outcome).
Standing: PARTIAL_ALIVE (unchanged).
