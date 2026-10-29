# BK-XPRIF — plug_status < 500 exemption in the crash-path fence

**Standing: ALIVE** — BK-XPRI's deterministic HIGH regression is flipped: the GLD-3
sql-ingest malformed-JSON face answers typed 400 again (3/3, 2/2 runs), and every
BK-EGS1 crash-face leg stays green. Genuine 500-class crashes still hit the fallback
envelope; typed 4xx-class exceptions now reach the adapter untouched.

Context: solo · Date: 2026-10-22 · Repo: /Users/sac/smalt
Lane: BK-XPRIF · Build roots `_build-bkxprif` / `_build-bkxprif2` deleted at lane close.

## Change

The BK-EGS1/EXPL9-R2 crash fence (`handle_errors/2`) sent its 500 Storage/ARM/JSON-RPC
envelope for ANY unhandled exception — including `Plug.Parsers.ParseError`
(`plug_status: 400`) — swallowing the typed 400 that Bandit would otherwise render
(BK-XPRI finding, `docs/jira/v26.10.22/receipts/bkxpri-cross-milestone.md`).

Fix: a leading exemption clause in all three fenced routers. When
`kind == :error and Plug.Exception.status(reason) < 500`, the fence skips (logs
"typed plug-status crash (fence skipped)"), returns `:ok` without sending, and lets
Plug.ErrorHandler's guaranteed re-raise carry the exception to Bandit, which renders
the exception's own typed status with the pre-fence body face. Everything else keeps
the BK-EGS1 guarded path (try/rescue + F-EGS1 constant fallback).

Files (all three fences, same hole, same fix):

- `lib/smalt/egress_router.ex` (`handle_errors/2`)
- `lib/smalt/arm_gateway/router.ex` (`handle_errors/2`)
- `lib/smalt/mcp/router.ex` (`handle_errors/2`)

`Plug.Exception.status/1` is total (protocol with `@fallback_to_any`: exceptions with a
`plug_status` field map through `Plug.Conn.Status.code/1`, everything else → 500), so the
exemption is safe for any `kind: :error` reason; non-`:error` kinds (throw/exit) never
carry a plug status and fall to the 500 path.

## Court

`test/internal/bkegs1_fence_court_test.exs` — the six existing rigs updated verbatim to
carry the exemption clause, plus a new `EgressParseRig` (real `Plug.Parsers` + JSON
parser + the current egress `handle_errors/2` verbatim) and **LEG7**: real Bandit,
real malformed-JSON POST (`{"format": ` with `content-type: application/json`) →
**typed 400**, empty body (the exact pre-fence parse-error face), fence 500 envelope
ABSENT (no `<Code>InternalServerError</Code>`, no x-ms-request-id), control leg
well-formed JSON → 200. 6 old legs (crash → 500 envelope / fallback flip) unchanged
and green.

## Embedded court output

```
$ MIX_BUILD_ROOT=_build-bkxprif mix test test/internal/sql_ingest_wire_court.exs   # run 1
Result: 3 passed
$ MIX_BUILD_ROOT=_build-bkxprif mix test test/internal/sql_ingest_wire_court.exs   # run 2
Result: 3 passed
$ MIX_BUILD_ROOT=_build-bkxprif mix test test/internal/bkegs1_fence_court_test.exs
Result: 7 passed
$ MIX_BUILD_ROOT=_build-bkxprif mix test \
    test/internal/sql_ingest_wire_court.exs \
    test/internal/bkegs1_fence_court_test.exs \
    test/internal/expl9r1_egress_guard_court_test.exs \
    test/internal/expl9r2_arm_guard_court_test.exs \
    test/internal/mcpt1_dispatch_court_test.exs
Result: 32 passed
$ mix format --check-formatted <4 changed files>
FORMAT-OK
```

## Falsifiers (all fired in the passing direction)

1. GLD-3 malformed-JSON leg → 400 again (regression flipped): `sql_ingest_wire_court.exs`
   3/3, twice.
2. Genuine crash → still the well-formed 500 envelope: fence court LEG1-6, 7/7.
3. BK-EGS1 + expl9r1/expl9r2 + mcpt1 regression set: 32/32 (was 28 legs + GLD-3 3 + new LEG7).

## Notes

- The mcp/router.ex:309 `@json_rpc_parse_error` undefined-attribute warning is
  pre-existing (line 309, outside the edited handler) — not session-introduced.
- Old LEG2 (naked-500 defect class, unguarded handler) intentionally unchanged — its
  rig is the pre-BK-EGS1 handler and still witnesses the BEFORE.
