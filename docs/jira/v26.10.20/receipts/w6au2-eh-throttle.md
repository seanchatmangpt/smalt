# w6au2 — Event Hubs ingress quota/limit parity (eh_throttle)

**Standing: PARTIAL_ALIVE**
Date: 2026-10-20
Lane: w6au2 (re-dispatch of w6au; design carried forward)
Files (exclusive): `lib/smalt/messaging/eh_throttle.ex` (NEW)
Scratch: `tmp/w6au2_witness.exs` (replay below), `tmp/w6au2_ebin/`

## What landed

`lib/smalt/messaging/eh_throttle.ex` — Event Hubs quota/limit parity:

- per-hub sliding-window ingress quota in heir'd ETS `:smalt_eh_throttle`
  (`{:heir, Process.whereis(:init) || self(), []}` 3-tuple, lazily created,
  insert_new-guarded);
- `admit/3` publish-side gate: under quota `{:ok, :admitted}`, over quota
  typed `{:throttled, %{retry_after_s, window_ms, limit}}` face;
- HTTP face `retry_after/1` (429 + `Retry-After` seconds) and typed AMQP-face
  mapping `amqp_refusal/1` → `{:error, {:resource_limit_exceeded, msg}}`
  (server-busy/resource-limit class);
- window slides: counts keyed `win:<hub>:<bucket>` drop naturally per bucket;
  re-admission after expiry witnessed (bounded poll — no Process.sleep);
- quotas: `set_quota/3` override + additive hub-record field
  (`properties.quota` integer, read-only lookup over the real resources
  store, never written by this module);
- typed telemetry `[:smalt, :event_hubs, :throttled]` on refusal.

## Real witness output (module-direct, real Store; replay below)

    STORE=:started
    F1_UNQUOTAED_ADMITS=ok
    F2_QUOTA_LIMIT_THROTTLES=ok retry_after_s=1
    F3_WINDOW_SLIDE_READMITS=ok
    F4_RETRY_AFTER_FACE=ok (1s)
    F5_AMQP_FACE=ok
    F6_CLEAR=ok
    F7_RECORD_QUOTA_HONORED=ok
    W6AU2 WITNESS: DONE

Note: F7 first run skipped (Store.put/3 absent in isolation), then the
arity check corrected to /3; the witness itself caught a real module bug
en route (`list_prefix` returns values, not tuples — the {_k, rec} pattern
silently rescued to nil and quota lookup never found the record; fixed and
the F7 green leg is the non-vacuity proof).

## Compile

- Standalone (ERL_LIBS=deps): RC=0 (exit 0), single expected isolation warning
  (`Smalt.Store.list_prefix/2` against the stale prebuilt smalt beam).
- Full-lane `MIX_BUILD_ROOT=_build-lane-w6au2 MIX_ENV=test mix compile`
  GREEN except sibling-owned strict warnings blocking
  `--warnings-as-errors` (Store.list_all/1 unqualified in rbac.ex,
  Policy.role_verbs_builtins in policy surface, maybe_forward/3 in
  queue_store.ex) — none in my file, disclosed per SLA; my module
  contributed zero diagnostics.

## Falsifier

Re-run the witness replay on the quiesced tree: a green run under a
broken admit gate (over-quota admitting, or retry_after 0) would be
vacuous.

## Replay

    ERL_LIBS=$(ls -d _build-coord/test/lib/* | tr '\n' ':') elixir -e '
    Code.put_compiler_option(:ignore_module_conflict, true)
    Code.compile_file("lib/smalt/store_tables.ex")
    Code.compile_file("lib/smalt/store.ex")
    Code.compile_file("lib/smalt/messaging/eh_throttle.ex")
Code.compile_file("tmp/w6au2_witness.exs")
'
