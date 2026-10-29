# KD-69 fix witness — cross-connection epoch-eviction detach now delivered to an idle incumbent

**Standing:** **ALIVE** (fix landed, live-wire witness on a private beam; live-substrate flip needs the next recycle)

- Subject: `lib/smalt/messaging/amqp/connection.ex` (sha256 `719737136f42a0869018073284d43082ebb7c3964dd767120204106ce036d4fa`)
- Lane: W14-A, repo `/Users/sac/smalt`, `MIX_BUILD_ROOT=_build-w14a`
- Date: 2026-10-20

## Defect

`eh_epoch_admit/3` (KD-69 / GAP-A2-02) asks the incumbent's connection to detach
via `send(old_pid, {:eh_epoch_evict, ...})`, but `handle_info(:recv)` parked the
GenServer inside a blocking `:gen_tcp.recv(sock, want, timeout)` for the FULL
pre-open/idle window (up to 300s). The typed detach sat in the idle incumbent's
mailbox until its client next sent bytes — exactly what W13-A2's discriminator
witnessed (detach only after a client flow frame).

## Fix (short-recv mailbox-servicing pump, connection.ex only)

- `need_more/2` no longer blocks for the full window: it waits in 100ms
  `:gen_tcp.recv` slices under a per-await deadline (pre-open 5s / post-open
  negotiated idle clamp table unchanged, R3 slowloris clamps preserved; expiry
  mirrors the old `{:closed, state}` handling exactly).
- Between slices, `pump_drain/1` performs a SELECTIVE receive matching only
  `{:eh_epoch_evict, ...}` / `{:azb07_force_partition_detach, ...}` — no
  catch-all, so system messages and `:recv` are never stolen. On a match the
  message is requeued to the mailbox tail and the pump yields
  (`{:requeued, state}`), so the GenServer dispatches it against the LATEST
  state (no forked state); the handle_info clauses resume the pump via
  `send(self(), :recv)`.
- KD-COVERS: KD-69 markers on the changed lines.
- New state field `recv_deadline` (per-await deadline).
- Diff: 91 insertions, 17 deletions (plus a moduledoc line update).

## Witness

BEFORE (live shared substrate, old code, 2026-10-20 21:36):
```
KD69-RESULT: %{
  face1_a_attach: {:ok, "A attached epoch=7, no detach within 500ms"},
  face2_b_evicts_a: {:fail, {:no_detach_on_a, "{:error, :no_detach}"}},
  face3_c_stale_refused: {:ok, "C refused: attach echoed then detach EPOCH_REFUSED (72B)"}
}
KD69-VERDICT: BEFORE-FAIL (face 2)
```
Discriminator BEFORE: `A-detach-before-activity: {:error, :no_detach}`;
`A-detach-after-flow: {:detached_after_flow, ...}` (the mailbox-stuck mechanism);
`D(epoch 7)-after-B: {:refused, ...}` (B-8 took the registry).

AFTER (private beam, alt ports 15672/15673/19443/19444/18443/19545,
MIX_BUILD_ROOT=_build-w14a, cold boots witnessed):
```
KD69-RESULT: %{
  face1_a_attach: {:ok, "A attached epoch=7, no detach within 500ms"},
  face2_b_evicts_a: {:ok, "A evicted: detach error carries epoch-lock-lost + EPOCH_EVICTION (73B)"},
  face3_c_stale_refused: {:ok, "C refused: attach echoed then detach EPOCH_REFUSED (72B)"}
}
KD69-VERDICT: PASS  (3/3 consecutive runs)
```
Discriminator AFTER: `A-detach-before-activity: {:detached, ...}` — the typed
`com.microsoft:epoch-lock-lost` + `EPOCH_EVICTION` detach delivered WITHOUT the
incumbent sending first (the named witness). `D(epoch 7)-after-B: {:refused,...}`
(B-8 registered). Cold connect (full SASL/open/attach) passes on every falsifier
run (6+ cold connects across runs; no `:not_owner`, no ECONNRESET — W13-H's
cold-attach concern does not apply: no socket opts or ownership change was kept).

## Abandoned form (disclosed)

`active: :once` + `:gen_tcp.controlling_process(sock, self())` in `init/1` was
implemented, compiled, and REFUTED on the wire: `{:error, :not_owner}` at init
(the listener never transfers ownership) and the listener would swallow armed
`{:tcp,...}` messages. Reverted to HEAD before landing the short-recv design;
coordinator/W13-H's cold-connect correction arrived mid-lane and is satisfied by
the reverted state.

## Regression tier

- `mix test` (full offline suite, _build-w14a): 186 tests, 9 failures — A/B
  against HEAD connection.ex on the failing subset: 8 of 9 reproduce on the
  BASELINE (cluster net_kernel/epmd, cosmos TTL + census — other lanes'
  in-flight edits/environment). AMQP surface green (plane_blast_radius +
  eh_arm + sb_topic_fanout: 19/19; eh_arm + eh_geo_dr + consumer_groups: 22/22;
  kv_ec_create: 5/5).
- Pre-existing warning (clause-grouping on handle_info/2) unchanged from HEAD.

## Notes / disclosures

- A derived probe copy `/tmp/w14a_kd69_falsifier.exs` (port override via
  `KD69_PORT` env) fixed a latent probe bug (`{:detached, body, _} = a_check`
  3-tuple destructure of a 2-tuple) that only fired once face 2 passed; the
  original W13-A2 probe under /tmp is unmodified.
- The other lane's SHIM-COURT KD-88 diagnostic lines in connection.ex were
  removed by their owner mid-lane (witnessed: grep 0); my final diff contains
  no KD-88 content.
- Live-substrate flip: the shared substrate (pid 1835/beam 62236) still runs
  the old pump; the fix takes effect on its next recycle. The private witness
  beam was torn down; shared substrate untouched.

Commands: `MIX_BUILD_ROOT=_build-w14a mix compile` (clean);
`KD69_PORT=15673 MIX_BUILD_ROOT=_build-w14a mix run --no-start /tmp/w14a_kd69_falsifier.exs`;
`... /tmp/w14a_kd69_discrim.exs`; `MIX_BUILD_ROOT=_build-w14a mix test`.
