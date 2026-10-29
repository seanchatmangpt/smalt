# r11 — T-12: Chaos engineering — AMQP link/credit/session injectors

- window: v26.10.28 · ticket: `tickets/T12-amqp-chaos-injectors.md` · date: 2026-10-29
- tier: beam (`test/integration/chaos_injectors_test.exs`) · status: **CODE-COMPLETE (2026-10-29): r11, awaiting integration run**

## landed

1. **New injector module `lib/smalt/messaging/chaos.ex`**
   (`Smalt.Messaging.Chaos`) — the single owner of flag resolution, the
   pure predicates, the typed error shape and the telemetry emission.
   Zero `Process.sleep` anywhere (the zero-sleep law; the one timer in the
   feature is a `Process.send_after` SCHEDULING timer inside the
   connection — doctrine Law 2's lawful form):
   - Config resolution (boot-eval discipline): all six typed
     `Application.get_env(:smalt, key)` reads — `:sb_chaos_detach_after`,
     `:sb_chaos_starve_credits`, `:sb_chaos_session_timeout_ms` plus the
     `:eh_*` trio namespacing the same machinery for Event Hubs links.
     Defaults `:infinity` / `"off"` / `:infinity`; anything that is not a
     typed arm (0, negatives, strings, garbage) fails closed to OFF.
     Never runtime module patching — the flags are read at the hook sites
     like every other `:smalt` env key (`Smalt.Config.amqp()` pattern).
   - Pure API the broker calls: `should_detach?(delivery_count, ns \\ :sb)`
     (true iff armed with N and the count REACHED N — never before),
     `detach_armed?/1` (the connection skips its per-link counter entirely
     when off — the anti-vacuity skip), `starve?/1`,
     `session_timeout/1` + `session_close_bound/0` (the session layer is
     shared, so the shortest armed namespace bound governs), and
     `config/0` (the court/receipt view).
   - Typed fault shape: `detach_error/1` —
     `%{condition: "amqp:link:detach-forced", description: "SMALT_CHAOS_DETACH_FORCED (chaos_detach_after=N)"}`
     — the same retryable error name @azure/service-bus surfaces during
     Azure maintenance events.
   - Typed telemetry on every fired injection, stable event names:
     `[:smalt, :chaos, :link_detach]` (measurements `%{deliveries: n}`),
     `[:smalt, :chaos, :credit_starved]` (`%{withheld_credit: c}`),
     `[:smalt, :chaos, :session_timeout]` (`%{timeout_ms: ms}`); metadata
     carries namespace / channel / handle / address.
2. **`lib/smalt/messaging/amqp/connection.ex` — four surgical hooks**
   (file structure untouched; every hook sits adjacent to the code it
   hooks and is a no-op passthrough when the flags are off):
   - **(a) delivery path → `bump_credit/4`**: `bump_credit` is called ONLY
     from the three delivery paths (queue claim + both EH delivery paths),
     so the delivery decrement is the one counting point for every link
     kind. `chaos_after_delivery/4` counts per link (`:chaos_deliveries`
     on the link map — link maps already tolerate additive keys, the
     `eh_agg_cursors` precedent); on the Nth delivery it requeues the SAME
     typed `{:eh_epoch_evict, ch, handle, error}` message the
     cross-connection epoch-eviction handler consumes (mirroring that
     handler's detach frame, epoch release, link removal and pump resume —
     the connection stays up so the client relink is clean) and zeroes the
     link credit so the same-frame `deliver_to_link` recursion cannot
     outrun the detach. Wired detach goes out AFTER exactly the Nth
     transfer frame.
   - **(b) credit/flow path → `handle_amqp(:flow, ...)`**: while
     `starve?/1` (namespace resolved from the targeted link's kind — a
     handle-nil session flow only ever grants queue links → `:sb`), the
     inbound flow's credit grant is withheld (`add_credit`/`set_credit`
     skipped); deliveries stall until the flag clears. Credit already
     outstanding still drains — the stall is on NEW grants, exactly the
     ticket's face. Each withheld grant emits `:credit_starved`.
   - **(c) session timeout → `do_begin/3` + one `handle_info`**:
     `chaos_arm_session_timeout/2` arms a deterministic
     `Process.send_after(self(), {:sb_chaos_session_timeout, ch, ref}, ms)`
     keyed by a `make_ref` token (a stale timer — client already ended /
     re-begun the channel — no-ops via the ref match and can never close a
     NEWER session). The fired handler closes the session with the typed
     `amqp:internal-error` / `SMALT_CHAOS_SESSION_TIMEOUT` end frame and
     mirrors `handle_amqp(:end)` cleanup (drop the channel's links,
     release their epoch registrations, retire its outbound deliveries).
3. **Event Hubs namespacing (scope 4)**: the `:eh_*` trio resolves by link
   kind at the hook sites — EH receiver links ride the SAME delivery/flow
   machinery, so `:eh_chaos_detach_after` / `:eh_chaos_starve_credits` arm
   detach/starve for EH links only, and
   `:eh_chaos_session_timeout_ms` participates in the shared session close
   bound. `:sb_*` flags leave EH links untouched and vice versa (wire-proven
   in the isolation leg below).

## DoD mapping — the Azure developer's view

- **Detach injection**: boot with the one-liner below, run your
  `@azure/service-bus` receiver: every N-th delivery lands in your
  `processError` with `amqp:link:detach-forced` (retryable, the Azure
  maintenance-event error name), and your retry loop relinks and keeps
  receiving without code changes — the court relinks and takes the next
  message, then takes the next detach, deterministically, every time.
- **Credit starvation**: your receiver observes the stall (no transfer
  while armed); when you flip the flag off (the boot-eval form: re-boot
  with the key cleared) and the next flow fires, deliveries resume — no
  detach, no session end, the link survives.
- **Session timeout**: your sessions close on schedule with the typed
  chaos marker; your session/connection-recreation path is exercised
  exactly as in production (re-begin → fresh session → the injector
  re-arms).

## boot-eval snippet (the documented one-liners)

```elixir
# force-detach queue links after the 2nd delivery (retryable detach-forced)
Application.put_env(:smalt, :sb_chaos_detach_after, 2)
# starve Event Hubs receivers (deliveries stall until the flag clears)
Application.put_env(:smalt, :eh_chaos_starve_credits, true)
# close sessions 750ms after each begin (client resiliency path)
Application.put_env(:smalt, :sb_chaos_session_timeout_ms, 750)
# all flags default OFF: nil / unset / garbage all read as :infinity / "off"
```

## courts (`test/integration/chaos_injectors_test.exs`, DO NOT RUN here — awaiting integration lane)

Pure-function courts over `Chaos`:

1. **Detach court**: armed N=3 — `should_detach?` false at 1..2, true at 3
   (exactly on the Nth, never before), still true past N (liveness);
   garbage bounds (`0`, `-2`, `"three"`) fail closed to `:infinity`; the EH
   namespace is its own flag.
2. **Starve court**: off = always false; `true`/"on" arm; "off" clears;
   `:sb` / `:eh` isolated.
3. **Session-timeout court**: defaults `:infinity`; per-namespace bounds;
   shared bound = shortest armed; garbage drops out of the min.
4. **Error-shape + config court**: `amqp:link:detach-forced` +
   `SMALT_CHAOS_DETACH_FORCED` shape; `config/0` round-trip.

Wire round-trips through the REAL Connection hook paths (Application
put_env in-process, kd134 harness: real TCP socket, real Connection
GenServer, real QueueStore/EventHubs, real CBS put-token, codec-native
frames, bounded polls only):

5. **Starve wire court**: armed → flow withheld (absence window), typed
   `:credit_starved` telemetry (`namespace: :sb`); flag clears → re-flow
   delivers; no detach/end ever (link survives).
6. **Detach wire court**: N=2 — two transfers, then the forced detach with
   `amqp:link:detach-forced`; FIRST-detach index strictly after the second
   transfer index and exactly 2 transfers precede it (never before); typed
   `:link_detach` telemetry (`deliveries: 2`); relink + flow recovers
   (third delivery), then the second detach (every N-th).
7. **Session-timeout wire court**: begin → the broker's own send_after
   timer closes the session ~300 ms in with `SMALT_CHAOS_SESSION_TIMEOUT`;
   typed `:session_timeout` telemetry; re-begin recreates the session and
   the injector re-arms deterministically.
8. **EH namespacing wire court** (shared machinery, link-kind resolution):
   queue link (flag off) delivers while the EH partition link (flag on) is
   starved with `:eh` telemetry; flag clears → EH transfer lands.
9. **Anti-vacuity witness (the ticket's non-vacuity court)**: all flags
   off — delivery lands normally, delivery settled (structural sync), then
   a 3s bounded absence window observes NO detach, NO forced end, NO chaos
   telemetry. Flags off = zero interference.

## non-goals honored

No random/probabilistic modes (deterministic, typed, bounded only); no
network-level injection. `sb_rules.ex` / `sb_delivery.ex` (T-08),
`event_hubs.ex` and `parity/` untouched. Zero `Process.sleep` in
`chaos.ex` and zero new sleeps in `connection.ex` (the one timer is
doctrine-lawful `Process.send_after` scheduling).
