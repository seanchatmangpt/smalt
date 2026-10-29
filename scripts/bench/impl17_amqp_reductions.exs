# IMPL-17: AMQP decode baseline on OTP 29.1.2 — honest denominator for the JIT claim.
# In-process, 100k synthetic AMQP transfer frames per size class, decoded via
# Smalt.Amqp.FrameCodec.decode_frame/1 (which routes the body through PrimitiveCodec).
# Emits tmp/bench/impl17-amqp-reductions.jsonl
#
# Run (from repo root), no substrate needed (--no-start; decode is pure):
#   MIX_BUILD_ROOT=_build-impl17 IMPL17_OTP=29.1.2 \
#     mix run --no-start scripts/bench/impl17_amqp_reductions.exs
# with OTP 29.1.2 + Elixir 1.20.4-otp-29 on PATH (asdf pins from .tool-versions).

alias Smalt.Amqp.FrameCodec

emit_dir = Path.expand("tmp/bench", File.cwd!())
File.mkdir_p!(emit_dir)
out = Path.join(emit_dir, "impl17-amqp-reductions.jsonl")

emu_flavor =
  try do
    inspect(:erlang.system_info(:emu_flavor))
  rescue
    _ -> "unknown"
  end

machine = %{
  "cpu" => "Apple M3 Max",
  "otp" => System.get_env("IMPL17_OTP", "unknown"),
  "erts" => :erlang.system_info(:version) |> to_string(),
  "elixir" => System.version(),
  "jit" => emu_flavor
}

Code.ensure_loaded!(Smalt.Amqp.FrameCodec)

defmodule Impl17 do
  @fields %{
    handle: 0,
    delivery_tag: 1,
    message_format: 0,
    settled: 0,
    more: false,
    rcv_settle_mode: 0,
    state: nil
  }

  def bench_class(payload_size, frames, n_iters) do
    payload = :binary.copy(<<0>>, payload_size)
    frame = IO.iodata_to_binary(FrameCodec.encode_frame(:amqp, 0, {:transfer, @fields, payload}))
    frame_size = byte_size(frame)

    # sanity: the synthetic frame must decode clean through PrimitiveCodec
    {:ok, %{type: :amqp, performative: %{performative: :transfer}}} =
      FrameCodec.decode_frame(frame)

    # warmup
    for _ <- 1..2_000, do: FrameCodec.decode_frame(frame)

    {r0, _} = :erlang.statistics(:reductions)
    t0 = System.monotonic_time(:millisecond)

    for _ <- 1..(frames * n_iters), do: FrameCodec.decode_frame(frame)

    {r1, _} = :erlang.statistics(:reductions)
    t1 = System.monotonic_time(:millisecond)

    total = frames * n_iters
    wall_ms = max(t1 - t0, 1)
    reds = r1 - r0

    %{
      frame_size: frame_size,
      total: total,
      wall_ms: wall_ms,
      per_frame_reductions: reds / total,
      per_frame_us: wall_ms * 1000 / total
    }
  end
end

# {label, payload_size, iterations over the 100k frames}
classes = [
  {"64B", 64, 20},
  {"1KB", 1024, 20},
  {"64KB", 64 * 1024, 5}
]

lines =
  Enum.map(classes, fn {class, size, iters} ->
    res = Impl17.bench_class(size, 100_000, iters)

    row = %{
      lane: "impl17",
      surface: "amqp_frame_codec",
      op: "decode_frame",
      class: class,
      frame_size_bytes: res.frame_size,
      n: res.total,
      per_frame_reductions: Float.round(res.per_frame_reductions, 1),
      per_frame_us: Float.round(res.per_frame_us, 3),
      wall_ms_total: res.wall_ms,
      ops_per_sec: trunc(res.total / (res.wall_ms / 1000)),
      errors: 0,
      machine: machine
    }

    Jason.encode!(row)
  end)

:erlang.garbage_collect()
File.write!(out, Enum.join(lines, "\n") <> "\n")
IO.puts("wrote #{out}")
Enum.each(lines, &IO.puts/1)
