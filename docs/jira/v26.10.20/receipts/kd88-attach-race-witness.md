# KD-88 cold-boot attach race — witness receipt (lane W13-H)

- **Standing: PARTIAL_ALIVE — KD-88 stays OPEN; row's suspected root REFUTED; end-to-end flake reproduced and root-caused to the client-pump cold-start path, with one new typed lead (`{:bad_frame_body, :truncated}`) and one robustness wart (Connection init `not_owner`). No register edit (no flip mandate).**
- Lane: W13-H (substrate-op), repo /Users/sac/smalt, 2026-10-20. No shared-substrate restart; all beams lane-private on 39590-39595, MIX_BUILD_ROOT=_build-w13h.
- Row: docs/jira/v26.10.14/KNOWN_DIVERGENCES.md KD-88 (EH checkpoint-store pump warm-up race, cold boot).

## What the task asked

Cold-boot the EH plane and attach immediately: does the attach hit a not-yet-ready
store/link and answer a **raw crash or wrong error instead of a typed not-ready**?

## Method

Scratch repro harness `tmp/w13h_kd88_cold_attach.mjs` (real @azure/event-hubs from
workspace/node_modules; checkpoint pump = SmaltBlobCheckpointStore; port-open poll at
100ms, attach with ZERO settle delay; per attempt a fresh beam + fresh hub + fresh
checkpoint container; anonymous AMQP SAS via real sb_shared_key):

    mix run --no-start --no-halt -e 'Application.put_env(:smalt, :auth_mode, :anonymous); ...Application.put_env(:smalt, :event_hubs_port, 39591); {:ok, _} = Application.ensure_all_started(:smalt)'

(5 runs, 33 cold boots total; two harness iterations discarded — dummy SAS key
INVALID_LOCAL_SAS 5×, then port-release timing 5×.)

## Witness 1 — the suspected beam-side "not-ready error" is REFUTED (clean bill on the task's question)

Every cold-boot attach, at every lateness (40ms..+30s after boot), was answered by the
beam with a correct attach echo and correct deliveries. In the stall attempt the
partition-1 receiver attached ~40ms after listener bound and was served CORRECTLY EMPTY
deliveries; the partition-0 attach when it finally came drained 20/20 instantly
(`deliver partition=.../partitions/0 after_seq=0 credit=3` → 20 deliveries, shim log
tmp/w13h_kd88_run3.log). No raw crash, no wrong error, no raw `:badarg` on any attach
path. Static audit agrees: every EH read goes through `EventHubs.receive_events/
last_enqueued` → `ensure_tables()` (tables created server-owned inside
`Smalt.Messaging.EventHubs.Server`, lib/smalt/messaging/event_hubs.ex:61-71,641-663);
`:smalt_eh_epochs` has a self-healing guarded create
(lib/smalt/messaging/amqp/connection.ex:1175-1184); the `$management` partition readout
ensures tables first (lib/smalt/messaging/amqp/management_rpc.ex:975).

## Witness 2 — the KD-88 flake reproduced (pump stall signature)

- run2 (no shim): attempt 2 — `seen=0/20 errors=[]`, beam log: partition-1 receiver
  tokened+attached 08.254, then 20s of NOTHING — partition-0 CBS token + receiver attach
  never sent by the client within the 20s window. Attempts 1,3-6: 20/20 in ~2.5-11.7s.
- run3 (SHIM-COURT diagnostic shim on connection.ex, restored byte-exact after,
  sha256 dec85d84…637 both sides): partition-1 attach 12.150, 20s gap, partition-0
  token 32.101 + attach 32.103 → drained 20 events immediately; deadline fired at 18/20.
- run5 att3: same stall; at +30.2s the beam logged
  `21:40:23.446 [warning] [amqp-conn] closing on {:bad_frame_body, :truncated}` — the
  consumer connection DIED on a client frame the codec reads as truncated
  (frame_codec.ex:554-562, PrimitiveCodec reports :truncated). Client perr=[] — the SDK
  surfaced nothing, pump never re-attached (harness maxRetries:0), 0/20.

Signature across runs: the SDK pump's partition-0 receiver (+ its CBS token) is not
sent for 20-30s on some cold boots, and when it eventually IS sent (run5 att3) the
frame can arrive as `{:bad_frame_body, :truncated}` → typed close → no re-attach. The
row's suspected "warm-up race in the deliver/$management attach path" is not the
mechanism: the deliver and $management paths are correct from the first accepted frame.

## Witness 3 — cross-lane disclosure: concurrent edit to connection.ex broke cold connects (not pre-existing smalt code)

Mid-campaign (21:39), a CONCURRENT lane landed an uncommitted edit to
lib/smalt/messaging/amqp/connection.ex adding `:gen_tcp.controlling_process(sock, self())`
to `init/1` (annotated KD-COVERS: KD-69, "socket-owner connection"). From the moment
that edit compiled (my run5 attempt 4, 21:40:41), EVERY cold connect failed
deterministically, 5/5:

    [warning] [amqp] could not start Smalt.Amqp.Connection for eh socket: {{:badmatch, {:error, :not_owner}}, [{Smalt.Amqp.Connection, :init, 1, ... line 88 ...}]}
    -> client sees raw ECONNRESET on every EH attach (run5 attempts 4-8)

Root: OTP requires the CALLER of `gen_tcp:controlling_process/2` to be the socket's
CURRENT owner (kernel-10.5 inet.erl tcp_controlling_process: `{connected, Pid} when
Pid =/= self() -> {error, not_owner}` — `self()` is the caller). The current owner is
the LISTENER process, not the connection process, so the call returns {error,
not_owner} and the `:ok =` badmatch kills init. The edit's own comment claims the
handoff is safe; it is not — the transfer must run in the LISTENER (or the child must
be spawned such that the listener performs the transfer), never as init's first socket
op from the non-owner side. Attempts 1-3 of run5 (pre-edit beam code) connected fine —
the regression is the edit, not the tree.

This is a compile-freeze-class hazard on a shared lib/ seam, disclosed here per the
same-checkout fanout law. Not my lane's file to repair without coordination; the
owning lane must call controlling_process in the listener before start_child, or drop
the transfer. My KD-88 witnesses 1-2 are unaffected (all stall evidence predates the
edit; the not_owner attempts never reached AMQP).

## Disposition

- KD-88 row: stays OPEN. Suspected root (beam warm-up race) REFUTED with witness;
  observed mechanism is client-pump cold-start stall, amplified in one run by a typed
  beam close on `{:bad_frame_body, :truncated}` (candidate new-KD lead for the
  registrar: rhea-frame the codec reads as truncated — needs client-side frame capture).
- Falsifier as currently worded ("20/20 first attempt zero retries") is client-bound:
  it cannot pass while the SDK pump itself cold-starts late. Registrar may re-word.
- No fix landed BY THIS LANE. My SHIM-COURT diagnostic shim was restored byte-exact
  at 21:38 (sha256 dec85d84a8f5e756a495398c56f6ab8db60d32f0707d3abca5237bdd606e0637,
  verified); the CURRENT diff on connection.ex belongs to the concurrent lane
  (Witness 3) and is theirs to repair. My lane owns only this receipt.
- No register edit, no git ops. Harness + logs (scratch): tmp/w13h_kd88_cold_attach.mjs,
  tmp/w13h_kd88_run2.log, tmp/w13h_kd88_run3.log (shim logs, SHIM-COURT marked),
  tmp/w13h_kd88_run5.log.
