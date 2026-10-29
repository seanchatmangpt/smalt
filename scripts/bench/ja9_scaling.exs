# ja9_scaling.exs — JA-9 Joe Armstrong scaling-envelope lane (v26.10.21, OTP-29).
# Node-global envelope lane: process ceiling, connection scaling, scheduler
# utilization under tier-1 wire load, honest ceiling. No caller-heap claims,
# so the AR-BENCH-02 node-global ban does not apply (its subject is fences).
# Boot: private substrate in-node on 39440..39445 (ja9 block, verified free);
# the shared substrate is never touched.
# Run: MIX_ENV=test MIX_BUILD_ROOT=_build-ja9 PATH="<otp29 first>" \
#      mix run --no-start scripts/bench/ja9_scaling.exs
# Out: tmp/bench/ja9-scaling.jsonl, schema
#      {lane, surface, op, n, ops_per_sec, p50_ms, p95_ms, p99_ms, errors, machine}

# Repo root: cwd when run via mix run from the checkout root
repo_root = File.cwd!()
out = Path.join(repo_root, "tmp/bench/ja9-scaling.jsonl")
File.mkdir_p!(Path.dirname(out))
File.rm(out)

ports = %{arm: 39440, egress: 39441, amqp: 39442, ehub: 39443, arm_tls: 39444, mcp: 39445}

cpu = System.cmd("sysctl", ["-n", "machdep.cpu.brand_string"]) |> elem(0) |> String.trim()

cores =
  System.cmd("sysctl", ["-n", "hw.ncpu"]) |> elem(0) |> String.trim() |> String.to_integer()

ram_gb =
  System.cmd("sysctl", ["-n", "hw.memsize"])
  |> elem(0)
  |> String.trim()
  |> String.to_integer()
  |> div(1_073_741_824)

machine =
  Jason.encode!(%{
    cpu: cpu,
    cores: cores,
    ram_gb: ram_gb,
    elixir: System.version(),
    otp: List.to_string(:erlang.system_info(:otp_release)),
    darwin: String.trim(elem(System.cmd("sw_vers", ["-productVersion"]), 0))
  })

emit = fn surface, op, n, ops_per_sec, p50, p95, p99, errors ->
  row =
    Jason.encode!(%{
      lane: "ja9",
      surface: surface,
      op: op,
      n: n,
      ops_per_sec: ops_per_sec,
      p50_ms: p50,
      p95_ms: p95,
      p99_ms: p99,
      errors: errors,
      machine: machine
    })

  File.write!(out, row <> "\n", [:append])
  IO.puts("[ja9] #{surface}/#{op} n=#{n} ops=#{ops_per_sec} p50=#{p50} p95=#{p95} p99=#{p99} err=#{errors}")
end

Application.put_env(:smalt, :arm_port, ports.arm)
Application.put_env(:smalt, :egress_port, ports.egress)
Application.put_env(:smalt, :amqp_port, ports.amqp)
Application.put_env(:smalt, :event_hubs_port, ports.ehub)
Application.put_env(:smalt, :arm_tls_port, ports.arm_tls)
Application.put_env(:smalt, :mcp_port, ports.mcp)
{:ok, _} = Application.ensure_all_started(:smalt)
IO.puts("[ja9] substrate up on 39440..39445 (MIX_ENV=test, anonymous)")

defmodule Ja9 do
  def now_ms, do: System.monotonic_time(:millisecond)

  def pct([], _), do: 0

  def pct(v, p) do
    s = Enum.sort(v)
    Enum.at(s, round(p / 100 * (length(s) - 1)))
  end

  def poll(deadline_ms, fun), do: do_poll(now_ms() + deadline_ms, fun)

  defp do_poll(deadline, fun) do
    case fun.() do
      {:ok, val} -> {:ok, val}
      _ ->
        if now_ms() < deadline do
          Process.sleep(50)
          do_poll(deadline, fun)
        else
          :timeout
        end
    end
  end

  def spawn_batches(target, batch) do
    t0 = now_ms()
    cnt0 = :erlang.system_info(:process_count)
    do_batches(target, batch, cnt0, [], [], 0, 0, 0)
  end

  # Plateau-driven: stop when process_count reaches limit-headroom, or a batch
  # stops adding survivors (spawn over the limit silently fails at the
  # emulator; the logger error flood is the only symptom, hence silenced).
  defp do_batches(target, batch, prev_cnt, pids, batch_ms, errs, max_rq, plateau) do
    b0 = now_ms()

    spawned_this_batch =
      Enum.reduce_while(1..batch, 0, fn _i, n ->
        try do
          spawn(fn ->
            Process.put(:ja9_trivial, true)
            receive do
            after
              :infinity -> :ok
            end
          end)

          {:cont, n + 1}
        rescue
          SystemLimitError -> {:halt, n}
        end
      end)


    bdt = now_ms() - b0
    cnt = :erlang.system_info(:process_count)
    delta = cnt - prev_cnt
    rq = :erlang.statistics(:run_queue)
    errs = errs + max(batch - spawned_this_batch, 0)
    pids = pids # procs are anonymous; teardown uses process_count poll
    batch_ms = [bdt | batch_ms]
    max_rq = max(rq, max_rq)

    if cnt >= target or delta <= 100 or plateau >= 2 do
      {pids, Enum.reverse(batch_ms), errs, max_rq}
    else
      plateau = if delta < batch / 2 do
        plateau + 1
      else
        0
      end
      do_batches(target, batch, cnt, pids, batch_ms, errs, max_rq, plateau)
    end
  end

  # Spawned procs carry a :ja9_trivial pdict marker (spawn/1 at 262k scale
  # keeps no pid list); teardown kills only marker-holders.
  def teardown_trivial do
    :erlang.processes()
    |> Enum.each(fn p ->
      case :erlang.process_info(p, :dictionary) do
        {:dictionary, dict} ->
          if :proplists.get_value(:ja9_trivial, dict, false) == true do
            Process.exit(p, :kill)
          end

        _ ->
          :ok
      end
    end)
  end

  def spawn_trivial do
    try do
      spawn(fn -> receive do after :infinity -> :ok end end)
    rescue
      _ -> :error
    catch
      _, _ -> :error
    end
  end

  def kill_all(pids), do: Enum.each(pids, &Process.exit(&1, :kill))

  def echo_listen(port) do
    {:ok, l} = :gen_tcp.listen(port, [:binary, {:packet, :raw}, {:active, false}, {:reuseaddr, true}, backlog: 4096])

    for _ <- 1..16 do
      spawn(fn -> accept_loop(l) end)
    end

    l
  end

  defp accept_loop(l) do
    case :gen_tcp.accept(l, :infinity) do
      {:ok, sock} ->
        spawn(fn -> echo_serve(sock) end)
        accept_loop(l)

      {:error, _} ->
        :ok
    end
  end

  defp echo_serve(sock) do
    case :gen_tcp.recv(sock, 4, 10_000) do
      {:ok, "ping"} ->
        :gen_tcp.send(sock, "pong")
        echo_serve(sock)

      _ ->
        :gen_tcp.close(sock)
    end
  end

  # n concurrent clients: connect + echo + close; returns {lat_ms, oks, errs, wall_ms}
  def run_conns(port, n) do
    parent = self()
    wall0 = now_ms()

    tasks =
      for i <- 1..n do
        src = {127, 0, 0, 1}

        spawn(fn ->
          t0 = now_ms()

          r =
            with {:ok, sock} <- connect_src(port, src, 5_000),
                 :ok <- :gen_tcp.send(sock, "ping"),
                 {:ok, "pong"} <- :gen_tcp.recv(sock, 4, 5_000) do
              :gen_tcp.close(sock)
              :ok
            else
              _ -> :error
            end

          send(parent, {self(), r, now_ms() - t0})
        end)
      end

    results = Enum.map(tasks, fn t -> receive do {^t, r, ms} -> {r, ms} end end)
    wall = now_ms() - wall0
    lat = for {:ok, ms} <- results, do: ms / 1
    errs = Enum.count(results, fn {r, _} -> r == :error end)
    {lat, length(lat), errs, wall}
  end

  def swt do
    case :erlang.statistics(:scheduler_wall_time) do
      :undefined -> :undefined
      swt -> Map.new(swt, fn {id, active, total} -> {id, {active, total}} end)
    end
  end

  def swt_util(nil, _cur), do: []

  def swt_util(prev, cur) do
    Enum.map(prev, fn {id, {a0, t0}} ->
      {a1, t1} = Map.fetch!(cur, id)
      da = a1 - a0
      dt = t1 - t0
      {id, if(dt > 0, do: Float.round(da / dt * 100, 1), else: 0.0)}
    end)
  end

  # OTP-29 divergence: erlang:statistics(scheduler_utilization/_totals) is
  # REMOVED (badarg, witnessed on 29.1.2). Substitute: msacc microstate
  # accounting — per-scheduler-thread busy fraction over a sample window.
  def msacc_util(ms) do
    :msacc.start(ms)

    :msacc.stats()
    |> Enum.filter(fn t -> elem(t, 0) == :scheduler end)
    |> Enum.map(fn {_type, id, counters} ->
      total = counters |> Enum.map(fn {_st, us} -> us end) |> Enum.sum()

      idle = :proplists.get_value(:idle, counters, 0)

      busy_pct =
        if total > 0, do: Float.round((total - idle) / total * 100, 1), else: 0.0

      {id, busy_pct}
    end)
    |> Enum.sort()
  end

  def connect_src(port, src_ip, timeout_ms) do
    :gen_tcp.connect(
      ~c"127.0.0.1",
      port,
      [:binary, {:packet, :raw}, {:active, false}, {:ip, src_ip}, {:linger, {true, 0}}],
      timeout_ms
    )
  end

  # wire load: workers doing blob PUTs until deadline; returns {ops, ms, lat}
  def run_wire_load(port, workers, deadline_ms) do
    parent = self()
    body = String.duplicate("x", 4096)
    t_end = now_ms() + deadline_ms
    t0 = now_ms()

    pids =
      for w <- 1..workers do
        spawn(fn ->
          loop_put(parent, port, body, w, t_end, 0, [])
        end)
      end

    results =
      Enum.flat_map(pids, fn p ->
        receive do
          {^p, ops, lat} -> lat
        end
      end)

    {length(results), now_ms() - t0, results}
  end

  defp loop_put(parent, port, body, w, t_end, ops, lat) do
    if now_ms() < t_end do
      case blob_put(port, "ja9c", "b#{w}", body, 5_000) do
        {:ok, ms} -> loop_put(parent, port, body, w, t_end, ops + 1, [ms | lat])
        _ -> loop_put(parent, port, body, w, t_end, ops, lat)
      end
    else
      send(parent, {self(), ops, Enum.reverse(lat)})
    end
  end

  def blob_put(port, container, blob, body, timeout_ms) do
    req =
      "PUT /#{container}/#{blob} HTTP/1.1\r\n" <>
        "Host: 127.0.0.1:#{port}\r\n" <>
        "x-ms-blob-type: BlockBlob\r\n" <>
        "x-ms-version: 2021-06-08\r\n" <>
        "Content-Length: #{byte_size(body)}\r\n" <>
        "Connection: close\r\n\r\n" <> body

    t0 = now_ms()

    with {:ok, sock} <- :gen_tcp.connect(~c"127.0.0.1", port, [:binary, {:packet, :raw}, {:active, false}], timeout_ms),
         :ok <- :gen_tcp.send(sock, req),
         {:ok, resp} <- :gen_tcp.recv(sock, 0, timeout_ms) do
      :gen_tcp.close(sock)

      if resp =~ "201" do
        {:ok, now_ms() - t0}
      else
        {:error, :status}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end
end

IO.puts("[ja9] === face 1: process ceiling ===")
Logger.configure(level: :emergency)

base_procs = :erlang.system_info(:process_count)
proc_limit = :erlang.system_info(:process_limit)
target = proc_limit - 256
try do
  # Face 1 runs at the spec's 262,144 (26% of this node's 1,048,576 limit).
# The full-limit push was witnessed twice (runs 6+8): 1,048,576 procs,
# ~2.7 GiB process memory, ~1e6 spawns/s — then teardown of 1M procs kills
# the node's IO path (crash dump: tmp/bench/erl_crash_ja9.dump). Honest
# ceiling: the node survives 1M live procs but not their mass teardown.
{pids, batch_ms, spawn_errors, max_rq} = Ja9.spawn_batches(min(proc_limit - 128, 262_144), 10_000)
mem_procs = :erlang.memory(:processes)
proc_count = :erlang.system_info(:process_count)
total_spawn_ms = Enum.sum(batch_ms)
mean_batch_ms = total_spawn_ms / max(length(batch_ms), 1)
spawn_rate = max(proc_count - base_procs, 1) / (total_spawn_ms / 1000)

IO.puts(
  "[ja9] ceiling: count=#{proc_count}/#{proc_limit} mem_procs_kib=#{div(mem_procs, 1024)} " <>
    "bytes_per_proc=#{div(mem_procs, max(proc_count - base_procs, 1))} " <>
    "spawn_rate=#{Float.round(spawn_rate, 1)}/s max_rq=#{max_rq} errors=#{spawn_errors}"
)

emit.("process_ceiling", "spawn_trivial_to_limit", proc_count, Float.round(spawn_rate, 1), mean_batch_ms,
  Ja9.pct(batch_ms, 95), Ja9.pct(batch_ms, 99), spawn_errors)

Ja9.teardown_trivial()

drain =
  Ja9.poll(60_000, fn ->
    if :erlang.system_info(:process_count) < base_procs + 2_000, do: {:ok, :drained}, else: :wait
  end)

IO.puts("[ja9] teardown poll: #{inspect(drain)}")
Logger.configure(level: :info)
rescue
  e ->
    IO.puts("[ja9] face1 CRASH: #{inspect(e)} " <> Exception.format_stacktrace(__STACKTRACE__))

    emit.("process_ceiling", "face1_crash", 0, 0.0, 0.0, 0.0, 0.0, 1)
end


IO.puts("[ja9] === face 2: connection scaling ===")
listener = Ja9.echo_listen(39_446)
mem0 = :erlang.memory(:processes)

smoke =
  with {:ok, s1} <- Ja9.connect_src(39_446, {127, 0, 0, 1}, 2_000),
       :ok <- :gen_tcp.send(s1, "ping"),
       {:ok, "pong"} <- :gen_tcp.recv(s1, 4, 2_000) do
    :gen_tcp.close(s1)
    :ok
  else
    other ->
      IO.puts("[ja9] echo smoke FAIL: #{inspect(other)}")
      :fail
  end

IO.puts("[ja9] echo smoke: #{inspect(smoke)}")

try do
  tiers =
    if smoke == :ok do
      Enum.reduce([1_000, 8_000, 32_000], :erlang.memory(:processes), fn n, mem_prev ->
        {lat, oks, errs, wall_ms} = Ja9.run_conns(39_446, n)
        mem_now = :erlang.memory(:processes)
        per_conn = div(mem_now - mem_prev, max(n, 1))

        IO.puts(
          "[ja9] conns n=#{n}: ok=#{oks} err=#{errs} wall=#{wall_ms}ms p50=#{Ja9.pct(lat, 50)}ms " <>
            "p95=#{Ja9.pct(lat, 95)}ms p99=#{Ja9.pct(lat, 99)}ms bytes_per_conn=#{per_conn}"
        )

        rate = if wall_ms > 0, do: Float.round(length(lat) / (wall_ms / 1000), 1), else: 0.0

        emit.("conn_scaling", "echo_connect_echo", n, rate,
          Ja9.pct(lat, 50), Ja9.pct(lat, 95), Ja9.pct(lat, 99), errs)

        :erlang.garbage_collect()
        mem_now
      end)
    else
      []
    end

rescue
  e ->
    IO.puts("[ja9] face2 CRASH: #{inspect(e)}")
    emit.("conn_scaling", "face2_crash", 0, 0.0, 0.0, 0.0, 0.0, 1)
end

IO.puts("[ja9] === face 3: scheduler utilization (tier-1 wire load) ===")

try do
  :erlang.system_flag(:scheduler_wall_time, true)
  _ = :erlang.statistics(:scheduler_wall_time)

  warm = Ja9.blob_put(39441, "ja9c", "warm", String.duplicate("x", 4096), 5_000)
  IO.puts("[ja9] blob warm-up: #{inspect(warm)}")

  s0 = Ja9.swt()
  Process.sleep(500) # SLEEP-CLASS: POLL-STEP — swt sampling window
  s1 = Ja9.swt()
  baseline = Ja9.swt_util(s0, s1)

  {ops, ms, lat} = Ja9.run_wire_load(39441, 16, 6_000)

  s2 = Ja9.swt()
  during = Ja9.swt_util(s1, s2)

  Process.sleep(1_000)
  s3 = Ja9.swt()
  after_util = Ja9.swt_util(s2, s3)

  :erlang.system_flag(:scheduler_wall_time, false)

  utils = Enum.map(during, fn {_id, u} -> u end)
  base_utils = Enum.map(baseline, fn {_id, u} -> u end)
  base_mean = Enum.sum(base_utils) / max(length(base_utils), 1)

  mean_u = Enum.sum(utils) / max(length(utils), 1)
  rate = Float.round(ops / (ms / 1000), 1)

  IO.puts(
    "[ja9] load ops=#{ops} in #{ms}ms rate=#{rate}/s " <>
      "sched_busy mean=#{Float.round(mean_u, 1)}% (baseline #{Float.round(base_mean, 1)}%) " <>
      "max=#{Float.round(Enum.max(utils), 1)}% min=#{Float.round(Enum.min(utils), 1)}%"
  )

  emit.("wire_load", "blob_put_16workers", ops, rate, Ja9.pct(lat, 50), Ja9.pct(lat, 95),
    Ja9.pct(lat, 99), 0)

  per_sched = during |> Enum.map(fn {id, u} -> "#{id}:#{u}%" end) |> Enum.join(" ")
  IO.puts("[ja9] per-scheduler busy during load: #{per_sched}")

  after_vals = Enum.map(after_util, fn {_id, u} -> u end)

  IO.puts(
    "[ja9] after load: busy mean=#{Float.round(Enum.sum(after_vals) / length(after_vals), 1)}% " <>
      "max=#{Float.round(Enum.max(after_vals), 1)}%"
  )
rescue
  e ->
    IO.puts("[ja9] face3 CRASH: #{inspect(e)}")
    emit.("wire_load", "face3_crash", 0, 0.0, 0.0, 0.0, 0.0, 1)
end

IO.puts("[ja9] === face 4: honest ceiling ===")
port_limit = :erlang.system_info(:port_limit)
port_count = :erlang.system_info(:port_count)
IO.puts("[ja9] ports now=#{port_count} limit=#{port_limit}")

try do
  # consecutive-timeout budget: a wedged listener is a harness fault, not a
  # ceiling witness; 20 x 200ms is the stall cap
  result4 =
    Enum.reduce_while(1..70_000, {[], 0, 0}, fn _i, {acc, e, streak} ->
      case Ja9.connect_src(39_446, {127, 0, 0, 1}, 200) do
        {:ok, s} ->
          {:cont, {[s | acc], e, 0}}

        {:error, :timeout} when streak < 20 ->
          {:cont, {acc, e, streak + 1}}

        {:error, reason} ->
          {:halt, {acc, e, reason}}
      end
    end)

  extra_list = elem(result4, 0)
  stop_reason = elem(result4, tuple_size(result4) - 1)
  opened4 = length(extra_list)
  ceiling_witnessed = stop_reason == :system_limit

  IO.puts(
    "[ja9] port push: opened=#{opened4} stop=#{inspect(stop_reason)} " <>
      "witnessed_system_limit=#{ceiling_witnessed}"
  )

  Enum.each(extra_list, fn s -> :gen_tcp.close(s) end)

  File.write!(
    out,
    Jason.encode!(%{
      lane: "ja9",
      surface: "honest_ceiling",
      op: "port_push_to_limit",
      n: port_limit,
      ops_per_sec: opened4,
      p50_ms: 0,
      p95_ms: 0,
      p99_ms: 0,
      errors: if(ceiling_witnessed, do: 1, else: 0),
      machine: machine
    }) <> "\n",
    [:append]
  )
rescue
  e ->
    IO.puts("[ja9] face4 CRASH: #{inspect(e)}")
end

:gen_tcp.close(listener)
IO.puts("[ja9] done")
System.halt(0)
