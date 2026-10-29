# GWS-7 — smalt wasm host bridge aligned to the real graphlaw wasm ABI

**Standing:** **ALIVE** (encoding round-trip proven both directions; 18/18 court tests green, exit 0)
Context: solo

Repo: /Users/sac/smalt (branch main) · graphlaw read at 0af58bf
Toolchain: Elixir 1.20.4-otp-29 (asdf), OTP 29.1.2, `MIX_BUILD_ROOT=_build-gws7`

## Diff (my lane files only)

- `lib/smalt/wasm/worker.ex` — speaks the real graphlaw ABI (src/abi.rs,
  `ABI_VERSION = 1`): public `encode_abi_request/1` (map -> exact call_json
  bytes, the gl_alloc/gl_call buffer) and `decode_abi_response/1`
  (`{"ok":true,...}` -> `{:ok, verdict}`; `{"ok":false,"error":{kind,engine,
  dialect,message,details}}` -> `{:error, {:abi_refusal, %{...}}}`; anything
  else typed `{:malformed_frame, _}`). Typed runtime switch
  `config :smalt, :wasm_binary_path`: set -> abi mode over
  `wasmtime run --max-memory 67108864 <binary>` (raw ABI bytes cross the
  port; 16 MiB `MAX_REQUEST_BYTES` enforced host-side as a typed
  `ResourceLimit` abi_refusal; non-JSON-op payloads refused pre-send as
  `{:abi_request_malformed, ...}`); unset -> stub mode, where the port frame
  still rides the runner eval envelope but `payload_b64` now carries the
  REAL ABI request bytes.
- `lib/smalt/wasm/bridge.ex` — real-ABI focus-node mapping:
  `pack_focus_node/1` (shapes+text -> `{"op":"shacl","data":{"text",
  "dialect"},"shapes"}`; text-only -> `{"op":"parse","text","dialect"
  [,"base"]}`; dialects are the ABI wire names, default `ntriples`),
  `encode_request/1`, `decode_response/1`, `unpack_verdict/1` (real shacl
  non-conform verdict -> typed `{:abi_refusal, %{kind: "EngineRejected",
  details: %{"code" => "NotAdmitted"}}}` guard refusal), and `eval/2` now
  accepts a focus-node map end-to-end (pack -> encode -> sandbox -> decode
  -> unpack); legacy raw-binary payloads bypass packing so transport courts
  stay green.
- `lib/smalt/wasm/pool.ex` (one line) — **compile-freeze unblock, disclosed
  for WASM-1's lane**: their in-flight edit piped the queue as the first
  argument to `:queue.filter/2` (signature is `filter(pred, queue)`), which
  crashed `respawn/3` with ArgumentError and took down gates 3/5 of the
  sandbox court. Fixed to `state.queue |> then(&:queue.filter(pred, &1)) |>
  then(&:queue.in(fresh, &1))` — their piped style preserved, argument order
  corrected. Please re-read before your next edit of that line.
- `test/integration/wasm_abi_court_test.exs` (new) — encoding round-trip
  court, both directions, real bytes, no mocks.

## Court output (real, exit 0)

```
MIX_BUILD_ROOT=_build-gws7 mix test test/integration/wasm_sandbox_court.exs test/integration/wasm_abi_court_test.exs --trace
  * gate 1 clean eval ... (556ms) / gate 2 memory wall (23ms) / gate 3 respawn (455ms)
  * gate 4 pool_exhausted / gate 5 fail-closed timeout / gate 6 guest trap
  * 12 wasm_abi_court tests: pack shacl/parse shapes, encode byte round-trip,
    decode ok / NotSemanticContent / ResourceLimit refusal shapes,
    malformed-frame typed refusals, shacl non-conform unpack, stub end-to-end
    with real ABI bytes in payload_b64, legacy raw path
Finished in 2.3 seconds
Result: 18 passed
EXIT=0
```

The placeholder `OP_EVAL_FOCUS` / `OP_EXEC_DUCKDB` byte encoding is gone from
the worker's protocol surface: the worker now targets the real 14-op JSON ABI
(`capabilities`..`policy`), ABI_VERSION=1, with the real limits
(16 MiB request, depth 64) enforced host-side.

## Notes for the coordinator

- graphlaw's real wasm binary is not built yet (GWS-2 pending), so abi mode
  is prepared but exercised only at the encoding layer; the stub court rides
  the transport path with the real ABI request bytes as payload.
- Pre-existing cross-lane leak observed: `stub_runner.exs --hang` sleeps
  forever and port close never kills it — orphan erl VMs accumulate across
  lanes (_build-wasm1, _build-lane18, _build-gws7 each had several). Runner
  fix belongs to WASM-1's spec lane, not GWS-7.
- GWS-7 ran with `MIX_BUILD_ROOT=_build-gws7` throughout; no shared-infra
  edits, no bench files touched.
