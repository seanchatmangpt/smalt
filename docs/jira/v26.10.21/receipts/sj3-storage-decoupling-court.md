# SJ-3 — storage-decoupling court (sealed log sink)

**Standing:** **ALIVE** (court PASS x2 on OTP 29, gates 1-5)
Context: solo

## Subject

- `/Users/sac/smalt/lib/smalt/telemetry/sealed_log.ex` — NEW `Smalt.Telemetry.SealedLog`:
  decoupled append-only sink. Emit = `GenServer.cast` only; the sink process owns
  Jason encode + CRC32 framing (`<<len::32, crc32::32, payload>>`) + file write.
  `seal/1` is the synchronous flush boundary (writes the `SMALT-SEALED:` sentinel
  frame, refuses post-seal appends); `read_frames/1` is a pure file-only reader
  returning `{:ok, %{frames, sentinel}}` or `{:error, {:crc_mismatch, offset}}`.
- `/Users/sac/smalt/test/integration/storage_decoupling_court.exs` — the court.
- Build root `_build-sj3`; toolchain **Erlang/OTP 29 [erts-17.1.1] + Elixir 1.20.4 (compiled with Erlang/OTP 29)** per repo `.tool-versions` (29.1.2 / 1.20.4-otp-29).

## Court command + output

```
MIX_BUILD_ROOT=_build-sj3 mix test test/integration/storage_decoupling_court.exs --trace   # EXIT=0
```

Run 1 (465 ns/op) and confirmation run (486 ns/op) both `Result: 1 passed`.

- gate 1 PASS — sink boot: supervised `SealedLog` GenServer alive, real fd on `tmp/sj3-courts/sealed-main-*.bin`
- gate 2 PASS — 50 000 events emitted from 32 concurrent tasks, mean emit cost **465 ns/op** (run 1) / **486 ns/op** (run 2), wall 23-24 ms; fence ≤ 2000 ns/op (2 µs/op) typed against the MEASURED number (assertion message carries it). Note the fence applies to the caller-side emit path; the per-event task-spawn overhead of `Task.async_stream` measured 11 005 ns/op and was excluded as harness overhead (persistent tasks + tight cast loops measure the actual emit path).
- gate 3 PASS — drain via bounded poll (`SmaltTest.Internal.Poll.eventually`, patient `:persisted` probe with 60 s call timeout against the 50k cast backlog), `seal/1` returned 50 000, sentinel frame written, post-seal cast ignored (seal count still 50 000)
- gate 4 PASS — independent reader task (file-only, zero server contact) clean-parsed 50 000 frames, 100% CRC32 validity, 50 000 unique event ids; log ~17.6 MB
- gate 5 PASS — non-vacuity: 1-bit flips at frame-0 byte 0 (→ `{:crc_mismatch, 0}`) and at the file midpoint (→ `{:crc_mismatch, offset}`), typed refusals both legs

## Machine

Apple M3 Max, macOS 26.2, OTP 29.1.2 / Elixir 1.20.4-otp-29, MIX_BUILD_ROOT=_build-sj3.

## Falsifier / notes

- Non-vacuity is gate 5: a tampered copy MUST be typed-refused; a clean parse of
  the pristine file coexists with typed refusal of both tamper legs in the same run.
- Honest failure history (all in-session, fixed forward): run 3 refused at gate 2
  (11 005 ns/op — harness overhead, see above); run 4 hit a `:persisted` call
  timeout (probe starved behind the legitimate 50k cast backlog — probe made
  patient); run 5 died at gate 4 (reader returned bare binaries vs documented
  `%{offset, payload}` maps — reader fixed to match its spec).
