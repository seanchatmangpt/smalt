# Draft: AMQP test-lane sleep/timing/singleton rewrite — five test files

Status: DRAFT (frozen tree; no edits, no git)
Window: v26.10.18
Files in scope (absolute, one canonical checkout):

- `/Users/sac/smalt/test/amqp/fuzz_test.exs`
- `/Users/sac/smalt/test/amqp/broker_facade_test.exs`
- `/Users/sac/smalt/test/amqp/flow_credit_test.exs`
- `/Users/sac/smalt/test/amqp/queue_store_test.exs`
- `/Users/sac/smalt/test/amqp/event_hubs_test.exs`

Primitives used: `SmaltTest.AssertEventually.eventually/2` (draft of record:
`docs/jira/v26.10.18/rewrite-drafts/assert-eventually.ex.md`), `start_supervised!/1`
per-test ownership, message/monitor-based sync, relative-ratio fences, structural
asserts over measurement windows.

## Method note: regression math

Three classes, three treatments:

1. **Authored-state replaces wall-clock waits.** A `Process.sleep(n)` before an
   assert carries a race window of width n: the pass probability is
   `P(settle) = 1 - P(jitter > n)`, strictly < 1 on a loaded fleet, and the
   only fix is inflating n (slower AND still < 1). Authored state (write the
   expired `until` / backdated `locked_until` directly, or use
   `:sys.suspend/1` to park the racer) has a **zero-width window**: the flake
   term vanishes instead of shrinking. This is the standard already proven in
   this tree — broker_facade's claim-GC test comment ("the state IS the
   contract, not a wall-clock wait") and queue_store's backdated
   `locked_until` sweeps.
2. **Message-based sync replaces silence windows.** A negative claim over a
   socket ("no transfer arrives") sampled for a fixed 1000 ms is a measurement,
   not a law. The rewrite converts it to a happens-before claim: the broker
   serializes frames per AMQP session (spec §2.5), so a client-issued
   `flow(echo: true)` reply is a barrier — every delivery the broker was going
   to make under earlier credit must precede it. Observed-then-ordered beats
   waited-and-hoped; the residual bounded recv keeps `@recv_timeout` as a
   fail-safe only (fires on hang, never on load).
3. **Relative ratios replace absolute ms.** Calibration already measured in
   this file (fuzz_test): bare-array decode clean ratio measured <= 1.3
   (array often faster than list — no per-element ctor dispatch), the
   quadratic mutant 22.9..36.1 (55x CPU), bound 3.0 (2.3x over clean, 7.6x
   under mutant); map single-pass ~1.12 vs probe-then-retry ~1.7, bound 1.4.
   Any NEW performance fence must be paired same-run min-of-N with the bound
   set by that geometry; no new absolute-ms bound is introduced anywhere in
   this draft.

## Pinned pinions — NOT touched (contract law, receipted)

Every rewrite below preserves these; none is classified as flake debris:

- **SASL ANONYMOUS only** — `flow_credit_test.handshake/1`
  (`{:sasl_init, %{mechanism: "ANONYMOUS"}}`), `event_hubs_test.wh/1`.
- **Attach arity tripwire (<= 14, locale fields omitted)** — fuzz_test
  `@perf_orders[:attach]` is exactly the 14-field order (source=8/target=7
  composite shapes ride the dedicated fences); the differential fuzz IS the
  tripwire's executor.
- **Fixed EH partitions `["0","1"]`** — r200h pk-hash tests, out-of-pin
  typed-detach refusal, the partition-`"1"` isolation comment (ann-hub test).
- **Drain no-op pin** — flow_credit test 5 pins the landed no-drain-echo
  behavior honestly; rewrite keeps the pin, changes only how silence is
  observed.
- **Flat-1000 sender credit pin** — flow_credit test 4 (`assert credit == 1000`).
- **Frame-size cap asymmetry pin** — fuzz_test lens-4 (encode unbounded,
  decode refuses > 1 MiB+512) — kept verbatim.

---

## 1. `/Users/sac/smalt/test/amqp/fuzz_test.exs`

Verdict: **nearest to clean of the five.** Deterministic seeds, structural
asserts, relative fences already in place. Remaining items:

| Item | Site | Class | Treatment |
|---|---|---|---|
| `Task.await(..., 30_000)` hostile-nesting probes | lens-4 deep-nesting tests (x2) | fail-safe deadline | KEEP (see 1.1) |
| millisecond-granularity ratio legs | bare-array + map fences | timing precision | TIGHTEN (see 1.2) |
| `:persistent_term` counters | module-wide | shared state | KEEP — single-module keyed, exact-count asserted |

### 1.1 Hostile-nesting `Task.await/2` 30 s — retained fail-safe

The 30 s bound gates a decode that either completes in microseconds or hangs
(the contained-exhaustion path returns tagged). It is not a settle-wait: the
success path never approaches it, so it has no flake channel — inflating or
deflating it changes nothing observable except hang latency. Absolute-bound
ban applies to bounds that SAMPLE behavior; this one only fences a hang.
Keep, with a one-line comment stating the fail-safe role so a future lens
does not "fix" it into a ratio.

### 1.2 Ratio-leg precision: `System.monotonic_time(:millisecond)` -> microsecond legs

The fences are already relative (correct form). Residual noise source: legs
timed in whole ms. A list leg measured 1..2 ms makes the ratio step 2x on a
one-tick difference. Draft: time with `:erlang.monotonic_time/1` native or
`:timer.tc/1` (microseconds) and keep everything else identical — paired
rounds, min-of-5, same bounds (3.0 / 1.4) until re-measured.

```elixir
timed_us = fn b, f ->
  {us, _} = :timer.tc(fn -> f.(b) end)
  us
end

ratio =
  for _ <- 1..5 do
    timed_us.(bin, map_f) / timed_us.(lis, list_f)
  end
  |> Enum.min()
```

Strengthened vs removed: nothing removed; precision of the existing fence
raised (ms legs -> us legs). Regression math: same measured geometry, noise
floor drops from ±1 ms to ±1 us per leg, so the bound stays valid without
re-derivation (min-of-5 of paired rounds already sheds co-monotonic load
jitter).

---

## 2. `/Users/sac/smalt/test/amqp/broker_facade_test.exs`

| Item | Site | Class | Treatment |
|---|---|---|---|
| `Process.sleep(50)` after client-churn close | Listener churn test | fixed sleep | REMOVE — monitor/structural (2.1) |
| `Process.sleep(50)` after `Process.exit(conn_pid, :kill)` | ConnSup handoff test | fixed sleep | REMOVE — `Process.monitor` (2.2) |
| `wait_until/2` (50 tries x 20 ms, count-bounded) | module helper | attempt-bounded poll | REPLACE with `AssertEventually.eventually/2` (2.3) |
| shared named `Sweeper` singleton | Sweeper describe | shared singleton | OWN or PARK per test (2.4) |
| stop-and-restart race in tick_ms refusal test | R132 test | restart race | REPLACE with suspend + owned instance (2.5) |

### 2.1 Churn test: drop `Process.sleep(50)`

Current shape asserts `Process.alive?(pid)` after a 50 ms settle. The sleep
buys nothing: liveness-after-close is proven by the NEXT assertion in the same
test — a fresh `:gen_tcp.connect/3` succeeding, which is only possible if the
acceptor loop never died. Rewrite:

```elixir
socks = for _ <- 1..3, do: tcp_connect!(port)
Enum.each(socks, &:gen_tcp.close/1)

# Survival is proven structurally: the acceptor must still hand out a fresh
# connection. No settle sleep — a dead acceptor fails the connect below, and
# a live one passes with zero race window.
assert match?({:ok, _}, :gen_tcp.connect(~c"127.0.0.1", port, [:binary], 1_000))
assert Process.alive?(pid)
GenServer.stop(pid)
```

Strengthened: the alive-check now sits AFTER the structural proof (an accept)
instead of after a blind wait; removed: the 50 ms sleep (zero informational
content — it sampled nothing).

### 2.2 ConnSup handoff test: kill observed via monitor, not sleep

```elixir
ref = Process.monitor(conn_pid)
Process.exit(conn_pid, :kill)

assert_receive {:DOWN, ^ref, :process, ^conn_pid, _}, 1_000

assert Process.alive?(pid)
assert Process.alive?(Process.whereis(Smalt.AmqpBroker.ConnSup))
assert match?({:ok, _}, :gen_tcp.connect(~c"127.0.0.1", port, [:binary], 1_000))
```

Strengthened: the DOWN message is the actual death event, not a 50 ms guess
at it; the test can no longer pass by the connection dying slowly nor flake
by it dying fast. Removed: `Process.sleep(50)`.

### 2.3 `wait_until/2` -> `AssertEventually.eventually/2`

The helper is count-bounded (50 x 20 ms = 1000 ms wall budget only under
zero load). Deadline-bounded is strictly stronger under load. All call sites
become:

```elixir
AssertEventually.eventually(
  fn ->
    children = DynamicSupervisor.which_children(conn_sup)

    case Enum.find(children, fn {_, pid, _, _} -> is_pid(pid) and pid != :undefined end) do
      {_, pid, _, _} -> {:ok, pid}
      nil -> :retry
    end
  end,
  observable: "Connection child appears under ConnSup",
  deadline_ms: 5_000
)
```

The tick_ms-refusal call site returns `nil` to mean retry today; rewrite to
`:retry` per the primitive's contract. The module-local `wait_until/2` is
deleted (dead helper, ERRC reduction).

### 2.4 Sweeper singleton: park, don't share

The run_pass test already found the right shape: own-or-park. Generalize it
to a `setup` helper so every Sweeper test gets a deterministic background
tick without stop/restart races:

```elixir
defp own_sweeper!(tick_ms) do
  case GenServer.whereis(Sweeper) do
    nil ->
      start_supervised!(Sweeper)

    pid ->
      # Shared instance: park its background tick for the test window. A
      # suspended GenServer still answers run_pass/0 calls (they are plain
      # functions/gencalls) but never ticks. Resume is on_exit-safe.
      :sys.suspend(pid)
      on_exit(fn -> :sys.resume(pid) end)
      pid
  end
end
```

For tests needing a SPECIFIC tick (the 20 ms setup), start a fresh instance
under the test supervisor instead of mutating shared env:

```elixir
setup do
  Application.put_env(:smalt, :amqp_sweeper_tick_ms, 20)
  on_exit(fn -> Application.delete_env(:smalt, :amqp_sweeper_tick_ms) end)
  EventHubs.ensure_tables()
  SmaltTest.Lifecycle.ensure_store_up()
  :ok
end
```

env write stays (init reads it) but the stop-the-shared-instance dance in the
GC test (2.5's sibling) is replaced by the suspend park.

### 2.5 Claim-GC test: suspend replaces the 1-hour-tick restart

Current shape: re-write env to 3_600_000, `GenServer.stop` the shared
Sweeper, wait for the supervisor restart to re-read env. Two races (restart
wins the name; old pid lingers). The park form has neither:

```elixir
# Neutralize the background racer WITHOUT a restart: a suspended Sweeper
# cannot tick EventHubs.sweep() into our window. No env churn, no restart
# race, no wait for re-registration.
pid = own_sweeper!(nil)
:sys.suspend(pid)
on_exit(fn -> :sys.resume(pid) end)

...authored-expiry writes as today...

assert EventHubs.sweep() >= 1
```

Strengthened: the racer is provably parked (suspend is synchronous) vs
probably-restarted; removed: env flip-flop + `GenServer.stop` + restart wait.
The authored-past `until` write stays exactly as landed (it is the exemplar).

---

## 3. `/Users/sac/smalt/test/amqp/flow_credit_test.exs`

| Item | Site | Class | Treatment |
|---|---|---|---|
| `expect_silence(c, 1000)` x2 | tests 1 and 3 | fixed silence window | REPLACE with flow-echo barrier (3.1) |
| `drain_performatives(c, 1000)` | test 5 (drain pin) | fixed silence window | REPLACE with flow-echo barrier, pin kept (3.2) |
| `@recv_timeout 5000` | all blocking recvs | fail-safe deadline | KEEP |
| app-env port overrides + `stop_existing_tree/0` + module-scoped restore | setup | shared-singleton env churn | REPLACE with direct child-spec ports (3.3) |
| `get_free_port/0` TOCTOU | setup | port lease race | KEEP (standard, reuseaddr mitigates) |

### 3.1 Credit-fence tests: flow-echo barrier replaces 1000 ms silence

The claim "no third delivery sneaks in" is currently sampled by waiting
1000 ms. Rewrite as an ordering proof: after collecting the granted
deliveries, send `flow(echo: true)` — the broker MUST answer with its own
flow frame (spec §2.6.4 echo), and session-level per-link ordering means any
transfer it was still going to deliver precedes that reply.

```elixir
c = send_frame(c, {:flow, %{handle: 1, link_credit: 2}})
{transfers, c} = collect_transfers(c, 2)
assert length(transfers) == 2

# Barrier: drain everything up to and including our echo's flow reply. Any
# transfer the broker intended under the earlier credit is session-ordered
# BEFORE the reply — observing the reply with zero interleaved transfers is
# a happens-before proof, not a 1 s sample.
{inter, c} = drain_until_performative(c, :flow, @recv_timeout)
refute :transfer in inter

:gen_tcp.close(c.sock)
```

New helper (replaces `expect_silence/2` for these sites):

```elixir
# Drains frames until a performative of `name` is seen; returns the
# performatives observed BEFORE it (excluding it). Bounded recv keeps
# @recv_timeout as hang fail-safe only.
defp drain_until_performative(c, name, timeout, acc \\ []) do
  case pop_frame(c.buf) do
    {:ok, %{performative: %{performative: ^name}}, rest} ->
      {Enum.reverse(acc), %{c | buf: rest}}

    {:ok, frame, rest} ->
      drain_until_performative(%{c | buf: rest}, name, timeout, [
        frame.performative.performative | acc
      ])

    :incomplete ->
      assert {:ok, data} = :gen_tcp.recv(c.sock, 0, timeout)
      drain_until_performative(%{c | buf: <<c.buf::binary, data::binary>>}, name, timeout, acc)
  end
end
```

For the zero-credit test, the barrier is the same: send
`{:flow, %{handle: 1, link_credit: 0, echo: true}}`, drain to the echo reply,
`refute :transfer in inter`. Removed: `expect_silence/2` at these sites and
both 1000 ms windows. Strengthened: the negative claim changed register from
timed-sample to ordering-law; a broker bug that would have shipped a late
third transfer within 1001 ms is now caught at ANY latency.

### 3.2 Drain pin: same barrier, pin untouched

The test pins "no echo to drain, no further transfer". Keep the drain send
and the pin asserts verbatim; replace the 1000 ms `drain_performatives/2`
observation with the echo barrier (echo flow with drain ABSENT is our own
probe frame, distinct from the pinned no-echo-to-drain behavior):

```elixir
c = send_frame(c, {:flow, %{handle: 1, link_credit: 0, drain: true}})

# Probe barrier: an echoed flow (drain NOT set) forces the broker to answer.
# Per the drain pin, the drain itself produces no reply; the echo does.
c = send_frame(c, {:flow, %{handle: 1, echo: true}})
{inter, _c} = drain_until_performative(c, :flow, @recv_timeout)

refute :transfer in inter
refute :flow in Enum.drop(inter, -1) or inter != Enum.filter(inter, &(&1 != :flow))
```

(The final two lines reduce to: `refute :transfer in inter` and
`refute :flow in inter` — no echo to the drain and no flow besides our own
echo reply. Pinned contract unchanged.)

### 3.3 Setup: direct child-spec ports instead of global app env

`Smalt.AmqpBroker.children/1` already accepts `sb_port:`/`eh_port:` (pinned
by broker_facade's spec test). The full-app env override
(`arm_port`/`egress_port`/`amqp_port`/`event_hubs_port` + save/restore +
module-scoped `restore_app`) exists only to steer the shared Application
boot — which this suite does not need, since it boots its own supervisor.
Draft: build the broker spec with explicit ports, drop four env writes and
both restore layers:

```elixir
setup do
  ports = %{amqp: get_free_port(), eh: get_free_port()}
  Application.put_env(:smalt, :sb_shared_key, Base.encode64(:crypto.strong_rand_bytes(48)))
  on_exit(fn -> Application.delete_env(:smalt, :sb_shared_key) end)

  assert Code.ensure_loaded?(Smalt.AmqpBroker)

  children = [
    Smalt.Store
    | Smalt.AmqpBroker.children(sb_port: ports.amqp, eh_port: ports.eh)
  ]

  {:ok, sup} =
    Supervisor.start_link(children, strategy: :one_for_one, name: Smalt.FlowCreditTestSup)

  on_exit(fn -> stop_tree(sup) end)

  {:ok, amqp: ports.amqp, queue: "flow-credit-#{System.unique_integer([:positive])}"}
end
```

Removed: `stop_existing_tree/0` (the private supervisor no longer collides
with the shared tree's registered names — ports differ by construction, and
`Smalt.Store` stays the single shared seam, gated by `ensure_store_up` in the
module-scoped on_exit as landed), the 4-key prev/restore block, and the
module-scoped `restore_app` on_exit (no app teardown happens anymore).
Strengthened: the suite no longer mutates global Application state per test,
eliminating the cross-test `{:error, :closed}` window documented in the
landed comment (fc4.log 12:14). Note: if `Listener` still reads
`:application.get_env(:smalt, :amqp_port)` somewhere off the opts path, that
read must be confirmed before landing — the child-spec opts path is proven
by broker_facade; the env path is the one being retired.

---

## 4. `/Users/sac/smalt/test/amqp/queue_store_test.exs`

| Item | Site | Class | Treatment |
|---|---|---|---|
| `Process.sleep(700)` + `Process.sleep(500)` | renew-mirror test | fixed sleeps (~1.2 s, jitter-sensitive) | REMOVE — authored clock (4.1) |
| `Task.await_many(..., 60_000)` | ST4 courts | fail-safe | KEEP |
| shared Store named tables + `delete_all_objects` | setup | shared singleton | KEEP with fence note (4.2) |

### 4.1 Renew-mirror test: authored clock, zero sleeps

The sleeps exist to land the renew "before original expiry" and the sweep
"after original, before renewed" — a two-sided timing window with ~700 ms of
tolerated jitter. The property under test is structural: renew MIRRORS the
extended expiry into the message row; sweep consults the row. Split into a
structural proof (no clock at all) plus the existing authored-expiry sweep
tests (already landed elsewhere in this file):

```elixir
test "renew mirrors locked_until into the message row (sweep therefore cannot reclaim it)" do
  {:ok, _} = QueueStore.ensure_queue("sweep-renew-q")
  {:ok, _} = QueueStore.enqueue("sweep-renew-q", "keep")

  # Deterministic clock: dequeue at t=1000 with duration 1000 -> original
  # expiry 2000. Renew at t=1500 -> renewed expiry 2500, mirrored into the
  # row. No real time passes that matters; the contract is read back
  # directly instead of being sampled through two sleeps.
  {:ok, m, lock} =
    QueueStore.dequeue_matching("sweep-renew-q", now_ms: 1_000, lock_duration_ms: 1_000)

  assert {:ok, renewed_expiry} =
           LockManager.renew(lock.lock_token, 1_500)

  assert renewed_expiry == 2_500

  # The mirror is the mechanism under test: the message row must carry the
  # RENEWED expiry, which is exactly why a sweep at any t in (2000, 2500)
  # sees a live lock. Exact equality — the landed >= form is weakened by
  # real-clock slop that no longer exists.
  assert {:ok, %{state: :locked, lock_token: ^lock.lock_token, locked_until: 2_500,
                 delivery_count: dc}} =
           Smalt.Store.get(:smalt_sb_messages, {"sweep-renew-q", m.seq})

  assert dc == m.delivery_count
  assert {:ok, %{locked_until: 2_500}} = LockManager.get(lock.lock_token)
end
```

Caveat to verify at implementation: `dequeue_matching/2` defaults
`now_ms` to the real clock when the opt is omitted — the opt IS supported
(every sibling test uses it), and `LockManager.renew/2` takes an explicit
`now` (the landed tests pass `@now + 1_000`). If `QueueStore.sweep/0`'s
real-clock sweep coverage is wanted as a belt over the mirror, the existing
authored-expiry sweep tests already carry it; this test no longer needs any.

Strengthened: `locked_until >= lock.locked_until` -> exact `== 2_500` on both
row and token; window shrinks from ~1200 ms of real time to zero. Removed:
both sleeps, the i21d contention comment (its reason disappears).

### 4.2 Shared Store: keep, fenced

The tables are named globals owned by `Smalt.Store`; a per-test Store
instance would need parameterized table names (an API change out of scope
for a test-lane rewrite). The landed shape — `ensure_store_up/0` readiness
gate + `delete_all_objects` per setup + on_exit cleanup of
`:smalt_resources` — is the correct fence for a shared seam and is already
the R185j repair. Keep. Note for the WO: `async: false` on this module is
load-bearing precisely because of the shared tables; do not "fix" it to
`async: true` without the parameterized-table change.

---

## 5. `/Users/sac/smalt/test/amqp/event_hubs_test.exs`

| Item | Site | Class | Treatment |
|---|---|---|---|
| `Process.sleep(30)` after `reserve_processing(..., 10)` | lease reclaim test | fixed sleep | REMOVE — authored expiry (5.1) |
| `Process.sleep(10)` after `reserve_processing(..., 1)` | lens-5 sweep live/expired | fixed sleep | REMOVE — authored expiry (5.1) |
| `Process.sleep(60)` after `reserve_processing(..., 15)` | F-3 shape test | fixed sleep | REMOVE — authored expiry (5.1) |
| `:ets.delete/1` of global named tables | F-4 test | global transition | KEEP with disclosure (5.2) |
| conditional `if whereis(Store) == nil, do: start_supervised!` x6 | wire tests | shared-singleton conditional | REPLACE with canonical gate (5.3) |
| per-test listener/accept/handshake boilerplate x6 | wire tests | duplication | DEDUP via setup helper (5.4) |
| `recv_until` timeouts 2000/3000 | wire harness | fail-safe | KEEP |

### 5.1 Authored expiry replaces all three lease TTL sleeps

The claim's `until` field IS the contract (same justification already landed
in broker_facade's GC test: tables are `:public :named`, server-owned; the
test-fixture write is state construction, not a production caller-side RMW —
the court-banned shape is in the sweep/cas implementation, and the F-3 trace
court enforces exactly that on the caller). One shared fixture helper:

```elixir
# Test-fixture state construction: author the claim's `until` in the past.
# The tables are :public :named and server-owned; this is the same
# authored-state pattern as broker_facade's claim-GC test. The production
# caller-side-write ban is enforced separately by the F-3 trace court.
defp expire_claim!(g, p) do
  [{_k, cp}] = :ets.lookup(:smalt_eh_checkpoints, {g, p})
  expired = put_in(cp, ["claim", "until"], System.system_time(:millisecond) - 60_000)
  true = :ets.insert(:smalt_eh_checkpoints, {g, p}, expired) && true
  :ok
end
```

(correction at implementation: the insert is
`true = :ets.insert(:smalt_eh_checkpoints, {g, p}, expired)` — one table
arg, one object.)

Sites:

```elixir
# lease reclaim:
assert :ok = EventHubs.reserve_processing(g, p, :a, 60_000)
assert {:error, :conflict} = EventHubs.reserve_processing(g, p, :b, 5_000)
assert :ok = EventHubs.reserve_processing(g, p, :a, 60_000)
expire_claim!(g, p)
assert EventHubs.sweep() >= 0
assert :ok = EventHubs.reserve_processing(g, p, :b, 5_000)
```

Same one-line substitution at the lens-5 (`:expired, 1` + `sleep(10)`) and
F-3-shape (`:expired, 15` + `sleep(60)`) sites. Removed: three sleeps and
three short TTLs; strengthened: expiry no longer depends on the sweep
landing between t+TTL and t+TTL+sleep — the claim is expired at the moment
sweep runs, deterministically.

### 5.2 F-4 global table delete/recreate: keep, disclose

The 32-racer `ensure_tables` court must race the CANONICAL names
(`:smalt_eh_partitions`, `:smalt_eh_checkpoints`) or it tests nothing —
unique names would not exercise the shipped `ensure_tables/0`. The delete is
a global transition, but the same test recreates both tables through the
public seam before returning, and every other test in the module calls
`EventHubs.ensure_tables()` in setup, which re-materializes them. Keep, add
one `on_exit(fn -> EventHubs.ensure_tables() end)` for the crash-mid-test
case. This is a named exception, not an oversight — record it in the lane
receipt.

### 5.3 Wire tests: canonical Store gate

Six wire tests repeat `if GenServer.whereis(Smalt.Store) == nil, do:
start_supervised!(Smalt.Store)`. Two problems: duplicated policy, and a
TOCTOU on `whereis` (another suite can stop the shared Store between the
check and the use). Replace with the canonical readiness gate every
non-wire suite already uses:

```elixir
assert :ok = SmaltTest.Lifecycle.ensure_store_up()
```

Strengthened: bounded-loud readiness (waits for ALL Store tables, the R185j
repair) vs a nil-check on one pid; the conditional disappears (ensure_store_up
starts the tree iff absent — same idempotence, one implementation). Each
wire test keeps `Application.put_env(:smalt, :sb_shared_key, ...)` +
on_exit as landed.

### 5.4 Wire harness dedup

Six tests hand-roll the same ~20 lines: `:gen_tcp.listen(0, ...)` ->
`:inet.port` -> accept task spawning `Smalt.Amqp.Connection.start_link` ->
`wh/1` handshake. Draft one setup-scoped helper (structure only; wire
behavior identical, pinions untouched):

```elixir
defp wire_conn! do
  Application.put_env(:smalt, :sb_shared_key, "test-shared-key-0123456789abcdef012345")
  on_exit(fn -> Application.delete_env(:smalt, :sb_shared_key) end)
  assert :ok = SmaltTest.Lifecycle.ensure_store_up()
  EventHubs.ensure_tables()

  {:ok, listener} =
    :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true,
                        ip: {127, 0, 0, 1}])

  {:ok, port} = :inet.port(listener)

  accept_task =
    Task.async(fn ->
      {:ok, sock} = :gen_tcp.accept(listener, 5000)
      {:ok, pid} = Smalt.Amqp.Connection.start_link(socket: sock)
      :ok = :gen_tcp.controlling_process(sock, pid)
      {:ok, pid}
    end)

  {:ok, client} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 5000)
  {:ok, _conn} = Task.await(accept_task, 5000)

  on_exit(fn -> :gen_tcp.close(client) end)
  wh(client)
  {client, port}
end
```

The ann-hub test keeps its partition-`"1"` isolation choice (unique hub +
partition `"1"`) — that comment is a witnessed-fix note, not boilerplate.
`out-of-pin` attach test keeps its unique-hub construction. Removed: ~120
lines of duplicated setup; strengthened: one place to fix the handshake if
the SASL pinion ever changes.

---

## Summary: strengthened / removed / kept

| File | Strengthened | Removed | Kept (with rationale) |
|---|---|---|---|
| fuzz_test.exs | ratio legs ms -> us | — | 30 s hostile-probe deadlines (hang fail-safe, no flake channel); ratio bounds 3.0/1.4 (measured geometry); all pinions |
| broker_facade_test.exs | survival proven by fresh accept; kill observed via DOWN; suspend parks racer synchronously; deadline-bounded polls | 2 x `sleep(50)`; count-bounded `wait_until/2`; stop/restart dances | authored-expiry GC (landed exemplar); Store via `ensure_store_up` |
| flow_credit_test.exs | silence windows -> flow-echo happens-before proofs (any-latency detection); no per-test app-env mutation | 2 x 1000 ms windows; 4-key env save/restore; module-scoped `restore_app` | `@recv_timeout 5000` (fail-safe); drain no-op pin + flat-1000 credit pin verbatim; `get_free_port` |
| queue_store_test.exs | `>=` expiry -> exact `== 2_500` on row and token; window 1200 ms -> 0 | 2 sleeps in renew-mirror test | shared Store + `delete_all_objects` fence (R185j, named seam); 60 s task deadlines |
| event_hubs_test.exs | whereis nil-check -> `ensure_store_up/0` readiness gate; expiry authored, 3 sleeps gone; ~120 lines deduped | 3 x TTL sleeps; duplicated wire boilerplate | F-4 global table delete (named exception, on_exit restore added); recv fail-safes; partition pinion tests verbatim |

Regression-math citations used: fuzz_test's own measured fence geometry
(clean <= 1.3 vs mutant 22.9..36.1, bound 3.0; map ~1.12 vs ~1.7, bound 1.4)
as the relative-fence exemplar; the zero-window-vs-n-window argument in
Method note for every sleep removal; AMQP session per-link ordering (spec
§2.5) as the soundness basis for the flow-echo barriers.

## Implementation notes (for the WO, not this draft)

1. `flow_credit_test` 3.3 depends on `Smalt.AmqpBroker.children/1` covering
   every port the listener tree reads; verify no `Application.get_env`
   fallback in `Listener.start_link` before deleting the env writes.
2. `queue_store_test` 4.1 depends on `dequeue_matching/2` and
   `LockManager.renew/2` honoring explicit `now_ms`/`now` — both are
   exercised with explicit clocks by sibling tests in the same file.
3. `event_hubs_test` 5.1's `expire_claim!/2` shape must match the landed
   checkpoint value shape (`cp["claim"]["until"]`) — confirm against
   `reserve_processing`'s writer before landing.
4. `AssertEventually` is a dependency of 2.3; land per
   `assert-eventually.ex.md` first or inline the poll loop temporarily.
5. No generated artifact, no `lib/` file, no pinion surface is touched by
   any rewrite in this draft.
