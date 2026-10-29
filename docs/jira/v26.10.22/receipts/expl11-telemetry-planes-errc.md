# EXPL-11 — Telemetry / Planes / ConfidentialLedger / WebPubSub ERRC sweep (read-only)

- **Date**: 2026-10-22
- **Lane**: EXPL-11, repo /Users/sac/smalt (canonical checkout, read-only sweep; only this receipt written)
- **Surfaces**: `lib/smalt/telemetry/*` (ocel_emitter, ocel_ndjson, semconv/registry, sealed_log, *_ocel), `lib/smalt/planes.ex` + runtime.exs + application.ex plane-boot subset, `lib/smalt/confidential_ledger/` (service + router + supervisor), `lib/smalt/webpubsub/` (service/events/token/socket)
- **Prior art read first**: KD register (v26.10.22 KNOWN_DIVERGENCES.md: KD-166/169/171/172/175 rows + EXPL-4/6/7/9 pointers), receipts INDEX, prior EXPL-1..9 receipts (expl4 F1/F6 already closed token-verify and socket catch-all gaps — both re-checked clean)
- **Standing**: PARTIAL_ALIVE
- **Context**: solo

## Method

Full read of all 15 target files (2809 lines). Then real compiled-module probes with
`mix run --no-start` (asdf elixir 1.20.4-otp-29 / OTP 29.1.2), ephemeral in-proc
supervisor + Bandit on ephemeral loopback port, all writes under /tmp, cleaned up.

## Findings (ranked)

### F1 — HIGH, WITNESSED E2E OVER THE WIRE: ACL range parser silently coerces malformed transactionIds; dotful non-numeric values CRASH the ledger service

`lib/smalt/confidential_ledger/service.ex` `seq_of/1` (~:476) and `list/4`/`in_range?/3`:

```elixir
defp seq_of(id) do
  case String.split(id, ".", parts: 2) do
    [seq, _] -> String.to_integer(seq)          # "notanumber.9" -> raises ArgumentError
    _ -> 0                                       # "zzz", "7" -> silently seq 0
  end
end
```

Two opposite failure modes from one root cause, both witnessed via real HTTP
(Bandit + `Smalt.ConfidentialLedger.Router`, ephemeral 47111, temp journal dir):

```
GET list (no range): 200 OK — {"transactions":[...0.1..., ...1.1...]}

GET /app/transactions?rangeBegin=zzz
=> 200 OK {"transactions":[0.1, 1.1]}          # should be 400 BadRequest (real ACL validates)
   # "zzz" (dot-less) -> seq_of -> 0 -> range silently widened to admit ALL transactions

GET /app/transactions?rangeEnd=notanumber.9
=> 500 Internal Server Error
05:22:11.846 [error] GenServer Smalt.ConfidentialLedger.Service terminating
** (ArgumentError) ... :erlang.binary_to_integer("notanumber")
    service.ex:481: Smalt.ConfidentialLedger.Service.in_range?/3
    service.ex:412: list/4 -> handle_call/3
Last message: {:transactions, "0.1", "notanumber.9", 100}
```

The dotful case is a loopable remote DoS: any unauthenticated GET with
`rangeEnd=<garbage>.<n>` crashes the ledger GenServer (one_for_one restart churn,
max_restarts 10/5s). The dot-less case is success-on-unknown: a filter the caller
cannot trust. Fix class: parse+validate range values in `list/4` before the fold,
return a typed `{:error, :invalid_range}` → router 400 (match real ACL, which
validates `rangeBegin`/`rangeEnd` as `N.M` transactionIds). Router already has an
`{:error, {:integrity, _}}` arm; an invalid-range arm is a two-line diff.

Fix owner: BK lanes, v26.10.22 backlog. Falsifier: `GET ?rangeEnd=zzz.9` → 400, and
service alive after; `GET ?rangeBegin=zzz` → 400 (or documented coercion), never
200-with-all.

### F2 — MED, WITNESSED: Web PubSub CloudEvents webhook is success-on-unknown (silent drop)

`lib/smalt/webpubsub/events.ex` `post_event/2` + `emit/5`:

- `:httpc.request(...)` result is DISCARDED (no status check, no retry, unlinked
  `spawn/1`); `Events.connect/3` returns `:ok` unconditionally.
- Probe: handler URL = loopback port with no listener (real TCP reset):

```
Events.connect return (dead handler): :ok
```

`:ok` returned while the POST was dropped (the spawned process only Logger.warning's
— at default log level in the probe nothing surfaced). No delivery witness, no retry.
Real Azure Web PubSub retries webhook delivery; the emulator drops silently. The
in-process witness buffer (events()) records the event regardless (documented
HTTP-independent), so `events()` shows an "emitted" event that was never delivered —
the buffer success-launderers the drop. Fix class: check the `:httpc` status code,
log-drop-count or surface delivery failure on the witness event (e.g. `"delivered"
=> bool`), bounded retry like the real service. Falsifier: with a dead handler,
`events()` must expose a non-delivered typing, never a bare :ok-only story.

### F3 — MED, WITNESSED: Web PubSub group membership leaks dead pids

`lib/smalt/webpubsub/service.ex` `handle_call({:publish,...})`/`members` filter by
`Process.alive?/1` at read time but NEVER prune `groups` state; only an explicit
`leave` prunes, and `Socket.terminate/2` calls `Events.disconnected` but never
leaves the socket's groups. Probe (join then kill member pid):

```
members (filtered): []
raw state.groups: %{"h1" => %{"g1" => [#PID<0.539.DOWN#-class dead pid>]}}
```

Unbounded state growth on churn (every client that joins without a clean leave).
Fix class: prune dead pids in `publish`/`members` handlers (the alive-filter pass
already has the list in hand), or `Process.monitor` in join. Falsifier: join+kill,
then read `:sys.get_state` — dead pid must be gone.

### F4 — LOW, WITNESSED (config-path only): empty plane selection boots zero surfaces, no typed refusal

`Smalt.Planes.resolve/0` (lib/smalt/planes.ex) validates names tightly (JA-R1 atom
guard intact — good), but the app-env path admits the empty list:

```
Application.put_env(:smalt, :planes, [])
Smalt.Planes.resolve() => []
```

`Smalt.Application.plane_children/0` flat_maps unknown→`[]`, so `[]` → zero plane
supervisors → a "successful" boot of an emulator with no planes (no refusal, no
log). SMALT_PLANES env cannot produce it (`"" → :all`), so config-only. Fix class:
`resolve` (or `plane_children`) refuses `[]` with `{:invalid_plane, []}`-class
typed refusal. Falsifier: `config :smalt, :planes, []` must refuse boot.

### F5 — LOW, structural (not probed): ACL `seg_meta` premise rot

`certify_segment/2` gates on `.meta.json` ("frames" count) and takes first_seq/
last_seq from it; `seg_meta/1` returns `%{}` on missing/corrupt meta. A frame-bearing
segment whose meta is missing → refused as `:empty_segment` (fail-closed, safe);
a reader-valid segment with meta missing first_seq/last_seq would put `nil` into
`committing_seg` comparisons (`seq >= nil` ArgumentError → certify-tick crash loop).
JournalSink.seal always writes meta, so this needs external meta-only tampering —
premise-rot class, register as watch item, no witness attempted.

### F6 — note, not a defect

OcelEmitter labels every bandit stop `cosmos.doc.crud` regardless of the actual
surface (blob/kv/arm requests included). Label drift is guarded: the semconv
registry documents the bandit→`cosmos.doc.crud` mapping as a deliberate documented
deviation row in `otel_to_ocel_rules/0`, so no action.

## Clean (checked, no defects)

- `WebPubSub.Token.verify/2` — EXPL-4 F1 essential-claim fail-closed intact (aud/nbf/exp/sub presence + aud match + non-empty sub; garbage sub normalized to []).
- `WebPubSub.Socket` — EXPL-4 F6 catch-all dispatch intact; permission checks symmetric (leave gated like join).
- `Smalt.Planes` validation — JA-R1 no-atom-minting guard intact; malformed env refuses typed.
- Semconv registry — closed names + attribute allowlist fail-closed (unknown name admits no attributes); generated, fenced by semconv tests.
- `OcelNdjson` — assembly closure laws (dangling refs, used-but-undeclared types) fail closed; agent-chain violations typed.
- `ConfidentialLedger.Service` integrity path — tampered-segment re-verify at read time fail-closed (typed `{:error, {:integrity, _}}`); degraded sink records NO transaction; PENDING never silently committed.
- ACL supervisor — loopback bind default, bounded Bandit shutdown (AZB-22b).

## Probe receipts

- Probe 1: `/tmp/expl11_probe1.exs` (planes resolve, WPS join/kill/members/state, dead-handler connect, publish-to-dead-group) — output embedded above.
- Probe 2: `/tmp/expl11_probe2.exs` (real Bandit HTTP: list, rangeBegin=zzz, rangeBegin=7.1, rangeEnd=notanumber.9) — output embedded above. Temp dirs removed by probes.
