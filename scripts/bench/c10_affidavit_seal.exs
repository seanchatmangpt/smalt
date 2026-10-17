# c10: affidavit admit_and_seal latency bench (lane 7, affidavit-closure wave).
# Run: MIX_BUILD_ROOT=_build-lane7 MIX_ENV=test mix run --no-start scripts/bench/c10_affidavit_seal.exs
#
# Conventions (scripts/bench/REGISTRY.md):
#   * lane c10 -> port block 39250..39255 (c-law 39200 + 10*10 .. +5). The
#     engine boot in this lane binds NO listeners (in-process Wasmex host),
#     so the block is reserved-but-unused; the lane never touches the b-band.
#   * result file: tmp/bench/c10-affidavit-seal.jsonl (script underscore,
#     result hyphen). This lane writes ONLY that file.
#   * lib.sh use: the machine block is produced by the real
#     `bench_machine_spec` from scripts/bench/lib.sh (sourced via bash).
#     `bench_emit` itself is not called because this row carries two extra
#     fields the shared emitter cannot express (p_max_ms, engine_sha256);
#     the emitted line is byte-compatible with the bench_emit schema.
#   * boot: no shared substrate needed — the lane boots its own
#     Smalt.Affidavit.WasmEngine (fail-closed start_link, sha256 sidecar
#     pin on priv/wasm/affidavit_wasm.wasm).

defmodule Bench.C10.AffidavitSeal do
  @n 100
  @result_path "tmp/bench/c10-affidavit-seal.jsonl"

  def run do
    engine_sha = engine_artifact_sha256!()

    {:ok, _} = Smalt.Affidavit.WasmEngine.start_link([])
    # Warmup: 10 seals off-clock (JIT / first-instantiate cost).
    Enum.each(1..10, fn i -> seal_once(i) end)

    t0 = :erlang.monotonic_time(:millisecond)
    :rand.seed(:exsss, {t0, t0 * 7919 + 13, t0 * 104_729 + 7})

    {lats_us, errors} =
      Enum.map_reduce(1..@n, 0, fn i, errs ->
        {us, res} = :timer.tc(fn -> seal_once(i) end)

        case res do
          {:ok, %{sealed: sealed}} when byte_size(sealed) == 352 -> {us, errs}
          _ -> {us, errs + 1}
        end
      end)

    total_ms = Enum.sum(lats_us) / 1000.0
    p50 = pct(lats_us, 50) / 1000.0
    p95 = pct(lats_us, 95) / 1000.0
    p99 = pct(lats_us, 99) / 1000.0
    pmax = Enum.max(lats_us) / 1000.0
    ops_per_sec = if total_ms > 0, do: @n / (total_ms / 1000.0), else: 0.0

    row = %{
      lane: "c10",
      surface: "affidavit-seal",
      op: "admit_and_seal",
      n: @n,
      ops_per_sec: round(ops_per_sec),
      p50_ms: fl(p50),
      p95_ms: fl(p95),
      p99_ms: fl(p99),
      p_max_ms: fl(pmax),
      errors: errors,
      engine_sha256: engine_sha,
      machine: machine_spec()
    }

    File.mkdir_p!(Path.dirname(@result_path))
    File.write!(@result_path, Jason.encode!(row) <> "\n", [:append])
    IO.puts(Jason.encode!(row, pretty: true))
    if errors > 0, do: System.halt(1), else: :ok
  end

  # Fresh receipt per iteration (unique subject_sha) under a fixed seed.
  defp seal_once(i) do
    t = :erlang.monotonic_time(:millisecond)
    :rand.seed(:exsss, {t, t * 7919 + i, t * 104_729 + 7})

    subject =
      1..32
      |> Enum.map(fn _ -> :rand.uniform(255) end)
      |> IO.iodata_to_binary()
      |> Base.encode16(case: :lower)

    receipt = %{
      subject_sha: subject,
      authority: "BRCE",
      consequence: "scripts/bench/c10_affidavit_seal.exs",
      replay: "mix run scripts/bench/c10_affidavit_seal.exs",
      standing: "ALIVE"
    }

    Smalt.Affidavit.Seal.admit_and_seal(receipt)
  end

  defp pct(lats, p) do
    v = Enum.sort(lats)
    Enum.at(v, round(p / 100 * (length(v) - 1)))
  end

  defp fl(x), do: :erlang.float_to_binary(x * 1.0, decimals: 3)

  defp engine_artifact_sha256! do
    path = "priv/wasm/affidavit_wasm.wasm"
    {:ok, bin} = File.read(path)
    Base.encode16(:crypto.hash(:sha256, bin), case: :lower)
  end

  # Mirrors scripts/bench/lib.sh bench_machine_spec byte-for-byte.
  defp machine_spec do
    {cpu, 0} = System.cmd("sysctl", ["-n", "machdep.cpu.brand_string"])
    {cores, 0} = System.cmd("sysctl", ["-n", "hw.ncpu"])
    {ram_b, 0} = System.cmd("sysctl", ["-n", "hw.memsize"])
    {elixir_v, 0} = System.cmd("elixir", ["-e", "IO.puts System.version()"])
    {otp, 0} = System.cmd("elixir", ["-e", "IO.puts :erlang.system_info(:otp_release)"])
    {darwin, 0} = System.cmd("sw_vers", ["-productVersion"])

    %{
      cpu: String.trim(cpu),
      cores: String.to_integer(String.trim(cores)),
      ram_gb: div(String.to_integer(String.trim(ram_b)), 1024 * 1024 * 1024),
      elixir: String.trim(elixir_v),
      otp: String.trim(otp),
      darwin: String.trim(darwin)
    }
  end
end

Bench.C10.AffidavitSeal.run()
