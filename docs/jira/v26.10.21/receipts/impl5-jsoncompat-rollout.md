# IMPL-5 — AR-WIRE-01 JsonCompat rollout: native default flip + 3 hot decode sites

Context: pair(AR-WIRE-02 lane live-editing shared files throughout the window (existing pair line normalized to law form))

**Standing:** **PARTIAL_ALIVE** (native default ALIVE on this OTP-28 host; integration tier
170/170 green under the native engine; A/B-vs-Jason formal court not run — see falsifiers)

Context: pair (AR-WIRE-02 lane live-editing shared files throughout the window)

Date: 2026-10-21

## What landed

1. **Default flip, runtime-gated** (`lib/smalt/json_compat.ex`): engine default is no
   longer hard-coded `:jason` — `default_engine/0` returns `:native` when
   `Code.ensure_loaded?(:json)` and `:json.decode/1` is exported, else `:jason`.
   Explicit `config :smalt, :json_engine` overrides either way. Added public
   `JsonCompat.decode/1` (`{:ok, _} | {:error, exception}`) for call sites wanting the
   non-raising form.
2. **Three hot decode families converted**:
   - arm_gateway body parse: `lib/smalt/arm_gateway/router.ex` Plug.Parsers
     `json_decoder: {Smalt.JsonCompat, :decode!, []}` (Plug MFA contract verified in
     `deps/plug/lib/plug/parsers/JSON.ex` — `{m, f, []}` → `decode!/1`).
   - cosmos query parse: `lib/smalt/egress_router.ex` — the main data-plane
     `@parsers_opts` json_decoder MFA (covers cosmos `query+json` and all
     body_params JSON) plus the `decoded_body/1` raw fallback via new
     `Smalt.JsonCompat.decode/1`.
   - kv secret body: `lib/smalt/data_plane/key_vault_actions.ex:1070` (backup
     envelope) and `lib/smalt/data_plane/vault_data.ex:129` (secret restore blob).
     Honest scoping note: KV secret PUT bodies ride body_params (covered by the
     egress_router Parsers MFA); these two are the KV-family *blob* decodes.
3. Court updated: `test/json_compat_test.exs` engine-flag test now asserts the
   runtime-gated default and the decode/decode! agreement (incl. invalid input).

## Tier output (real, MIX_BUILD_ROOT=_build-impl5)

```
$ MIX_BUILD_ROOT=_build-impl5 mix test test/json_compat_test.exs test/integration
Finished in 12.7 seconds (0.4s async, 12.3s sync)
170 tests, 0 failures
```

Determinism check: pinned seed (`--seed 0`) green twice; unpinned runs varied 0–6
failures on identical code during peak concurrent-lane load, all in a failure class
orthogonal to JSON decode (`AppConfigEvents` `{:already_started, _}` supervision
singletons; `namespace_put` `:code.delete` unload race) and passing in isolation
(15/15) and at low load. Failing tests re-run individually: `15 tests, 0 failures`.

## Compile-freeze SLA disclosure

The AR-WIRE-02 lane's in-flight edits used `int_in/3` guards with a `defguardp`
present only in `blob_storage.ex` — `file_share.ex` and `cosmos.ex` did not compile,
freezing this lane's fresh `_build-impl5` root. Minimal unblock applied per SLA:
local `defguardp int_in/3` inserted before first use in
`lib/smalt/data_plane/file_share.ex` and `lib/smalt/data_plane/cosmos.ex` (marked
`UNBLOCK FIX (IMPL-5...)`). The owning lane normalized these during the window;
compile green after bounded poll (4 attempts, ~3 min). Shared-compile churn then
broke the tier twice more; both cleared on bounded re-poll (60s cadence, 20 min cap).

## Commit state

Coordinator committed the lib deltas mid-flight in `48ad71f` (verified: all five
JsonCompat sites present in HEAD via `git show HEAD:<path> | grep -c JsonCompat`).
Still uncommitted in the working tree: `test/json_compat_test.exs` (this lane's
court update — coordinator owns commits).

## Numbers, honest

- Host is OTP 28 / Elixir 1.19.5 (`:json` stdlib-7.2 available, so the gate selects
  `:native` here); the prompt said OTP-29 — the flip is host-gated, so it is
  correct on either.
- No JSON-divergence findings in the integration tier: zero semantic deltas
  (null/bignum/float classes all already typed and normalized by the seam).
- No perf claim: this receipt does not measure throughput; decode-site wall-clock
  deltas are unmeasured (no bench lane was run for this rollout).

## Falsifiers / open

- Falsifier NOT run: a formal Jason-vs-native A/B over the full integration wire
  corpus (the equivalence court covers 9 payload classes, not the whole tier's
  bodies). Residual: a payload class where `:json` and Jason diverge beyond `null`
  would surface only on a real divergent body.
- `test/json_compat_test.exs` needs a coordinator commit to be receipt-clean.

## Files (absolute)

- /Users/sac/smalt/lib/smalt/json_compat.ex
- /Users/sac/smalt/lib/smalt/arm_gateway/router.ex
- /Users/sac/smalt/lib/smalt/egress_router.ex
- /Users/sac/smalt/data_plane/key_vault_actions.ex → /Users/sac/smalt/lib/smalt/data_plane/key_vault_actions.ex
- /Users/sac/smalt/lib/smalt/data_plane/vault_data.ex
- /Users/sac/smalt/test/json_compat_test.exs
- /Users/sac/smalt/lib/smalt/data_plane/file_share.ex, /Users/sac/smalt/lib/smalt/data_plane/cosmos.ex (SLA unblock)
