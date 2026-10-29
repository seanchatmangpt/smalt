# BK-POL — load-dependent `:not_alive` flake cluster repair (bounded Poll start-retry)

Standing: ALIVE
Context: solo
Build root: `_build-bkpol`
Date: 2026-10-22
Owner lane: BK-POL (repo /Users/sac/smalt)

## Verdict

The peer-court `:not_alive` cluster registered in `bknsp-ensure-loaded.md`
(failures at peer_two_node_court_test.exs:132 / swarm_court_test.exs:142 —
`{:error, :not_alive}` / `:peer.start_it/2` timeout under batch load, 2/3
loaded in-batch runs) is closed. The one-shot `:peer.start_link/:peer.start`
+ immediate face-boot handshake raced epmd registration / remote boot exactly
when the machine was loaded. Both courts now start peers via the one audited
poll implementation (`SmaltTest.Internal.Poll.eventually/2` — required from
`test/internal/poll_helper.exs`), retrying on the real observable (peer up +
faces answering) with a `:peer.stop` of the half-booted peer on partial
failure so the retry starts from a clean epmd name. Same class and idiom as
the BK-GWS7V gate-6 fix (bounded poll on actual convergence, not one-shots).

Contract unchanged: no mocks, real `:peer` nodes, real erpc face calls, legs
verbatim; only the start handshake is now convergence-polling.

## Change shape (both files)

```elixir
case SmaltTest.Internal.Poll.eventually(fn -> try_start_x(args) end,
       timeout_ms: @poll_timeout, poll_ms: 100) do
  {:ok, {pid, node}} -> {:ok, pid, node}
  {:timeout, last} -> raise "... start never converged: #{inspect(last)}"
end
```

with `try_start_x` returning `{:ok, {pid, node}}` on full convergence
(start + beam shipping + `boot_faces`), `{:error, reason}` on a failed start
(Poll retries), and `:peer.stop(pid)` + `{:error, {:boot_faces, other}}` on a
partial start (faces not loadable) so the retry gets a clean epmd name.

## Seam-collision disclosure (same-checkout fan-out)

BK-ARM3 held a concurrent name-free window on
`test/integration/swarm_court_test.exs` (its crash-leg conversion + the
`swarm_a/b/c@127.0.0.1` names) while BK-POL held the same file. Serialized
per coordinator: BK-POL's start-retry fix landed via coordinator tick
checkpoint (8c587c7c); BK-POL removed the now-unused `alias SmaltTest.
Internal.Poll` (file uses the fully-qualified call); ALL swarm-court falsifier
runs deferred until BK-ARM3's conversion landed. BK-ARM3 also disclosed
unblock fixes in `lib/smalt/cluster.ex` (stray `schedule_next/1`) — untouched
here. BK-POL reaped its own leaked peer beams (exact PID) after the
UndefinedFunctionError runs and witnessed epmd clean (`net_adm:names() ->
{ok,[]}`).

## Embedded runs

Build root `_build-bkpol`; distributed runner (courts exclude on a
non-distributed runner — `test/test_helper.exs`).

### Peer court standalone (falsifier leg), 3/3 green, zero :not_alive

```
MIX_BUILD_ROOT=_build-bkpol elixir --name bkpol<N>@127.0.0.1 --cookie smalt_peer_court \
  -S mix test test/integration/peer_two_node_court_test.exs --include peer_two_node_court
run 1 exit=0 -> Result: 4 passed
run 2 exit=0 -> Result: 4 passed
run 3 exit=0 -> Result: 4 passed
```

### Swarm court standalone (pre-BK-ARM3-conversion snapshot, honest 6/8)

```
MIX_BUILD_ROOT=_build-bkpol elixir --name bkpols<N>@127.0.0.1 --cookie smalt_swarm_court \
  -S mix test test/integration/swarm_court_test.exs --include swarm_court
run 1: 6/8 passed, exit 2 — 2 kind-context (kc) leg failures
run 2: 6/8 passed, exit 2 — same 2
run 3: 6/8 passed, exit 2 — same 2
```

The 2 failures are the BK-ARM3-owned kc legs (kind-context drift,
`container not found` writing `bkarm3-kc2-carry` carry keys via kubectl exec;
typed in commit 7ddd08a7: "swarm court 6/8 (host+k legs green, kc legs are
BK-ARM3 in-flight, kind-context drift)"). ZERO `:not_alive` failures in any
run: every host-side start leg (setup_all 3-peer boot, reboot_peer, leg-d
fresh-peer recovery) converged through the new Poll-retry start. The failure
mode the fix targets is absent; the residual 2 are outside this lane's
ownership.

[POST-CONVERSION RUNS — PENDING BK-ARM3 LANDING]

## Falsifier status

- [x] Peer standalone 3/3 green, zero :not_alive
- [ ] In-batch 5/5 green (mix test test/integration, distributed runner,
      both court tags included) — deferred on BK-ARM3 seam, pending
- [ ] One run under artificial CPU load — pending
- [x] Residual 2 kc-leg failures typed BK-ARM3-owned (pre-existing, disclosed
      7ddd08a7), not session-introduced
