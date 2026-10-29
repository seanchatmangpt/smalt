# SJ-1 — Journal Sink Writer (PROD-1)

Milestone: v26.10.21 · Lane: SJ-1 · Milestone: v26.10.21
Toolchain: Elixir 1.20.4-otp-29 / Erlang OTP 29.1.2 (erts 17.1.1), `MIX_BUILD_ROOT=_build-sj1`
**Standing:** **ALIVE** (as-scoped: writer only; SJ-2 reader is a sibling lane)
Context: solo

## Scope

PROD-1 WAL foundation — `Smalt.Storage.JournalSink`, a GenServer append-only
journal writer per the SJ-1 dispatch spec (no operator `.erl` reference found
on disk; the frame spec in the dispatch was complete and was the source of
truth). GLD-2's court-upgrade leg (raising when PROD-1 lands) is the
follow-on lane's and is untouched here.

- `/Users/sac/smalt/lib/smalt/storage/journal_sink.ex` — writer GenServer.
  Frame: `MAGIC "SMAL" | FrameLen u32 | SeqID u64 | Ts s64 | EventType u16 |
  TableID u16 | KeyLen u32 + Key | PayloadLen u32 + Payload | CRC32`
  (big-endian; CRC over SeqID..Payload). Active/sealed dirs, 64 MiB segment
  ceiling (pre-write rotation: a segment is sealed when the NEXT frame would
  cross the ceiling, so no sealed segment ever exceeds it), 500ms datasync
  tick (`Process.send_after` — SCHEDULING, not coordination), seal protocol
  = fsync -> rename into sealed/ -> meta.json (sha256, frame count, seq
  range) -> `.seal` sentinel written LAST.
- `/Users/sac/smalt/test/integration/sj1_journal_sink_court.exs` — Chicago
  court (plain mix-run script, real files, no mocks, no sleeps).

## Court legs (5, all PASS)

1. **Frame round-trip exactness** — 4/4 edge cases (empty fields, max u64
   seq, negative ts, 4 KiB payload, UTF-8) bit-exact re-encode.
2. **Frame refusal faces** — CRC corruption, bad magic, truncation, trailing
   bytes each return a typed `{:error, reason}`.
3. **Seal atomicity** — after `seal/1`: sealed file + meta.json + `.seal`
   present, exactly one new empty active segment, manifest sha256 == actual
   file sha256, manifest frames/first_seq/last_seq == decoded stream;
   sentinel removal = unsealed (negative face).
4. **Segment rotation** — 20 appends under a 512 B ceiling -> 3 sealed
   segments, each <= ceiling, each sentinel-sealed, no duplicates.
5. **Monotonic SeqID** — strict 0..30 across rotation and an explicit
   mid-stream seal.

## Command output

```
$ PATH=/Users/sac/.asdf/shims:$PATH MIX_BUILD_ROOT=_build-sj1 \
    mix run --no-start test/integration/sj1_journal_sink_court.exs
SJ-1 JOURNAL SINK COURT  (OTP 29, erts 17.1.1)
LEG 1: frame round-trip exactness
  round-trip: 4/4 cases exact
LEG 2: frame refusal faces
  refusals: crc/the rest all typed
LEG 3: seal atomicity (rename -> meta -> sentinel LAST)
  seal: ordered rename+meta+sentinel, sha256 verified, sentinel-removal = unsealed
LEG 4: segment rotation at ceiling
  rotation: 3 sealed segments, all under ceiling, all sentinel-sealed
LEG 5: monotonic SeqID across rotation and seal
  monotonic: 31 appends, strict 0..30 across rotation + explicit seal
SJ-1 COURT: PASS
EXIT=0   (4 consecutive green runs; repeat runs EXIT=0)
```

Zero compile warnings for the module (`mix compile` grep count 0). No
`Process.sleep` in either file (sleep-gate clean).

## Defect caught and fixed by the court

Rotation was originally post-write (segment crossed the ceiling before
sealing; leg 4 measured a 514 B segment against a 512 B ceiling). Fixed to
pre-write rotation; leg 4 then measured 3 sealed segments all under ceiling.

## Notes for the follow-on lanes

- SJ-2 reader consumes `decode_frame/1` (public), skips sealed segments
  whose `.seal` sentinel is absent.
- GLD-2 upgrade leg: `Smalt.Storage.JournalSink` is now loadable; the GLD-2
  court's `raise`-when-PROD-1-lands leg will trip on module name
  `Smalt.Storage.Journal` vs `Smalt.Storage.JournalSink` — the upgrade lane
  should reconcile the check against the landed module.
- `mix run --no-start` is required: the shared substrate holds 8443/9443, so
  a plain `mix run` app-start exits `:eaddrinuse` (pre-existing, not
  session-introduced).

## Falsifier

Re-run the court; any FAIL leg or nonzero exit flips this receipt to
SUSPECT.
