# Receipt: PRD-APPCONF push sub-claim — App Config webhook event-notification face

Context: solo

**Standing:** **ALIVE (in-process webhook face) + HTTP-delivery variant typed UNSUPPORTED-by-airgap**

Date: 2026-10-21 · Lane: APPWS (writer) · Build root: `_build-appws` · Machine: `{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}`

## Subject

Closes PRD-APPCONF's typed-down push sub-claim (real Azure App Configuration push is Event
Grid webhooks, not WS): minimal event-notification face over the /kv write path.

## Diff (absolute paths)

- **NEW** `/Users/sac/smalt/lib/smalt/data_plane/appconfig_events.ex` — `Smalt.DataPlane.AppConfigEvents`
  GenServer: subscription registry (pid receiver or webhook URL; URL must be loopback
  127.0.0.1/localhost/[::1], non-loopback → typed `{:error, {:refused, :non_loopback_endpoint}}`,
  SSRF fail-closed), typed Event Grid envelope emission
  (`Microsoft.AppConfiguration.KeyValueModified` / `...KeyValueDeleted`,
  subject `AppConfiguration.KeyValue:<key>:<label>`, data key/label/etag), delivery to
  pid subscribers (`{:appconfig_kv_event, name, event}`) + capped pull log (`events/0`).
- **MOD** `/Users/sac/smalt/lib/smalt/egress/AppConfigRoutes.ex` (+11): both successful /kv PUT
  branches (plain kv_write and the KD-109 feature-flag branch) call `emit_kv_event/1`;
  fail-safe (a broken registry never fails the write).
- **NEW** `/Users/sac/smalt/test/integration/appconfig_events_test.exs` — 5 Chicago tests.

## Typed verdict for the HTTP-delivery variant

**UNSUPPORTED-by-airgap.** The substrate has zero outbound dial (`grep -rn httpc lib/` → 0 hits;
no HTTP client, no outbound :gen_tcp.connect in `lib/` — only the AMQP listener's inbound
sockets), so loopback-HTTP webhook POST delivery is not implemented. The loopback-URL
subscription cell is admitted-then-typed-down honestly: the URL is stored, and each event
records the outcome `{:error, {:unsupported, :http_delivery_airgap}}` — never a silent drop,
never a faked pass. Envelope shape matches real Event Grid POST bodies so a future delivery
engine is receiver-compatible.

## Test output (actual, final run)

```
MIX_BUILD_ROOT=_build-appws mix test test/integration/appconfig_events_test.exs \
  test/integration/kv404_typed_error_test.exs test/integration/kv_crypto_face_test.exs \
  test/integration/event_grid_webhook_test.exs
→ ...........
Finished in 0.5 seconds (0.00s async, 0.5s sync)
21 tests, 0 failures
```

My suite: 5/5 (subscribe → mutate key → envelope received; deleted-variant typing;
non-loopback refusal typed; loopback URL admitted + UNSUPPORTED outcome recorded;
unsubscribe → nothing received). Assertions use `assert_receive` (bounded poll on real
observables — no `Process.sleep`; 0 hits in both new files).

## Cross-lane disclosure (compile-freeze SLA, same-checkout-fanout law 2+6)

Mid-run, another lane's in-flight edit broke the shared compile for >10 min: invalid guard
`defguardp int_in(x, lo, hi) when :erlang.is_integer(x, lo, hi)` in FOUR files
(`lib/smalt/data_plane/blob_storage.ex`, `cosmos.ex`, `file_share.ex`,
`lib/smalt/egress_router.ex`). I applied the minimal unblock fix
(`when is_integer(x) and x in lo..hi`) in all four; this lane owns no semantic claim on them —
owning lane should re-review. Earlier combined runs under heavy machine load (245 s sync)
returned 4 load-order flakes that all cleared on settled reruns (21/21 twice).

## Falsifier / flip condition

Flip the HTTP-variant cell to ALIVE only when a real loopback HTTP POST is witnessed landing
on a receiver process from an emitted kv event (requires adding the substrate's first
outbound dial — an airgap-census-relevant transition). The in-process face flips to REFUTED
if a /kv PUT after subscription fails to deliver a typed envelope to a registered pid.
