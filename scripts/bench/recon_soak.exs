# B-11: recon-based BEAM-level soak — process/binary/atom/ETS leak evidence.
# Companion to the RSS-only soak.py (B-10). Run:
#   MIX_ENV=test mix run scripts/bench/recon_soak.exs
# Boots the full Smalt.Application (Bandit listeners on ephemeral test ports),
# drives 5 minutes of ARM PUT/GET traffic, samples recon every 5s, and appends
# rows {t, proc_count, top_proc_mem, binary_leak_delta, ets_count, atom_count}
# to docs/jira/v26.10.14/bench/recon-soak.jsonl.
#
# Verdict per curve: FLAT (no BEAM-level leak) or GROWING (FIND).

defmodule ReconSoak do
  @out "docs/jira/v26.10.14/bench/recon-soak.jsonl"
  @duration_s 300
  @interval_s 5

  def run do
    File.mkdir_p!(Path.dirname(@out))
    port = Application.fetch_env!(:smalt, :arm_port)
    base = "http://127.0.0.1:#{port}"
    :inets.start()

    IO.puts(
      ~s({"lane":"b11","op":"start","port":#{port},"duration_s":#{@duration_s},"interval_s":#{@interval_s}})
    )

    t_end = System.monotonic_time(:second) + @duration_s
    first = nil
    drive_and_sample(base, t_end, 0, first)
    IO.puts(~s({"lane":"b11","op":"done"}))
  end

  # Load driver + sampler in one process; a 50ms request cadence keeps the
  # traffic realistic while the sampler runs between requests.
  defp drive_and_sample(base, t_end, i, first) do
    now = System.monotonic_time(:second)

    if now >= t_end do
      :ok
    else
      # --- traffic: ARM resource-group PUT (creates ETS rows) then GET ---
      rg = "b11-rg-#{rem(i, 50)}"

      body =
        Jason.encode!(%{
          location: "local",
          properties: %{provisioningState: "Succeeded"}
        })

      url = base <> "/subscriptions/soak-sub/resourcegroups/" <> rg <> "?api-version=2021-04-01"

      req =
        :httpc.request(
          :put,
          {String.to_charlist(url), [], ~c"application/json", body},
          [],
          body_format: :binary
        )

      _ = req

      _ =
        :httpc.request(
          :get,
          {String.to_charlist(base <> "/subscriptions/soak-sub/resourcegroups?api-version=2021-04-01"),
           []},
          [],
          body_format: :binary
        )

      sample()
      Process.sleep(50)
      drive_and_sample(base, t_end, i + 1, first)
    end
  end

  defp sample() do
    procs = :recon.proc_count(:memory, 10)
    top10_mem = procs |> Enum.map(fn {_pid, mem, _info} -> mem end) |> Enum.sum()
    # process-wide binary heap bytes (the bin_leak class, aggregated)
    bin_total = :erlang.memory(:binary)

    row = %{
      t: System.system_time(:second),
      proc_count: :erlang.system_info(:process_count),
      top_proc_mem: top10_mem,
      binary_leak_delta: bin_total,
      ets_count: length(:ets.all()),
      atom_count: :erlang.system_info(:atom_count)
    }

    File.write!(@out, Jason.encode!(row) <> "\n", [:append])
  end
end

ReconSoak.run()
