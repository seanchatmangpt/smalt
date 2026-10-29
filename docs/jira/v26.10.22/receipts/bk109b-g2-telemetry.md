# Receipt: BK-109b — JA-15 gap G2, error-path telemetry

**Standing:** **ALIVE** (court 10/10 passed on the exact subject; non-vacuity leg green;
anonymous-handler penalty wart fixed with a module-qualified handler; re-run exit 0)

Context: solo

## Scope (the 3 owned files)

JA-15 gap G2 (last open JA-15 gap; carried note in
`docs/jira/v26.10.21/receipts/ja15b-gap-adoption.md` line 83: "G2 (cosmos/blob/KV
error-path telemetry) not in scope; still open"). G4 gave the refusal funnels Logger
lines; G2 adds `:telemetry.execute` alongside them.

## Diffs

1. `lib/smalt/data_plane/cosmos.ex` — `error_response/5` (the G4 site): after the
   Logger.warning, `:telemetry.execute([:smalt, :wire, :refusal], %{count: 1},
   %{face: :cosmos, status: status, code: code, correlation_id: correlation_id})`.
   Note: the coordinator tick commits picked this file into HEAD during the session
   (telemetry hunk confirmed in `git show HEAD:...cosmos.ex` at 2505ff) — the hunk is
   identical to what this lane wrote; only the test file remained lane-local uncommitted
   per the do-not-commit instruction.
2. `lib/smalt/data_plane/blob_error.ex` — `send_error/5` (the G4 site): same execute
   with `%{face: :blob, status: status, code: code, correlation_id: correlation_id}`.
   Also confirmed in HEAD.
3. `test/internal/ja15_error_logger_court_test.exs` — 3 new legs (8, 9, 10) plus a
   `Smalt.Ja15.RefusalTelemetryHandler` module (module-qualified attach — the first
   run used anonymous fn handlers, `telemetry:attach/4` logged the local-function
   performance warning, fixed by attaching `&Smalt.Ja15.RefusalTelemetryHandler.handle_event/4`).
   - Leg 8 (cosmos): real `create_db` + real refusal `create_doc(db, coll, %{"id" => "bad/id"})`
     -> typed 400 BadRequest; handler attached to `[:smalt, :wire, :refusal]` asserts
     `%{count: 1}`, `%{face: :cosmos, status: 400, code: "BadRequest"}`, correlation_id
     =~ `^cos-\d+$`. Real processes, no mocks.
   - Leg 9 (blob): real `send_error/5` on a `Plug.Adapters.Test.Conn` conn, status 404
     BlobNotFound; asserts event `%{face: :blob, status: 404, code: "BlobNotFound"}`,
     correlation_id == "blob-ja15-g2-req-1", XML body byte-check `<Code>BlobNotFound</Code>`.
   - Leg 10 (non-vacuity): deliberately NO handler attached — both refusals still typed
     on the wire (cosmos 400 BadRequest with "Invalid document id"; blob 409
     LeaseIdMismatchWithBlobOperation envelope `state: :sent`). Telemetry is
     observability, not control flow.
   - This file is uncommitted per instruction; the other 18 files in `git status` are
     other lanes' in-flight work, not this lane's.

## Court output (actual)

```
$ MIX_BUILD_ROOT=_build-bk109b asdf exec mix test test/internal/ja15_error_logger_court_test.exs
...
Finished in 0.3 seconds (0.00s async, 0.3s sync)
Result: 10 passed
```
exit 0. (First run pre-handler-refactor: 10 passed; warning from `telemetry:attach`
re anonymous fn; second run post-refactor: 10 passed, warning gone.)

Site log lines witnessed in the run output (G4 layer still firing under G2):

```
warning[correlation_id=cos-270794 ] [cosmos] wire refusal status=400 code=BadRequest db=ja15g2nv coll=c1 message="Invalid document id: ..." correlation_id=cos-270794
warning[correlation_id=blob-ja15-g2-nv-1 ] [blob] wire refusal status=409 code=LeaseIdMismatchWithBlobOperation path=/ja15/blob-nv message="There is currently a lease on the blob." correlation_id=blob-ja15-g2-nv-1
```

## Exits

- mix test (court file): exit 0, 10 passed (7 pre-existing + 3 new G2 legs)
- Non-vacuity leg 10: PASS (refusals typed with zero handlers attached)
- Not run here: full `mix test` suite, `just court` — single-file scope; the court file
  is the named gate for this gap
- No commits made (per instruction); `test/internal/ja15_error_logger_court_test.exs`
  left modified in the working tree
