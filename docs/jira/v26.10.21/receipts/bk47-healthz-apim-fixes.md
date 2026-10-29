# Receipt: BK-47 — apim.ex duplicate-init/1 + HealthPlug missing halt()

Date: 2026-10-21 · Lane: BK-47 · Build root: `_build-bk47` · Context: solo

**Standing:** **ALIVE — both fixes verified on wire and in court**

Machine: Apple M3 Max, OTP 29.1.2 + Elixir 1.20.4-otp-29 (.tool-versions pin; lane shell
defaulted to 1.19.5 until PATH-pinned).

## Fix 1 — `lib/smalt/apim.ex` duplicate-`init/1` clause warning (JA-R2 residue)

JA-R2's GenServer conversion left `init/1` as two UNGROUPED clauses under DIFFERENT
`@impl` annotations (`@impl GenServer` on the `init(:ok)` owner clause at the old
line 59, `@impl Plug` on the `init(opts)` pass-through at the old line 73). Elixir
1.20.4 emits two warnings:

- `clauses with the same name and arity should be grouped together, "def init/1" was
  previously defined (lib/smalt/apim.ex:59)` (points at the `@impl Plug` clause, 73)
- `got "@impl GenServer" for function init/1 but this behaviour was not declared with
  @behaviour` (only `@behaviour Plug` is declared on the module)

**Kept both clauses, grouped under one `@impl true`**: the `init(:ok)` clause is the
LIVE GenServer owner clause (Process.set_label + ensure_table + persistent_term
publish) — that is the clause the task names as correct, and it was never dead. The
`init(opts), do: opts` clause is the live Plug.init pass-through, NOT dead either
(Plug behaviour declared on the module). The defect was grouping/@impl attribution,
not a dead clause: both callbacks share `init/1`, so a single grouped clause set with
`@impl true` satisfies both behaviours. `handle_info` also moved from `@impl
GenServer` (undeclared behaviour) to `@impl true`. Rationale comment left in-file
naming BK-47.

Gate:

```
$ MIX_BUILD_ROOT=_build-bk47 mix compile --warnings-as-errors   # (after fixes)
→ grep -c apim in output: 0   (was 2 apim.ex warnings on the identical cold run)
```

Note: tree-wide `--warnings-as-errors` still exits 1 during this window — the
failures are OTHER lanes' in-flight files (lib/smalt/egress/SyncRoutes.ex and
lib/smalt/store.ex churned mid-run, both self-recovered by their owners). Zero
smalt warnings attributable to apim.ex; not session-introduced by this lane.

## Fix 2 — HealthPlug missing `halt()`

`lib/smalt/health_plug.ex` sent all three response classes (GET /healthz, GET
/healthz/live, OPTIONS preflight 204) without halting, so the egress pipeline
continued into the next plug (:egress_cors → static_cors → CORSPlug), which calls
`register_before_send/2` on the already-sent conn.

### BEFORE (old code, live shared substrate pid 48942, 2026-10-21 20:41:27 PDT)

```
$ curl -s -o /dev/null http://127.0.0.1:8443/healthz        # then log delta:
20:41:27.168 [error] ** (Plug.Conn.AlreadySentError) the response was already sent
    (plug 1.20.3) lib/plug/conn.ex:1886: Plug.Conn.register_before_send/2
    (smalt 26.10.19) lib/smalt/egress_router.ex:1: Smalt.EgressRouter.plug_builder_call/2
    (bandit 1.13.1) lib/bandit/pipeline.ex:168: Bandit.Pipeline.call_plug!/2
    (bandit 1.13.1) lib/bandit/pipeline.ex:43: Bandit.Pipeline.run/5
    (bandit 1.13.1) lib/bandit/http1/handler.ex:23: Bandit.HTTP1.Handler.handle_data/3
    (thousand_island 1.6.0) lib/thousand_island/handler.ex:636: ...invoke_callback/2
```

Keepalive signature: `curl url url` shows the second GET silently re-Connecting —
the Bandit connection process died after the first /healthz. Also `https://` to 8443
is connection-reset (8443 is plain HTTP; TLS face is 9444 — probe-surface note).

### AFTER (fixed code, real Bandit + real :gen_tcp, private port 39485)

`mix run --no-start` boots ONLY Bandit with `{Smalt.EgressRouter, []}` on a private
port (the shared substrate holds the app ports). HealthPlug answers and halts before
any store dependency, so the no-app boot is a real pipeline witness, not a stub.
Four sequential requests over ONE :gen_tcp socket:

```
SAME_SOCKET status_line_1=HTTP/1.1 503 Service Unavailable   (GET /healthz)
SAME_SOCKET status_line_2=HTTP/1.1 200 OK                    (GET /healthz/live)
SAME_SOCKET status_line_3=HTTP/1.1 503 Service Unavailable   (GET /healthz)
SAME_SOCKET status_line_4=HTTP/1.1 503 Service Unavailable
CONNECTION_SURVIVED=true
AlreadySentError count in witness log: 0
```

(The 503 readiness is the correct structural verdict for a `--no-start` boot — no
data-plane stores are up; the 503/200 status mapping is pinned by the parity tests
below. The pre-fix behavior would have killed the socket after request 1.)

Witness script: /tmp/bk47_wire_witness.exs (scratch).

### Existing test files

```
$ MIX_BUILD_ROOT=_build-bk47 MIX_ENV=test mix test test/health_probe_parity_test.exs test/integration/healthz_cors_test.exs
→ 12 passed, 0 failures (exit 0)
```

## Lane hygiene

- Edits: `lib/smalt/apim.ex` (grouped init clauses + @impl true), `lib/smalt/health_plug.ex`
  (halt on all three send sites). Both swept into coordinator tick checkpoint
  f675cf5; this lane made no commits.
- Concurrent-lane churn witnessed, not touched: SyncRoutes.ex stray-`end` syntax
  error (owner removed it ~20:37), store.ex transient syntax error (owner fixed by
  20:39), both under the compile-freeze SLA. No unblock fixes applied by this lane.
- No shared-infra edits; substrate (pid 48942) left running, never restarted.
