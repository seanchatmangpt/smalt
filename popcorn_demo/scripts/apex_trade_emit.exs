# APEX-1 bench emitter — runs the apex settlement scenario 5 times and appends
# one JSONL row per run to bench/apex_trade.jsonl (popcorn_demo bench dir, same
# convention as bench/scvd.jsonl). Lane-owned artifact, not a bench-lane jsonl
# under docs/jira (no shared-infra writes).
#
# Run: MIX_BUILD_ROOT=_build-apex1 mix run scripts/apex_trade_emit.exs

{cpu_out, 0} = System.cmd("/usr/sbin/sysctl", ["-n", "machdep.cpu.brand_string"])
{cores_out, 0} = System.cmd("/usr/sbin/sysctl", ["-n", "hw.ncpu"])
{ram_out, 0} = System.cmd("/usr/sbin/sysctl", ["-n", "hw.memsize"])

machine = %{
  cpu: String.trim(cpu_out),
  cores: String.trim(cores_out) |> String.to_integer(),
  ram_gb: String.trim(ram_out) |> String.to_integer() |> div(1024 ** 3),
  elixir: System.version(),
  otp: :erlang.system_info(:otp_release) |> to_string()
}

IO.inspect(machine, label: "MACHINE")

# warmup (not emitted)
assert_warm = fn ->
  case PopcornDemo.ApexTrade.run() do
    {:ok, _} -> :ok
    other -> raise "warmup run failed: #{inspect(other)}"
  end
end

assert_warm.()

for run <- 1..5 do
  {:ok, r} =
    case PopcornDemo.ApexTrade.run() do
      {:ok, r} -> {:ok, r}
      other -> raise "apex run #{run} failed: #{inspect(other)}"
    end

  settle_ms = max(r.wall_ms - r.sign.wall_ms - r.cas.wall_ms, 0)

  row = %{
    lane: "apex-1",
    surface: "kv.sign+ets.cas+eh.amqp",
    op: "settlement_gate",
    n: r.actors,
    wall_ms: r.wall_ms,
    sign_ms: r.sign.wall_ms,
    sign_alg: r.sign.alg,
    sig_bytes: r.sign.sig_bytes,
    cas_ms: r.cas.wall_ms,
    settle_ms: settle_ms,
    winners: r.cas.winners,
    losers: r.cas.losers,
    committed: r.cas.committed,
    final_version: r.cas.final_version,
    actor_mem_bytes: r.cas.actor_mem_bytes,
    exceptions: r.exceptions,
    errors: 0,
    machine: machine,
    run: run
  }

  File.write!("bench/apex_trade.jsonl", Jason.encode!(row) <> "\n", [:append])
  IO.puts("run #{run}: wall=#{row.wall_ms}ms sign=#{row.sign_ms}ms cas=#{row.cas_ms}ms settle=#{row.settle_ms}ms")
end

IO.puts("emitted 5 rows -> bench/apex_trade.jsonl")
