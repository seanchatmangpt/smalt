# PB-6 dual-boundary settlement walk (v26.10.21).
#
# The SAME 5-step settlement (lease -> validate -> CAS -> seal -> observe)
# through BOTH boundaries with per-step wall decomposition:
#   (a) wire leg   — real @azure/cosmos SDK over the TLS twin
#                    (scripts/bench/pb6_wire_leg.mjs; per-step client timestamps)
#   (b) native leg — Smalt.POWL2.ChangeFeed in-process (this file), per-step
#                    :timer.tc timing, zero wire machinery.
# Emits tmp/bench/pb6-dual-boundary.jsonl rows {step, wire_ms, native_ms, tax}
# (p95s and machine spec included) — the measured boundary tax per step.
#
# Run (private TLS substrate must be listening on :39174 first — see receipt):
#   MIX_BUILD_ROOT=_build-pb6 MIX_ENV=test \
#     SMALT_TLS_CERTFILE=.smalt/tls/dev-cert.pem SMALT_TLS_KEYFILE=.smalt/tls/dev-key.pem \
#     mix run scripts/bench/pb6_dual_boundary.exs

defmodule PB6 do
  @repo_root File.cwd!()
  @tls "https://localhost:39174"
  @ca Path.expand(".smalt/tls/ca-cert.pem", @repo_root)
  @out Path.expand("tmp/bench/pb6-dual-boundary.jsonl", @repo_root)
  @wire_out Path.expand("tmp/bench/pb6-wire-steps.json", @repo_root)
  @wire_script Path.expand("scripts/bench/pb6_wire_leg.mjs", @repo_root)
  @node_cwd Path.expand("verification/ts", @repo_root)
  @steps ["1-lease", "2-validate", "3-cas", "4-seal", "5-observe"]
  @native_iters 5000
  @native_warm 200

  alias Smalt.POWL2.ChangeFeed

  # ---------------------------------------------------------------------------
  # Native leg — ChangeFeed CAS + CDC observe, :timer.tc per step
  # ---------------------------------------------------------------------------

  def native_walk(server, i) do
    pk = "pb6"
    id = "d#{i}"

    {t_lease, {:ok, 201, lease_etag}} =
      :timer.tc(fn -> ChangeFeed.put_item(server, pk, id, %{"state" => "lease", "v" => i}) end)

    {t_validate, lease_etag} =
      :timer.tc(fn ->
        got = ChangeFeed.etag(server, pk, id)
        ^lease_etag = got
        got
      end)

    {t_cas, {:ok, 200, cas_etag}} =
      :timer.tc(fn ->
        ChangeFeed.put_item(server, pk, id, %{"state" => "cas", "v" => i}, if_match: lease_etag)
      end)

    {t_seal, {:ok, 200, seal_etag}} =
      :timer.tc(fn ->
        ChangeFeed.put_item(server, pk, id, %{"state" => "seal", "sealSig" => "pb6-#{i}"},
          if_match: cas_etag
        )
      end)

    {t_observe, :visible} =
      :timer.tc(fn ->
        observe_until(seal_etag, System.monotonic_time(:millisecond) + 5_000)
      end)

    [t_lease, t_validate, t_cas, t_seal, t_observe]
  end

  # Settlement is "visible" once the seal etag arrives in a CDC batch. Old
  # batches are flushed through until the matching event shows; bounded by a
  # monotonic deadline (typed raise, never an unbounded wait). `after 0` +
  # 1ms re-loop is a bounded mailbox poll — the no-sleep lawful form.
  defp observe_until(etag, deadline) do
    if System.monotonic_time(:millisecond) > deadline, do: raise("pb6: observe deadline")

    receive do
      {:cdc_batch, _from, _to, events} ->
        if Enum.any?(events, fn {_seq, :put, _pk, _id, e} -> e == etag end) do
          :visible
        else
          observe_until(etag, deadline)
        end
    after
      0 ->
        Process.sleep(1)
        observe_until(etag, deadline)
    end
  end

  # ---------------------------------------------------------------------------
  # Wire leg via node child process
  # ---------------------------------------------------------------------------

  def run_wire do
    {out, 0} =
      System.cmd("node", [@wire_script],
        cd: @node_cwd,
        env: %{
          "NODE_EXTRA_CA_CERTS" => @ca,
          "PB6_TLS" => @tls,
          "PB6_WIRE_OUT" => @wire_out
        },
        stderr_to_stdout: true
      )

    IO.puts(out)
  end

  # ---------------------------------------------------------------------------
  # Stats + emission
  # ---------------------------------------------------------------------------

  def stats(list) do
    v = Enum.sort(list)

    pct = fn q ->
      idx = q / 100 * length(v) |> Float.floor() |> trunc() |> max(0) |> min(length(v) - 1)
      Enum.at(v, idx)
    end

    %{
      "mean_ms" => Enum.sum(v) / max(length(v), 1),
      "p50_ms" => pct.(50),
      "p95_ms" => pct.(95),
      "p99_ms" => pct.(99)
    }
  end

  def machine_spec do
    {:ok, cpu} = with_cmd("sysctl", ["-n", "machdep.cpu.brand_string"])
    {:ok, cores} = with_cmd("sysctl", ["-n", "hw.ncpu"])
    {:ok, ram} = with_cmd("sysctl", ["-n", "hw.memsize"])
    {:ok, otp} = with_cmd("erl", ["-noshell", "-eval", ~s{io:format("~s",[erlang:system_info(otp_release)]),halt()}])
    {:ok, el} = with_cmd("elixir", ["-e", "IO.puts System.version()"])
    {:ok, darwin} = with_cmd("sw_vers", ["-productVersion"])

    %{
      "cpu" => cpu,
      "cores" => String.to_integer(cores),
      "ram_gb" => String.to_integer(ram) |> div(1024 * 1024 * 1024),
      "elixir" => el,
      "otp" => otp,
      "darwin" => darwin
    }
  end

  defp with_cmd(cmd, args) do
    {out, 0} = System.cmd(cmd, args)
    {:ok, String.trim(out)}
  end

  def main do
    {:ok, _} = ChangeFeed.start_link(base: :powl2_pb6)
    :ok = ChangeFeed.subscribe(:powl2_pb6)

    IO.puts("[pb6-native] warmup #{@native_warm}")
    for i <- 1..@native_warm, do: native_walk(:powl2_pb6, -i)

    IO.puts("[pb6-native] measured #{@native_iters}")
    acc = Map.new(@steps, fn s -> {s, []} end)

    acc =
      Enum.reduce(1..@native_iters, acc, fn i, acc ->
        [t1, t2, t3, t4, t5] = native_walk(:powl2_pb6, i)

        acc
        |> Map.update!("1-lease", &[t1 / 1000 | &1])
        |> Map.update!("2-validate", &[t2 / 1000 | &1])
        |> Map.update!("3-cas", &[t3 / 1000 | &1])
        |> Map.update!("4-seal", &[t4 / 1000 | &1])
        |> Map.update!("5-observe", &[t5 / 1000 | &1])
      end)

    native_stats = Map.new(acc, fn {k, v} -> {k, stats(v)} end)
    IO.puts("[pb6-native] done")
    IO.puts(Jason.encode!(native_stats))

    run_wire()

    wire = @wire_out |> File.read!() |> Jason.decode!()
    wire_stats = Map.fetch!(wire, "steps")
    wire_n = Map.fetch!(wire, "n")
    wire_errors = Map.fetch!(wire, "errors")
    machine = machine_spec()

    File.mkdir_p(Path.dirname(@out))

    for step <- @steps do
      w = Map.fetch!(wire_stats, step)
      n = Map.fetch!(native_stats, step)
      tax = Float.round(w["p50_ms"] - n["p50_ms"], 3)

      row = %{
        lane: "pb6",
        surface: "cosmos-settlement",
        op: step,
        step: step,
        n: wire_n,
        n_wire: wire_n,
        n_native: @native_iters,
        wire_ms: Float.round(w["p50_ms"], 4),
        wire_p95_ms: Float.round(w["p95_ms"], 4),
        native_ms: Float.round(n["p50_ms"], 4),
        native_p95_ms: Float.round(n["p95_ms"], 4),
        tax_ms: tax,
        tax_ratio: if(n["p50_ms"] > 0, do: Float.round(w["p50_ms"] / n["p50_ms"], 1)),
        wire_errors: wire_errors,
        machine: machine
      }

      File.write!(@out, Jason.encode!(row) <> "\n", [:append])
      IO.puts(
        "#{step}  wire_p50=#{row.wire_ms}ms  native_p50=#{row.native_ms}ms  " <>
          "tax=#{row.tax_ms}ms (#{row.tax_ratio}x)"
      )
    end

    IO.puts("[pb6] wrote #{@out}")
  end
end

PB6.main()
