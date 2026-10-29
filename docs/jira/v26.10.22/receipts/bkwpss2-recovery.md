# Receipt — BK-WPSS2: Web PubSub restart-recovery semantics + hardening-note disposition

**Standing**: ALIVE
**Context**: solo
**Date**: 2026-10-22 · Lane: BK-WPSS2 · Repo: `/Users/sac/smalt`
**Closes**: residual notes (a)/(b) from BK-WPSSKEP + BK-WPS1

## (1) Restart-recovery contract — witnessed (real supervised crash, no mocks)

Probe `/tmp/bkwpss2_recovery.exs` (`mix run --no-start`, build root
`_build-bkwpss2`, real `Supervisor` one-for-one over `Smalt.WebPubSub`, real
`Process.exit(pid, :kill)` — no mocks):

```
broker pid1 = #PID<0.546.0>
PRE-RESTART members=[#PID<0.94.0>] events=[%{"delivered" => nil, "delivery_status" => "pending", "id" => "ev-1", "type" => "connect"}]
broker pid2 = #PID<0.547.0> (restarted=true)
POST-RESTART members(chathub,g) = []
POST-RESTART events = []
POST-RESTART publish -> {:ok, 0}
POST-RESTART rejoin -> :ok, members=[#PID<0.94.0>]
PASS restart happened (new pid, alive)
PASS groups wiped (members [])
PASS witness buffer wiped (events [])
PASS publish after restart delivers 0
PASS rejoin works post-restart
ALL PASS
```

(exit 0. Pre-restart state was populated via real `join/3` from a live client
process and a real `{:record_event, ...}` cast.)

**Recovery contract (typed)**:

- Broker state is **in-memory only** (`service.ex:60` init →
  `%{groups: %{}, events: :queue.new()}`; no DETS/ETS persistence). Any crash
  restart wipes BOTH the groups registry AND the witness buffer. Witnessed
  5/5: restart → new pid, `members/2` → `[]`, `events/0` → `[]`,
  `publish/3` → `{:ok, 0}` (honest 0-delivered, never an error), rejoin →
  `:ok` with membership restored on the same client pid.
- **Clients must rejoin after any broker restart.** Rejoin is a plain
  `join/3`, works first-try post-restart.
- **BK-WPSS2-N1 (LOW, contract property — no repair required)**: the wipe is
  silent to connected clients. Client WebSockets ride the Bandit child
  (separate supervision, `data_supervisor.ex`), so on broker restart
  connected clients get NO disconnect, error frame, or any signal — they
  stop receiving group pushes (publish delivers to 0) until they rejoin by
  other means. Real Azure Web PubSub drops the connections themselves on a
  service restart, forcing reconnect+rejoin; the emulator instead keeps
  sockets alive over dead membership. Typed as a contract property of an
  in-memory emulator, not a defect: no crash, and publish honestly reports
  `{:ok, 0}`. The socket-survival divergence is now register-typed here.

## (2) Hardening notes from BK-WPSSKEP — disposition

### (a) no-exp server Bearer admits (joken absent-claim skip) — NOT-A-DEFECT

`router.ex:141-157` (`check_authorization/2`, Bearer leg) validates `aud` and
`exp` via Joken, which skips absent claims — a signature-valid JWT with no
`exp` (or no `aud`) admits. **Reachability: not reachable by a non-key-holder.**
The gate signs with HS256 + the access key (`router.ex:142`); producing a
signature-valid token REQUIRES the access key. Any token that reaches the
absent-claim skip is by construction minted by a key holder — same trust
domain, no bypass, no ticket. Cross-checked against current disk truth
(`router.ex` unchanged); the kd169r court pins `no-exp Bearer ADMITS` as the
expected admit, so flipping it is NOT a trivial hardening — it edits another
lane's pinned court leg (out of this lane's lease).

### (b) Bearer `aud` bound to client-supplied Host — NOT-A-DEFECT

`router.ex:146`: `aud` must equal `"https://" <> host_port(conn)` and
`host_port/1` reads the request `Host` header — a key holder can pick their
own audience. But the signature check is the trust boundary: a non-key-holder's
token fails signature verification regardless of `aud`. Host-controlled
audience is reachable only inside the trust domain that already holds the key.
Hardening idea (pin `aud` to the configured endpoint rather than the request
Host) noted for a future lane — NOT-A-DEFECT today.

## (3) Fresh WPS suites

```bash
MIX_BUILD_ROOT=_build-bkwpss2 bash scripts/fast_test.sh \
  test/internal/expl11r2_wps_service_events_court_test.exs \
  test/internal/wps_exp4_court_test.exs \
  test/internal/kd169r_cred_gate_test.exs \
  test/internal/webpubsub_test.exs \
  test/internal/expl11r_court_test.exs \
  test/internal/expl11r3_court_test.exs
```

```
Finished in 16.7 seconds (0.00s async, 16.7s sync)
Result: 40 passed          (exit 0, 06:34:51Z 2026-10-22, wall 41s)
```

Same 6-file set as BK-WPS1's receipt, fresh this session.

## Files

- `docs/jira/v26.10.22/receipts/bkwpss2-recovery.md` — this receipt (only file this lane writes).
- No `lib/` or `test/` edit. Probe script `/tmp/bkwpss2_recovery.exs` (scratch, not a repo file).
