# BK-49 — Mcp.Router flatten_children/2 compile warning

**Standing:** **ALIVE** (warning eliminated, witnessed; MCP surface boots + deferred-listeners court 3/3)
Context: solo

## Warning (exact)

```
warning: comparison between distinct types found:

    pid != :undefined

given types:

    pid() != :undefined

where "pid" was given the type:

    # type: pid()
    # from: deps/plug/lib/plug/router.ex:1516:36
    is_pid(pid)

While Elixir can compare across all types, you are comparing across types which are always disjoint, and the result is either always true or always false

└─ deps/plug/lib/plug/router.ex:1516:56: Smalt.Mcp.Router.flatten_children/2
```

Attributed via plug's router macro to `lib/smalt/mcp/router.ex:1516` — the guard
`is_pid(pid) and pid != :undefined` in `flatten_children/2`.

## Fix (diff)

```diff
-        if type == :supervisor and is_pid(pid) and pid != :undefined and Process.alive?(pid) do
+        if type == :supervisor and is_pid(pid) and Process.alive?(pid) do
```

Rationale: `is_pid(pid)` already excludes `:undefined` (not a pid), so
`pid != :undefined` was a dead comparison. Behavior-preserving.

## Verification

- `MIX_BUILD_ROOT=_build-bk49 mix compile --warnings-as-errors` after fix:
  `flatten_children` / `router.ex:1516` warning count = **0** (grep on
  `/tmp/bk49_compile8.log`). The tree-wide `--warnings-as-errors` still exits 1
  on OTHER pre-existing warnings outside this lane's scope
  (`Smalt.Mcp.Router.invoke/2` typer clauses at plug 706/726/747/981/1111/1335,
  `apim.ex:78`, etc.) — pre-existing, not session-introduced, not BK-49 scope.
- MCP surface boots clean with the fix: `Running Smalt.Mcp.Router with Bandit …
  at 127.0.0.1:<port> (http)` witnessed in the deferred-listeners court boot.
- `MIX_BUILD_ROOT=_build-bk49 mix test test/internal/deferred_listeners_court_test.exs`
  → **exit 0, 3 passed** (run 2; run 1 hit a 60s nested-probe timeout under
  concurrent-lane load — load flake, passed on rerun).
- No dedicated Mcp.Router test file exists; the MCP surface is exercised by the
  deferred-listeners court (MCP among `@deferred` listeners) and the CLI probes.

## Generated-file check

`lib/smalt/mcp/generated/mcp_descriptor.ex` is NOT involved — the warning
originates in hand-written `lib/smalt/mcp/router.ex:1516`. Generated file
untouched.

## Compile-freeze disclosures (same-checkout SLA)

- `lib/smalt/store.ex` (TTV-5 lane, committed mid-window at f675cf5 with a
  syntax error on Elixir 1.20.4): `{:heir, …}` tuple placed after keyword args
  in the `:ets.new` list — invalid (keyword list must be last). Minimal unblock
  fix applied: moved `{:heir, Process.whereis(:init), []}` before
  `read_concurrency:`/`write_concurrency:`. Disclosed here per SLA rule 6;
  committed by coordinator checkpoint d2825dc.
- Other lanes' in-flight files (`lib/smalt/sync/` dir, `lib/smalt/egress/SyncRoutes.ex`)
  were snapshot-aside to /tmp during compile/test runs and restored byte-exact
  after each run.

## Landing

Fix content landed via coordinator tick checkpoint **d2825dc** (BK-49 listed in
the checkpoint message). This lane did not commit.
