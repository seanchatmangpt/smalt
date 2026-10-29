# BK-EGSKEP — egress/ARM crash-fence skeptic audit (EXPL-9 F2b adversarial verification)

**Standing:** PARTIAL_ALIVE — the fence holds under 5 of 7 probed crash classes; 2 classes escape it (F-EGS1, F-EGS2)
**Context:** solo
**Date:** 2026-10-22
**Lane:** BK-EGSKEP (read-only skeptic; only this receipt written)

## Subject

EXPL9-R1's F2b claim (`docs/jira/v26.10.22/receipts/expl9r1-egress-guards.md`): `use
Plug.ErrorHandler` + `handle_errors/2` on `Smalt.EgressRouter` — "Any unhandled
crash now renders the Storage `<Error>` envelope with a fresh `x-ms-request-id` —
never a naked Bandit adapter 500."

## Method (no mocks, real HTTP)

Real self-booted smalt app (MIX_ENV=test, ephemeral ports, :anonymous) with the
real `Smalt.EgressRouter` (60276) and `Smalt.ArmGateway.Router` (60274) live, plus
template rigs over real Bandit 1.13.1 whose `handle_errors/2` is copied VERBATIM
from `Smalt.EgressRouter` (reusing the subject's own public `error_xml/2` and
`generate_request_id/0`). Crash injection is mechanical in the rigs (the real
routers have no input-triggerable arm crash today — typed below); the handler is
the subject's own code. Every probe is a raw-socket request with `Connection:
close`; every wait is a deadline recv — no sleeps.

```
$ MIX_BUILD_ROOT=_build-bkegskep MIX_ENV=test mix run /tmp/bkegskep/fence_rig.exs   # exit 0
rig up on 60441 / handler-boom rig up on 60442
real egress port 60276, real arm port 60274
PROBE T1-raise-in-route -> HTTP=500 rid=231969aa-4de5-49e5-a46a-ba381eed47d2 code=InternalServerError body="<?xml version=\"1.0\" encoding=\"utf-8\"?><Error><Code>InternalServerError</Code><Message>Internal server error.</Message></Error>"
PROBE T2-throw-in-route -> HTTP=500 rid=e06a38c4-4462-4309-a1a6-cc0f69489f7d code=InternalServerError (same envelope)
PROBE T3-catchable-exit-in-route -> HTTP=500 rid=486435c6-25ee-4fa0-8512-5989488cbec7 code=InternalServerError (same envelope)
PROBE T4-untrappable-kill -> HTTP=none rid=ABSENT code=no-code body=""
PROBE T5-raise-in-before_send -> HTTP=500 rid=4587c702-5bd0-46f1-b9e0-7d3ad5ba2a22 code=InternalServerError (same envelope)
PROBE T0-handler-ok -> HTTP=200 rid=ABSENT code=no-code body="fine"
PROBE T6-raise-inside-handle_errors -> HTTP=500 rid=ABSENT code=no-code body=""
real egress port 60276, real arm port 60274
PROBE R1-egress-typed-baseline -> HTTP=404 rid=8a85c66b-06b9-47a7-ab7d-67c9b94ccfe2 code=RouteNotFound body="{\"error\":{\"code\":\"RouteNotFound\",\"message\":\"No route matches GET /bkegskepacct\"}}"
PROBE R2-egress-binary-garbage -> HTTP=none rid=ABSENT code=no-code body=""
PROBE R3-arm-typed-baseline -> HTTP=404 rid=b119bd66-73ea-4949-b9e0-3fcebfb7d5ce code=RouteNotFound body="{\"error\":{\"code\":\"RouteNotFound\",\"innererror\":{},\"message\":\"The route '/subscriptions/00000000-0000-0000-0000-000000000000/x' could not be found.\",..."
PROBE T7-bandit-read-timeout -> deadline-no-close after 20s (no 500, conn held)
DONE bkegskep
```

## Findings

### Covered classes (wire-witnessed over real Bandit HTTP)

| class | probe | witnessed result |
|---|---|---|
| raise in route arm | T1 | 500 Storage XML envelope + fresh x-ms-request-id |
| throw in route arm | T2 | 500 envelope (Plug.ErrorHandler catches `:throw`, renders, then re-raises; re-raise is harmless — response already sent) |
| catchable exit in route arm | T3 | 500 envelope (catches `:exit`) |
| raise in a `register_before_send` callback | T5 | 500 envelope; the in-flight send aborts pre-wire, `conn.state` still `:set`, handler sends the 500 — double-send-safe |

This supplies the wire-level crash evidence EXPL9-R1's court explicitly left "out
of scope" (its leg 5 was source-level only).

### F-EGS1 (MEDIUM, class hole): fault INSIDE handle_errors → naked Bandit 500

T6: with the subject's own verbatim handler, a raise inside `handle_errors`
itself propagates out of `Plug.ErrorHandler.__catch__` (plug 1.20.3
`error_handler.ex:113`) through `Bandit.Pipeline.call_plug!` → **HTTP 500, empty
body, no envelope, no x-ms-request-id — the exact naked-500 shape the F2b claim
denies.** Log excerpt (rig):

```
error[] bkegskep handler-boom: raising INSIDE handle_errors
error[] ** (RuntimeError) bkegskep raise-inside-handle_errors kind=:error reason=%RuntimeError{message: "bkegskep raise-in-route (handler-boom rig)"} stack=8
    BkEgskep.HandlerBoomRig.handle_errors/2
    (plug 1.20.3) lib/plug/error_handler.ex:113 Plug.ErrorHandler.__catch__/6
    (bandit 1.13.1) lib/bandit/pipeline.ex:168 Bandit.Pipeline.call_plug!/2
```

Real-subject induction is not input-triggerable today (the handler faults only if
`error_xml/2` or `generate_request_id/0` fault) — typed CLASS finding on the
GAP-AZB20-3 template, not a witnessed subject defect. Applies identically to the
ARM router and `Smalt.Mcp.Router` (same template).

**Repair ticket EXPL9-R2 (F-EGS1):** wrap the `handle_errors` body in
`try/rescue`; the rescue path renders a fault-free fallback (plain
`send_resp(conn, 500, minimal_bytes)` with a precomputed constant request-id
string) that itself contains no fallible call. Falsifier: a shim court shimming
`error_xml/2` to raise must still yield a well-formed 500 with
`x-ms-request-id`.

### F-EGS2 (LOW, inherent, not repairable): untrappable kill → connection close, no response

T4: `Process.exit(self(), :kill)` in a route arm kills the request process; the
fence cannot run in a dead process — client sees connection close with no
response. Not a 500 (so the claim's literal wording survives), but also no
envelope. Typed NOT-A-DEFECT(inherent): no in-process handler can render after
process death. Any hardening is adapter-level only (out of scope).

### Observations (no defect)

- **T7 Bandit read-timeout:** partial request line left open 20s → connection
  held, never a 500. Timeout is adapter-owned (ThousandIsland/Bandit closes at
  its `read_timeout`), outside the plug pipeline — the F2b claim's scope holds.
- **R2 binary garbage:** raw `\x00\x01...` request → adapter closes, no 500.
  Adapter-typed, outside the fence's scope.
- **Pre-router plugs** (`HealthPlug`, `Plug.Logger`, `egress_cors`) sit INSIDE
  the fenced `call/2` (Plug.ErrorHandler wraps the whole Plug.Builder pipeline),
  so a crash there is covered. The only unfenced hop is the composite path
  selector in `lib/smalt/application.ex` (Dispatch, ~L267-306) — a plain module
  with no ErrorHandler; its cond is total (no raise path: `starts_with?`,
  `contains?` on always-binary path/query_string), so exposure is nil today, but
  it is the one crash surface upstream of both fences.
- **Egress vs ARM delta:** ARM's handler reuses the stashed
  `conn.private[:arm_request_id]` (wire continuity across the crash);
  egress generates a fresh id. Divergence typed: cosmetic (Azure accepts fresh
  ids), ARM shape is strictly better for log correlation.

## Court (fresh suite runs)

```
$ MIX_BUILD_ROOT=_build-bkegskep MIX_ENV=test mix test test/internal/expl9r1_egress_guard_court_test.exs test/internal/expl9r2_arm_guard_court_test.exs test/internal/kd_blob_court_test.exs test/internal/blob_xml_error_test.exs
Finished in 30.6 seconds (0.00s async, 30.6s sync)
Result: 25 passed
```

## Verdict

The F2b claim holds for every crash class reachable inside the plug pipeline
(raise/throw/exit/before_send — wire-witnessed), and the naked-500 class it was
built against is genuinely closed for those. It does NOT hold universally:
a fault inside `handle_errors` itself still renders the naked Bandit 500
(F-EGS1), and process death (T4) yields no response at all. Standing
PARTIAL_ALIVE pending EXPL9-R2's handler fault-guard.

## Footer

Probe rig: `/tmp/bkegskep/fence_rig.exs` (scratch, uncommitted), full log
`/tmp/bkegskep/run6.log`. Lane build root `_build-bkegskep` is lane-owned;
coordinator reclaims at integration (rm -rf was permission-denied in this
session). Files touched: this receipt only.
