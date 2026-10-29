# KD-69 Falsifier Witness — EH exclusive-receiver epoch enforcement (W13-A)

- **Date**: 2026-10-20
- **Lane**: W13-A (continuation; prior run died on API 429 after substrate-up + code read)
- **Subject**: `lib/smalt/messaging/amqp/connection.ex` epoch enforcement —
  `eh_attach_epoch/1` (attach properties, symbol key `com.microsoft:epoch`),
  `eh_epoch_admit/3`, `EPOCH_EVICTION` / `EPOCH_REFUSED` detaches
  (GAP-A2-02 / KD-69)
- **Substrate**: live smalt substrate, beam pid 1835, EH plane 127.0.0.1:5673
  listening (lsof witnessed). Never restarted. Host toolchain: Elixir 1.19.5 /
  OTP 28 (`elixir --version`: "Elixir 1.19.5 (compiled with Erlang/OTP 28)").
- **Machine** (`just bench-machine`):
  `{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}`
- **Method**: Chicago — real wire, real substrate, hand-rolled minimal AMQP 1.0
  client (`:gen_tcp`, SASL ANONYMOUS, sasl-outcome 0x44) reusing the codec
  shapes from `popcorn_demo/lib/popcorn_demo/live_eh.ex`; no mocks, no smalt
  process-side instrumentation. Scripts (scratch, /tmp):
  - `/tmp/kd69_falsifier.exs` — 3-connection falsifier (faces 1–3)
  - `/tmp/kd69_discrim.exs` — registry-transfer discriminator + activity-flush probe
  - `/tmp/kd69_sameconn.exs` — same-connection eviction isolation probe
- **Epoch wire field**: map entry in the attach `properties` field:
  `{"com.microsoft:epoch": <long>}` (encoded 0xC1 map, 0xA3 sym8 key,
  0x81 long64 value).

## Faces (task contract) and verdicts

### Face 1 — attach receiver A, epoch N — PASS

A ("kd69-A") attached on `/eventhubs/popcorn-eh/Partitions/0`-shaped source
`/eventhubs/popcorn-eh/partitions/0` with epoch 7; attach echo (0x12) received;
no detach within 500 ms drain.

Verbatim: `face1_a_attach: {:ok, "A attached epoch=7, no detach within 500ms"}`

### Face 2 — B epoch N+1 must evict A — FAIL (falsifier FIRED — defect witnessed)

B ("kd69-B") attached same source, epoch 8. Registry transfer WORKS: a
follow-up attach D with epoch 7 was refused `EPOCH_REFUSED: active epoch 7`
(reported epoch = the refused link's own epoch value 7; refusal requires an
incumbent with epoch > 7, i.e. B's 8 owns the registry).

But A NEVER received the typed `EPOCH_EVICTION` detach while idle:

```
A-detach-before-activity: {:error, :no_detach}   (3s window)
D(epoch 7)-after-B: {:refused, ... "EPOCH_REFUSED: active epoch 7" ...}
```

Mechanism (itself wire-proven by prediction test): A's Connection process
blocks in `:gen_tcp.recv(sock, want, idle_timeout)` inside
`handle_info(:recv)` (connection.ex:101, :328); the cross-connection
`send(old_pid, {:eh_epoch_evict, ch, handle, error})`
(connection.ex:1253-ish, the `old_pid == self()` else-branch of
`eh_epoch_admit/3`) sits in A's mailbox unprocessed until A's client next
sends bytes. Prediction test — after B's evict, A sends a flow frame; the
typed detach flushes immediately:

```
A-detach-after-flow: {:detached_after_flow,
  <<192, 71, 3, 67, ...>>  # detach, error: com.microsoft:epoch-lock-lost,
                           # "EPOCH_EVICTION: active epoch 7"
}
```

So for an idle incumbent the eviction detach is deferred indefinitely (until
client activity or idle-timeout close with `amqp:resource-limit-exceeded`) —
exactly the channel real EH exclusive-receiver semantics close. Two live
receivers on one partition is the observable state in that window, which is
the divergence the KD-69 falsifier was designed to catch.

### Face 3 — stale epoch refused — PASS

C ("kd69-C") attach epoch 6 (stale vs incumbent 8): attach echo first, then
typed detach, both witnessed on the wire (rhea-order respected):

```
face3_c_stale_refused: {:ok, "C refused: attach echoed then detach EPOCH_REFUSED (72B)"}
```

Detach bytes carry `com.microsoft:epoch-lock-lost` +
`EPOCH_REFUSED: active epoch 6`.

## Isolation probes

- **Same-connection eviction WORKS**: A h=0 epoch 7, then h=1 epoch 8 on the
  SAME connection → h=0 received typed detach
  `EPOCH_EVICTION: active epoch 7` (73B; verbatim bytes:
  `163, 29, "com.microsoft:epoch-lock-lost"`, `161, 30, "EPOCH_EVICTION: active epoch 7"`).
  The `old_pid == self()` branch is sound because the same process handles the
  new attach and sends the detach inline.
- **Discriminator**: D epoch 7 after A(7)→B(8) refused → registry correctly
  moved to B-8; the transfer itself is not the defect.

## Verdict

**Falsifier FIRED on face 2 (cross-connection eviction detach delivery).**
Faces 1 and 3 hold on the wire. The epoch registry, refusal face, and
same-connection eviction are ALIVE; the cross-connection eviction detach to an
IDLE incumbent is deferred-until-activity (or lost to idle-timeout close) —
the kernel of the divergence: two live receivers on one partition coexist.

Named gap: cross-connection epoch eviction detach is only delivered when the
incumbent's client next sends a frame; an idle incumbent never gets it.

### Repair shape (for the fix lane, not landed here)

The `:recv` pump must not be a blocking recv that holds the process for the
full idle window: pump with a short recv timeout (or `active: true`/
`active: once` + `handle_info({:tcp, ...})`) so the mailbox is serviced
between bytes — `{:eh_epoch_evict, ...}` then flushes promptly without
touching the wire path.

### Boundary

- Cross-connection face tested at the wire only (no process-side tracing of
  A's mailbox); the mechanism claim is supported by the successful
  flow-flush prediction, not by tracing.
- Client-side: hand-rolled codec; attaches mirrored live_eh shapes verified
  against this substrate by prior receipted legs.

## Scratch files

- `/tmp/kd69_falsifier.exs`, `/tmp/kd69_discrim.exs`, `/tmp/kd69_sameconn.exs`
- No lib edits, no git actions, no register flip. KD-69 row untouched.

## Standing

**Standing:** ALIVE (falsifier FIRED on face 2 — the cross-connection epoch-eviction detach defect is witnessed live on the wire, embedded verbatim; faces 1/3 hold; no lib edits, register untouched)
