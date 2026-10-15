#!/usr/bin/env mix run
# Telemetry overhead A/B stress driver (see docs/STRESS/TELEMETRY.md).
#
# Runs inside `mix run` (app boots: Bandit ARM listener, RollingCounters child).
# Modes (env SMALT_STRESS_MODE):
#   a — prod wiring: Smalt.Telemetry.attach() + RollingCounters running
#   b — attach disabled: :telemetry.detach("smalt-telemetry") after boot
#   c — attach + DUMP under load: 64 parallel emitter lanes hammering
#       Smalt.Telemetry.admit/refuse (which funnel through the RollingCounters
#       GenServer) concurrent with the timed PUTs; Smalt.Telemetry.dump()
#       latency sampled mid-load; plus an ETS micro-court: GenServer-mediated
#       update_counter vs direct public-ETS update_counter from 64 tasks.
#
# Prints exactly one RESULT_JSON line to stdout for the python runner.

mode = System.get_env("SMALT_STRESS_MODE", "a")
n_puts = String.to_integer(System.get_env("SMALT_STRESS_PUTS", "5000"))

[:inets, :ssl] |> Enum.each(fn app ->
  case Application.ensure_all_started(app) do
    {:ok, _} -> :ok
    other -> throw({:app_start_failed, app, other})
  end
end)

# Boot the app ourselves (--no-start): runtime port overrides so the stress
# run never collides with a live substrate instance holding 9443/5672/8443.
# Every port is a probed-free ephemeral port (bind 0, close, then hand to the
# app) — same pattern as config/test.exs — or SMALT_STRESS_*_PORT when set.
free_port = fn default ->
  case System.get_env("SMALT_STRESS_ARM_PORT") do
    nil ->
      {:ok, p} = :gen_tcp.listen(0, [])
      {:ok, port} = :inet.port(p)
      :ok = :gen_tcp.close(p)
      port

    env ->
      String.to_integer(env)
  end
end

port = free_port.(nil)
:ok = Application.put_env(:smalt, :arm_port, port)
:ok = Application.put_env(:smalt, :arm_tls_port, free_port.(nil))
:ok = Application.put_env(:smalt, :egress_port, free_port.(nil))
:ok = Application.put_env(:smalt, :amqp_port, free_port.(nil))
:ok = Application.put_env(:smalt, :event_hubs_port, free_port.(nil))
{:ok, _} = Application.ensure_all_started(:smalt)
base = "http://127.0.0.1:#{port}"

unless mode == "b" do
  Smalt.Telemetry.attach()
end

if mode == "b" do
  case :telemetry.detach("smalt-telemetry") do
    :ok -> :ok
    {:error, :not_found} -> :ok
  end
end

# Wait for the ARM listener (up to ~20s).
wait_up = fn wait ->
  case :httpc.request(:head, {~c"#{base}/", []}, [timeout: 1000, connect_timeout: 1000], []) do
    {:ok, _} -> :ready
    {:error, _} -> Process.sleep(100) && wait.(wait)
  end
end

(wait_up.(wait_up) == :ready) || raise("ARM listener never came up on #{port}")

# Mint a bearer token via the gateway's own OAuth2 token endpoint, then send
# it as `Authorization: Bearer ...` on every PUT (Smalt.Auth.Bearer plug).
{:ok, {{_v, 200, _r}, _h, tok_body}} =
  :httpc.request(:post, {~c"#{base}/oauth2/v2.0/token", [], ~c"application/x-www-form-urlencoded", ~c""}, [timeout: 10_000], [{:sync, true}])

%{"access_token" => token} = Jason.decode!(tok_body)
auth_header = {~c"authorization", ~c"Bearer #{token}"}

url = ~c"#{base}/subscriptions/00000000-0000-0000-0000-000000000000/resourcegroups/stress-rg?api-version=2020-06-01"
headers = [auth_header, {~c"content-type", ~c"application/json"}]
body = ~c"{\"location\":\"eastus\",\"tags\":{\"stress\":\"true\"}}"
req = {url, headers, ~c"application/json", body}

put_once = fn ->
  case :httpc.request(:put, req, [timeout: 10_000, connect_timeout: 5_000], []) do
    {:ok, {{_v, status, _r}, _h, _b}} when status in 200..299 -> :ok
    other -> throw({:put_error, other})
  end
end

# Warmup (untimed): 250 PUTs.
for _ <- 1..250, do: (put_once.() == :ok) || throw(:warmup_failed)

# Mode c load: 64 emitter lanes spinning admit/refuse until told to stop.
if mode == "c" do
  parent = self()

  lanes =
    for _lane <- 1..64 do
      {:ok, pid} =
        Task.start(fn ->
          stop? = fn ->
            receive do
              {:stop, ^parent} -> true
            after
              0 -> false
            end
          end

          emit_loop = fn loop ->
            unless stop?.() do
              int = System.unique_integer([:positive])

              if rem(int, 2) == 0 do
                :ok = Smalt.Telemetry.admit(:ok, route: "/stress")
              else
                :ok = Smalt.Telemetry.refuse(:STRESS_REFUSE, route: "/stress")
              end

              loop.(loop)
            end
          end

          emit_loop.(emit_loop)
        end)

      pid
    end

  Process.sleep(500)

  :persistent_term.put({__MODULE__, :stress_lanes}, lanes)
end

## Timed phase: n_puts sequential ARM PUTs.

t0 = System.monotonic_time(:millisecond)

for _ <- 1..n_puts do
  (put_once.() == :ok) || throw(:put_failed)
end

t1 = System.monotonic_time(:millisecond)
elapsed_ms = t1 - t0

## Mode c extras: dump latency under load, then stop lanes.

dump_sample =
  if mode == "c" do
    samples =
      for _ <- 1..20 do
        s = System.monotonic_time(:millisecond)
        _ = Smalt.Telemetry.dump()
        System.monotonic_time(:millisecond) - s
      end

    %{dump_total_ms: Enum.sum(samples), dump_max_ms: Enum.max(samples), dump_n: 20}
  else
    %{dump_total_ms: 0, dump_max_ms: 0, dump_n: 0}
  end

if mode == "c" do
  for pid <- :persistent_term.get({__MODULE__, :stress_lanes}, []) do
    send(pid, {:stop, self()})
  end

  Process.sleep(200)
end

## ETS micro-court (all modes): GenServer-mediated RollingCounters.bump vs
## direct public-ETS :ets.update_counter, 64 tasks x 20_000 bumps each.

ets_court = fn ->
  table = :ets.new(:stress_direct_counters, [:set, :public, write_concurrency: true])
  per_task = 20_000
  minute = System.system_time(:millisecond) |> div(60_000)

  bench = fn bump_fun ->
    t0 = System.monotonic_time(:millisecond)

    tasks =
      for lane <- 1..64 do
        Task.async(fn ->
          for i <- 1..per_task do
            bump_fun.({minute, {lane, i}, :self})
          end
        end)
      end

    Task.await_many(tasks, 120_000)
    System.monotonic_time(:millisecond) - t0
  end

  gs_ms = bench.(fn full_key -> Smalt.Telemetry.RollingCounters.bump(full_key) end)

  direct_ms =
    bench.(fn {m, k, tag} ->
      full_key = {m, k, tag}

      :ets.update_counter(table, full_key, {2, 1}, {full_key, 0})
    end)

  %{genserver_bump_ms: gs_ms, direct_ets_ms: direct_ms, per_task: per_task, lanes: 64}
end.()

result = %{
  mode: mode,
  puts: n_puts,
  elapsed_ms: elapsed_ms,
  per_put_ms: Float.round(elapsed_ms / n_puts, 4),
  dump: dump_sample,
  ets_court: ets_court
}

IO.puts("RESULT_JSON: " <> Jason.encode!(result))
System.halt(0)
