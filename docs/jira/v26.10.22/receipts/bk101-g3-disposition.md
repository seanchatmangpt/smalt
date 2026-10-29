# Receipt: BK-101 — JA-15b G3 disposition (egress containment seam)

**Standing**: ALIVE
**Context**: solo
**Date**: 2026-10-21 · Lane: BK-101 · Build root: `_build-bk101` ·
Toolchain: OTP 29.1.2 + Elixir 1.20.4-otp-29 (`PATH=/Users/sac/.asdf/shims:$PATH` on every command).
**Subject**: canonical checkout `/Users/sac/smalt`, branch main (moving — concurrent tick checkpoints).

## Carried claim (JA-15b G3)

`docs/jira/v26.10.21/receipts/ja15-error-logger-audit.md` (§5 G3, and §2 at its
`:3279/:3319` line refs) and `ja15b-gap-adoption.md` (Carried section) state:
`with_valid_body`/`safe_dispatch` in egress_router.ex are "unwired (zero
callers)" — dead seam code, site log unreachable.

## Investigation result: premise rot — the claim is FALSE on the current tree

- The seam **is wired**: 38 call sites of `with_valid_body(` across 8 files
  (grep -c, current tree):
  KvRoutes 13, CosmosRoutes 12, ObservabilityRoutes 7, AppConfigRoutes 2,
  AttestRoutes 1, SchemaRegistryRoutes 1, SqlIngestRoutes 1, egress_router.ex 1
  (the definition file itself uses it once at `wrap`-face). Every route module
  does `import Smalt.EgressRouter, except: [match: 2, dispatch: 2]`.
- `safe_dispatch` is reachable from every one of those call sites
  (`with_valid_body` → `safe_dispatch` when the body is valid), and its rescue
  logs the site line `egress invalid body on <path>` — reachable, not dead.
- History: `git log -S with_valid_body` shows callers in the route modules
  going back through the w6R structural-split lineage to the initial commit
  (8078b77, 2026-10-15). The audit's `:3279/:3319` line refs match an older
  tree state, not this one (functions live at 3402/3442 today).

## Disposition: no wire, no deletion — the gap row is retired as stale premise

ERRC gives delete-or-wire only when the premise holds; it does not. Nothing to
wire (already wired), nothing to delete (38 live callers). Zero edits to
`lib/` this lane (`git status` at lane start: egress_router.ex clean; only
pre-existing unrelated dirt). The site log's reachability is proven, not
argued:

- **Leg A**: `with_valid_body` on a POST conn with `body_params =
  %Plug.Conn.Unfetched{}` → 400 `{"error":{"code":"InvalidBody"}}`.
- **Leg B**: `safe_dispatch` with a handler raising `FunctionClauseError` →
  400 envelope + `Logger.warning("egress invalid body on /app/transactions: Elixir.FunctionClauseError")`
  captured.

Probe source (lane-owned, uncommitted:
`test/internal/bk101_g3_seam_probe_test.exs` — 2 tests, Chicago-style real
conns, no mocks):

```elixir
conn = %Plug.Conn{} |> TestConn.conn("POST", "/app/transactions", "")
c1 = Smalt.EgressRouter.with_valid_body(conn, fn c -> c end)
# → status 400, code InvalidBody
capture_log(fn ->
  c2 = Smalt.EgressRouter.safe_dispatch(conn, fn _ -> raise FunctionClauseError end)
  assert c2.status == 400
end) =~ "egress invalid body on /app/transactions"
```

Note: `grep -rn "InvalidBody"` in test/ finds no prior wire test asserting the
400 gate or the site-log line — the seam had usage but no direct court of its
own; the probe closes that for this lane.

## Court (real outputs)

```
PATH=/Users/sac/.asdf/shims:$PATH MIX_BUILD_ROOT=_build-bk101 \
  mix test test/internal/ja15_error_logger_court_test.exs            → 7 passed
PATH=/Users/sac/.asdf/shims:$PATH MIX_BUILD_ROOT=_build-bk101 \
  mix test test/internal/bk101_g3_seam_probe_test.exs                → 2 passed
PATH=/Users/sac/.asdf/shims:$PATH MIX_BUILD_ROOT=_build-bk101 \
  mix test test/integration/bk19_kd10_kv_put_route_test.exs \
          test/integration/deletedkeys_purge_route_test.exs \
          test/integration/namespace_put_test.exs                    → 7 passed
```

ja15 court 7/7 (BK-94's syntax + premise repairs hold on this run); egress
wire faces (KV put/purge/namespace, all through `with_valid_body`) 7/7.

## Residue

- The audit + ja15b carried note should be read as superseded by this receipt;
  G3 row: **closed — stale premise, seam wired and witnessed**. G2 (error-path
  telemetry) remains open.
- BK-94's court-file assertion diffs remain uncommitted in the working tree
  (owned there, untouched by this lane).
- Temp note: a `mix run` probe variant failed with `:eaddrinuse` (substrate
  holds fixed ports) — the test-harness form (ephemeral ports) is the
  replayable one.

## Falsifier / replay

Running the three commands above on this tree must return 7/2/7 passed.
Deleting `with_valid_body` flips leg A and the egress face tests; removing the
`Logger.warning` from `safe_dispatch` flips leg B.
