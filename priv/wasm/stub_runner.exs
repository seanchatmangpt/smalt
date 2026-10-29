# WASM sandbox STUB runner (deterministic stand-in for
# `wasmtime run --max-memory 67108864 graphlaw_duckdb.wasm`).
#
# Production path (typed, not yet landed): the port cmd in
# Smalt.Wasm.Worker swaps to
#   wasmtime run --max-memory 67108864
# over priv/wasm/graphlaw_duckdb.wasm once the graphlaw + frozen-duckdb
# binary is compiled. The frame protocol below is the same one the
# production binary speaks, so the swap is config (`:wasm_runner_path` and
# `:wasm_runner_args`), not code.
#
# Protocol: packet-4 (4-byte big-endian length prefix) over stdio.
# Request  : JSON {"op":"eval","payload_b64":"...","predicate_frames":[...]}
# Response : JSON {"ok":true,"result":{...}} |
#            {"error":{"code":"sandbox_aborted","detail":"memory_wall"}}
#
# Modes:
#   (default)       deterministic eval: payload <= 64 MiB -> the documented
#                   429 RU refusal envelope; payload > 64 MiB limit -> the
#                   runner TRAPS (exit code 86, wasmtime memory-wall abort)
#                   with no reply frame.
#   --crash         reads one frame, then traps (exit code 86) immediately —
#                   guest-panic leg / pool self-heal court.
#   --hang          never replies (simulated infinite loop) — exercises the
#                   worker's fail-closed timeout leg.
#
# Exit codes: 0 clean, 86 sandbox trap (wasmtime semantics), other non-zero
# is a harness fault.

# Byte-exact stdio: without an explicit latin1 encoding the script device
# transcodes the packet-4 length prefix (any byte >= 0x80 becomes two UTF-8
# bytes) and the BEAM port reader desynchronizes.
:io.setopts(:standard_io, encoding: :latin1)

limit = 67_108_864

mode =
  case System.argv() do
    ["--crash"] -> :crash
    ["--hang"] -> :hang
    [] -> :eval
    other -> raise "stub_runner: unknown args #{inspect(other)}"
  end

# Bounded exact-count reads off stdio. binread may legitimately return fewer
# bytes than requested, so accumulate until the exact count is on hand.
read_exact = fn read_exact, n, acc ->
  case n - byte_size(acc) do
    0 ->
      acc

    remaining ->
      case IO.binread(:stdio, remaining) do
        :eof -> :erlang.halt(90)
        {:error, _reason} -> :erlang.halt(91)
        data when is_binary(data) -> read_exact.(read_exact, n, acc <> data)
        _other -> :erlang.halt(92)
      end
  end
end

<<len::big-unsigned-integer-size(32)>> = read_exact.(read_exact, 4, <<>>)
body = read_exact.(read_exact, len, <<>>)

# Dependency-free frame parse (the runner must run on bare `elixir`, no mix
# deps on the code path): payload_b64 and predicate_frames are the only
# fields the sandbox consumes.
payload_b64 =
  case Regex.run(~r{"payload_b64":"([A-Za-z0-9+/=]*)"}, body) do
    [_, b64] -> b64
    nil -> :erlang.halt(93)
  end

frames_count =
  case Regex.run(~r{"predicate_frames":\[(.*?)\]}, body) do
    [_, ""] -> 0
    [_, inner] -> inner |> String.split(",") |> length()
    nil -> 0
  end

case mode do
  :hang ->
    # Simulated guest infinite loop: never frame, never exit.
    Process.sleep(:infinity)

  :crash ->
    # Simulated guest panic: trap like the memory wall does.
    :erlang.halt(86)

  :eval ->
    payload = Base.decode64!(payload_b64)

    if byte_size(payload) > limit do
      # Memory wall: the guest is killed by the enforced 64 MiB
      # linear-memory ceiling before any reply can be framed.
      :erlang.halt(86)
    else
      frames = Integer.to_string(frames_count)

      reply =
        ~s({"ok":true,"result":{"code":"refusal_envelope","http":429,) <>
          ~s("error":"TooManyRequests","message":"RU burst injected: graphlaw ) <>
          ~s(guard engine refuses the focus-node transaction.",) <>
          ~s("detail":{"predicate_frames_count":#{frames}}}})

      IO.binwrite(:stdio, <<byte_size(reply)::big-unsigned-integer-size(32), reply::binary>>)
    end
end
