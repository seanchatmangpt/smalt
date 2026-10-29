# OBS4COURT — AR-OBS-04 peer two-node court (OTP-29)

Context: solo

**Standing:** **ALIVE** (court file landed; 4/4 legs green, two consecutive runs, exit 0; epmd clean after teardown)

## Subject

- File (new): `test/integration/peer_two_node_court.exs` — `Smalt.Integration.PeerTwoNodeCourtTest`, tagged `:peer_two_node_court`
- Toolchain: Elixir 1.20.4-otp-29 / Erlang 29.1.2 (asdf, OTP-29 as mandated), `MIX_BUILD_ROOT=_build-obs4`, `MIX_ENV=test`
- Close condition: AR-OBS-04's missing peer testbed half — two ephemeral BEAM nodes over loopback distribution, real `:peer` + `:erpc`, no mocks.

## Faces and mechanics

- Runner node: `elixir --name peer_court_runner@127.0.0.1 --cookie smalt_peer_court -S mix test test/integration/peer_two_node_court.exs`
- Remote: `:peer.start_link(%{name: :peer_court_a, host: ~c"127.0.0.1", longnames: true, args: -pa(:code.get_path()) ++ -setcookie})` — linked to the runner ⇒ deterministic lifecycle (runner halt kills it).
- Remote boots a minimal Smalt faces subset: `Smalt.Store` + `PeerCourt.Health` (court-side helper compiled via `Code.compile_string/1`, shipped as beam binaries via `:erpc.call(node, :code, :load_binary, ...)`). Faces boot under a registered long-lived owner process — a `start_link` straight from the transient erpc worker would kill the faces when the worker exits after replying (witnessed as `:noproc` on the first cross-node health call).
- Runner node boots the full `:smalt` app under `mix test`, so `Smalt.Store` is real on BOTH sides — the reverse latency leg reads a runner-written row from the runner's own store face through remote→runner erpc.

## Court legs (all real transport, no sleeps-as-coordination)

- (a) faces boot + bidirectional erpc round-trip latency (µs, informational):

      [peer-court] faces subset UP on peer_court_a@127.0.0.1 (Smalt.Store + PeerCourt Health)
      [peer-court] forward erpc round-trip: 55 µs/op avg (n=100)
      [peer-court] reverse erpc round-trip calls: 106 µs (n=100)

  (second run: 83 / 165 µs; earlier run 58/107 µs — informational, no fence)

- (b) injected disconnect: caller blocked in a cross-node `GenServer.call` to the never-replying `:hold_open` (server stays responsive via noreply; entry is OBSERVED via the health call counter reaching ≥2, a bounded poll — not a sleep guess). `:peer.stop(pid)` mid-call ⇒

      [peer-court] injected disconnect -> typed {:error, {:node_down, :"peer_court_a@127.0.0.1"}}

- (c) teardown: `:peer.stop(pid)` kills the remote; bounded-poll assert: node not in `nodes()`, `net_adm.ping == :pang`, epmd name deregistered (`net_adm.names()` no longer lists `peer_court_a`); re-stop of the dead controller exits typed `:noproc` immediately — no hang. Post-run `epmd -names` clean:

      epmd: up and running on port 4369 with data:

- (d) partition simulation, opaque + monitor-based (no firewall): `:erlang.monitor_node(node, true)` + `:erlang.disconnect_node/1` ⇒ `{:nodedown, node}` observed within 5 s deadline; `erpc` during partition fails typed `{:error, {:node_down, node}}` (Elixir surfaces erpc failures as `%ErlangError{original: {:erpc, :noconnection}}` — the court normalizes to the typed tuple); epmd name free; distribution recovery proven by booting a fresh peer under the same node name (health face answers again). Peer-lifecycle fact pinned: a `:peer` child is connection-bound — `disconnect_node` halts it — so "reconnect" is fresh-peer recovery, not link restoration to the same OS process.

## Command + output (final run, exit 0)

    $ MIX_BUILD_ROOT=_build-obs4 MIX_ENV=test elixir --name peer_court_runner@127.0.0.1 --cookie smalt_peer_court -S mix test test/integration/peer_two_node_court.exs
    ...
    Finished in 1.2 seconds
    Result: 4 passed

## Verification ladder + non-vacuity

- Two consecutive full-green runs (run 11 and run 12 logs, `/tmp/peer_court_run11.log`, `/tmp/peer_court_run12.log`), different ExUnit seeds.
- Loud-skip contract: undistributed runner ⇒ stderr `[peer-court] SKIP (loud)` + module exit — skip is loud, never a fake pass.
- No-sleep law: single `Process.sleep(5)` inside `poll_until/3`, annotated `# SLEEP-CLASS: POLL-STEP`; `just sleep-gate` reports zero FAILs for this file (the gate's FAILs are another lane's pre-existing `test/internal/impl6_process_label_test.exs` — pre-existing, not session-introduced).
- Named-port free asserted twice (leg c and leg d), `epmd -names` clean at end of run.

## Typed failures witnessed during bring-up (all fixed forward)

1. Calling `Health.health/0` directly via erpc — the health face is a GenServer; calls must ride `GenServer.call({Name, Node}, ...)` (`:undef` otherwise).
2. `{Name, node()}` built in the erpc args evaluates `node()` on the caller's side — must be built with the target node explicitly.
3. `:peer.stop(Node)` on a `start_link` controller exits `:noproc` on this toolchain; stopping by controller PID is lawful. Re-stop of a dead controller exits `:noproc` (typed, immediate).
4. `start_link` from the transient erpc worker links the booted faces to it (witnessed `:noproc` after boot returned) — faces need a long-lived owner.
5. `disconnect_node` on a peer child = permanent child halt (connection-bound lifecycle), monitor message is `{:nodedown, node}` (lowercase) from `erlang:monitor_node/2`.
6. erpc failures surface in Elixir as `%ErlangError{original: {:erpc, :noconnection}}`, not raw `{:erpc, _}` exits.

## Standing caveats

- Distribution flags go to elixir BEFORE `-S mix ...` (`elixir --name ... -S mix test ...`); `mix run script --name x` passes them to the script — witnessed dead-end during bring-up.
- Latency numbers are informational (no fence); reverse leg ≈ 2x forward (two hops remote→runner→remote).
- Runner needs loopback distribution + epmd; the court asserts named-port freed at teardown so it is lane-safe.
