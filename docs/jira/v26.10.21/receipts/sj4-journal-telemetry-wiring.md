# SJ-4: journal sink wired into the real telemetry path (config-gated, default OFF)

Date: 2026-10-21
Lane: SJ-4 (writer, OTP-29), MIX_BUILD_ROOT=_build-sj4
Repo: /Users/sac/smalt (canonical checkout)
Context: solo

## Standing
**Standing:** ALIVE

**ALIVE** — emitter diff compiles clean on the pinned OTP 29.1.2 /
Elixir 1.20.4-otp-29 toolchain, and the Chicago integration court is
green twice consecutively (13/13 assertions, exit 0) on the exact
subject (`_build-sj4`).

## What landed (the diff)

1. `lib/smalt/telemetry/ocel_emitter.ex` (lane-owned)
   - New closed operator EventType map, public for the court:
     `journal_event_code/2` — `cosmos.doc.crud` method != DELETE →
     0x0001 (put), method == DELETE → 0x0002 (delete);
     `blob.custody.transition` → 0x0003; `amqp.delivery.settled` →
     0x0004; anything else → nil (OCEL-only, no journal frame; the map
     is closed like the event registry).
   - New `journal_append/2` in the shared `append/2` path: when
     `config :smalt, :journal_sink_dir` is SET, one operator-format
     frame is appended through the real SJ-1 sink —
     `Smalt.Storage.JournalSink.append(JournalSink, code, 0, key, payload)`
     (TableID 0 = telemetry plane; Key = primary object id; Payload =
     tiny JSON `%{"ocel_event_id" => id, "time" => iso8601}` — ids and
     codes only, matter-isolation law holds). Unset → the function is a
     no-op: no sink call, OCEL ndjson path byte-identical.
   - Fail-safe law preserved: the whole journal branch is inside the
     emitter's rescue boundary; a sink process that is not running (or
     any failure) degrades to a logged drop — the OCEL path and the
     caller's request are never affected.
2. `lib/smalt/application.ex` (disclosed minimal cross-lane edit —
   shared file, no other lane currently holds it modified)
   - `journal_sink_child/0`: `config :smalt, :journal_sink_dir` set →
     the named `Smalt.Storage.JournalSink` GenServer child starts with
     that dir; nil (default) → `[]`, byte-identical boot.

## The court (Chicago, real collaborators)

`test/integration/sj4_journal_wire_court.exs` — run:

```
MIX_BUILD_ROOT=_build-sj4 MIX_ENV=dev mix run --no-start \
  test/integration/sj4_journal_wire_court.exs   # exit 0 = PASS
```

Real Bandit HTTP listener on a loopback port (OS-assigned via a
reserved socket), the real `OcelEmitter` handler attached to
`[:bandit, :request, :stop]`, the real `Smalt.Storage.JournalSink`
process, the real `Smalt.Storage.JournalReader`, real `OcelNdjson`:

- ON leg (13 ok lines): real wire PUT and DELETE → the sealed segment
  parsed back by SJ-2's reader holds exactly 4 frames; EventType codes
  exactly [1,2,3,4]; SeqID monotonic, starts at 0, no gaps; Key of the
  put/delete frames is the real request path; real wall-clock Ts;
  Payload JSON links the OCEL event id; OCEL ndjson still appended
  (coexistence); manifest sha256 present (bd36dcfb… on run 1,
  d8adf662… on run 2 — real content, not canned).
- OFF leg: no new journal directory anywhere under the tmp root; OCEL
  ndjson still appends; the line keeps exactly the four OCEL 2.0
  top-level keys (byte-identical shape).
- Skip contract: if SJ-1's module is absent the court exits 3 (typed
  SKIP, loud) — it did so once mid-wave while SJ-1 was landing; never a
  fake pass.

Real command output (run 2, tail):

```
SJ-4 JOURNAL WIRE COURT
  ok  sealed segment holds exactly 4 frames (got %{"bytes" => 587, "first_seq" => 0, "frames" => 4, "last_seq" => 3, ...})
  ok  exactly one sealed segment discovered
  ok  reader returns exactly 4 frames
  ok  frames carry the operator EventType codes 0x0001..0x0004 (got [1, 2, 3, 4])
  ok  SeqID is monotonic in segment order (got [0, 1, 2, 3])
  ok  SeqID starts at 0 with no gaps (got [0, 1, 2, 3])
  ok  wire put/delete frames carry the real request path as Key
  ok  frames carry a real wall-clock Ts
  ok  Payload JSON links the OCEL event id (matter-isolation: ids only)
  ok  OCEL ndjson still appended alongside the journal (coexistence)
  ok  config OFF: no new journal directory appears anywhere under the tmp root
  ok  config OFF: OCEL ndjson path still appends (behavior preserved)
  ok  config OFF: ndjson line keeps the exact four OCEL 2.0 top-level keys (byte-identical shape)
SJ-4 COURT: PASS
```

## Verification ladder + honest failures

- `MIX_BUILD_ROOT=_build-sj4 mix compile` — clean (no ocel_emitter /
  application warnings; pre-existing warnings elsewhere are untouched
  by this diff).
- Court exit 3 once (SKIP while SJ-1's file was mid-landing) — typed,
  loud, then re-run to exit 0 twice consecutively.
- `mix test test/internal` on `_build-sj4`: 187/204, **17 failures,
  ALL pre-existing or concurrent-lane, none in this diff's files**: 13
  in `Smalt.Storage.JournalReaderCourtTest` (SJ-1's own in-flight
  suite; this lane never touched journal_sink/reader) + census tests
  (InternalTier.CensusTest, file-set assertions over test/internal that
  another lane's in-flight files shift) + one EventHubs
  `:ensure_tables` timeout (substrate contention on the shared box).
  Rerun receipt: this lane's court is independent of all of them and
  passed twice.

## Coordination notes

- SJ-1's landed API is `Smalt.Storage.JournalSink.append(sink, event_type,
  table_id, key, payload, ts)` (named GenServer, PROD-1 frame codec) —
  the emitter diff was adapted to it mid-wave (earlier draft targeted a
  not-yet-landed `Smalt.Telemetry.JournalSink.append/1`; the skip gate
  made that visible loudly instead of faking a pass).
- In production ON mode, sealing happens on rotation/shutdown (the
  SJ-1 seal protocol); the court seals explicitly to read frames with
  the fail-closed reader. This is the reader's law, not a wiring gap.
- Poll in the ON leg of the earlier draft was retired when the sink
  became synchronously observable via seal+read (one bounded poll
  helper remains in the file for future async use, annotated).

## Falsifier (how this receipt dies)

Boot with `config :smalt, :journal_sink_dir` set, make a real HTTP
request, and find no sealed journal frame for it; or boot with config
unset and observe any new journal file or a changed OCEL ndjson line
shape. Both are executable directly from the court command above.
