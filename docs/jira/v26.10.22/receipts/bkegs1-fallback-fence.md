# BK-EGS1 — F-EGS1 repair: crash-fence fault-guard (fallback envelope) on EgressRouter, ArmGateway.Router, Mcp.Router

**Standing:** ALIVE
**Context:** solo
**Date:** 2026-10-22
**Lane:** BK-EGS1
**Repairs:** BK-EGSKEP finding F-EGS1 (docs/jira/v26.10.22/receipts/bkegskep-fence-audit.md); ticket EXPL9-R2

## Change

Per the EXPL9-R2 ticket: each `handle_errors/2` body is wrapped in `try/rescue`;
the rescue path renders a fault-free constant fallback — module-attribute bytes
+ static v4-shaped request id `00000000-0000-4000-8000-000000000000` — and logs
the secondary fault loudly ("... handle_errors itself FAULTED (F-EGS1 fallback
engaged)"). The rescue path contains no fallible call (`put_resp_header` /
`send_resp` / state check only). Secondary-fault logging goes through
`Exception.format(:error, secondary, __STACKTRACE__)`.

- `lib/smalt/egress_router.ex` — guard + Storage XML fallback
  (`@fegs1_fallback_body` / `@fegs1_fallback_request_id` attributes,
  `fegs1_fallback_send/2`)
- `lib/smalt/arm_gateway/router.ex` — guard + ARM JSON fallback (same static
  rid, `application/json; charset=utf-8`)
- `lib/smalt/mcp/router.ex` — the router declared `use Plug.ErrorHandler` but
  never defined `handle_errors/2` (default no-op → ALWAYS re-raise → naked 500
  on ANY crash, a stronger version of F-EGS1). Added `handle_errors/2` with the
  same guard: healthy path renders the JSON-RPC error envelope
  (`-32603 InternalError`) + fresh `x-ms-request-id`; rescue path renders the
  constant JSON-RPC fallback. Local `generate_uuid/0` added (MCP previously had
  no rid generator).

## Court — test/internal/bkegs1_fence_court_test.exs (real Bandit, template rigs per the audit method)

Rigs carry the subject routers' `handle_errors/2` VERBATIM (helpers module-
qualified onto the real subject API); boom rigs carry the SHIM-COURT mutation
(a fallible helper raises). No mocks, no sleeps (0 `Process.sleep`).

```
$ MIX_BUILD_ROOT=_build-bkegs1 MIX_ENV=test mix test test/internal/bkegs1_fence_court_test.exs
Finished in 1.4 seconds (0.00s async, 1.4s sync)
Result: 6 passed
```

Legs witnessed:
- LEG1 egress guarded, healthy error_xml → 500 Storage envelope + fresh rid
- LEG2 OLD unguarded handler + faulting error_xml → NAKED 500 (empty body, rid
  ABSENT) — the F-EGS1 defect class witnessed live
- LEG3 guarded + the SAME faulting error_xml → exact constant fallback envelope
  + static rid (the flip; a court that cannot flip is FAIL)
- LEG4 ARM guarded, healthy helpers → 500 ARM envelope + fresh rid
- LEG5 ARM + faulting rid generator → exact fallback ARM envelope + static rid
- LEG6 MCP healthy → JSON-RPC envelope + fresh rid; faulting generator → exact
  fallback + static rid

Regression: expl9r1 + expl9r2 + mcpt1 + bkegs1 fresh on the merged tree:

```
$ MIX_BUILD_ROOT=_build-bkegs1 MIX_ENV=test mix test test/internal/expl9r1_egress_guard_court_test.exs test/internal/expl9r2_arm_guard_court_test.exs test/internal/mcpt1_dispatch_court_test.exs test/internal/bkegs1_fence_court_test.exs
Finished in 16.4 seconds (0.00s async, 16.4s sync)
Result: 28 passed
```

## Real-lib shim court (file mutation, SHIM-COURT marked, byte-exact restore)

Shim: `error_xml/2` in `lib/smalt/egress_router.ex` gets a raising head
(`# SHIM-COURT F-EGS1: error_xml/2 faulted`). Probe:
`mix run --no-start /tmp/bkegs1/shim_court.exs` — two verbatim-handler rigs
over real Bandit; the guarded rig's healthy path calls the real (now-faulting)
`Smalt.EgressRouter.error_xml/2`.

```
BASELINE  sha256=1554a0971c64c6ce345dbeb9f136ee4998749aab0c8358649e22fd26bd16da7d
--- BEFORE (unshimmed lib) ---
GUARDED  -> HTTP=500 rid=6cac82d0-79aa-4b26-aec1-2c8c8b950bc9 body="<?xml version=\"1.0\" encoding=\"utf-8\"?><Error><Code>InternalServerError</Code><Message>Internal server error.</Message></Error>"
UNGUARDED-> HTTP=500 rid=d561da2a-f413-4f8d-a5fd-e0c1acf29038 body="<?xml ...same envelope...>"
--- SHIM applied sha256=3aa7517745e19dff647b88762cf99f30475e33238de430e7e0efdd6e45c2e5fc (marker lines: 9) ---
GUARDED  -> HTTP=500 rid=00000000-0000-4000-8000-000000000000 body="<?xml version=\"1.0\" encoding=\"utf-8\"?><Error><Code>InternalServerError</Code><Message>Internal server error.</Message></Error>"
UNGUARDED-> HTTP=500 rid=ABSENT body=""
RESTORED  sha256=1554a0971c64c6ce345dbeb9f136ee4998749aab0c8358649e22fd26bd16da7d (byte-exact: YES)
--- RESTORE ---
GUARDED  -> HTTP=500 rid=a89a35f6-3831-4471-adf5-ea8eb0749bf2 body="<normal envelope, fresh rid>"
UNGUARDED-> HTTP=500 rid=1c1c2eb8-9d15-4a69-abd0-1ee9a3f17a1b body="<normal envelope, fresh rid>"
```

The flip: under the SHIM the unguarded rig renders the NAKED 500 (empty body,
rid ABSENT) while the guarded rig renders the well-formed fallback envelope
with the static rid — F-EGS1 closed on real wire evidence. RESTORE verified
byte-exact (sha256 equality). No shim residue in lib (grep exit 1). Lib file
state is net-zero vs the landed tree (pristine copy round-trip).

## Verdict

F-EGS1 is repaired on all three shared-template surfaces: a fault INSIDE
`handle_errors/2` now renders a well-formed constant fallback envelope with a
request id — never the naked Bandit 500. F-EGS2 (untrappable kill) remains
typed NOT-A-DEFECT(inherent) per the audit. Standing ALIVE on the falsifier:
the shim that faults error_xml/2 flips the wire outcome from naked 500 to the
fallback envelope, and the restore leg proves the fence's normal face is
unchanged (fresh-rid envelope).

## Footer

Probe script: /tmp/bkegs1/shim_court.exs (scratch, uncommitted). Lane build
root `_build-bkegs1` is lane-owned; coordinator reclaims at integration. Router
+ court files landed via coordinator checkpoint commits (7a84b484 lineage).
Files touched: this receipt only.