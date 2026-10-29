defmodule PopcornDemo.TraceReproTest do
  @moduledoc """
  TRACEBUG minimal repro + positive control for the Z1-witnessed defect:
  `:erlang.trace_pattern({M,F,A}, _, [:local])` seemingly produced ZERO trace
  events under `mix test` while "the same" code traced fine under `mix run`.

  ROOT CAUSE (not ExUnit, not compile-strip, not an OTP-29 regression): a
  process NEVER receives `:call` trace events for its own execution. ERTS
  drops trace messages whose destination is the traced process itself
  (verified identical on OTP 28.3.1 and 29.0.6 — longstanding behavior, not a
  regression). The `mix test` witness set `:erlang.trace(self(), true,
  [:call])` on the ExUnit runner process and then called the traced functions
  ON that process — every event was destined for the traced process itself
  and silently discarded. "flags verified set, matched=16" is exactly the
  observable surface: pattern + flags are real, delivery is suppressed. The
  `mix run`/`erl` comparisons that traced fine used a spawned worker or a
  tracer fun — i.e. a tracer pid different from the traced pid.

  ExUnit-safe pattern (proven below): spawn the work on a worker pid, spawn a
  dedicated tracer process, trace the worker with `{tracer, TracerPid}`, and
  set the pattern with DEFAULT flags (empty flag list == local+global; on
  OTP 29 the explicit list `[:local, :global]` raises badarg — flags are
  per-call).

  Legs:
    A. self-as-tracer, self-calls         -> NONE (negative control, the trap)
    B. worker + separate tracer + pattern -> events (the working pattern)
    C. worker + separate tracer, no ACTIVE pattern -> NONE (control: a call
       trace with no matching pattern traces nothing; trace_pattern is
       required. Patterns are node-global and leak across tests, so the leg
       pauses the MFA explicitly (MatchSpec=false) rather than assuming a clean slate).
  """
  use ExUnit.Case, async: false

  defmodule Target do
    def ping, do: :pong
  end

  @tag :tracebug
  test "A: self-as-tracer drops its own call events (negative control)" do
    me = self()
    assert 1 = :erlang.trace_pattern({Target, :ping, 0}, [])
    _traced = :erlang.trace(me, true, [:call])

    assert :pong = Target.ping()
    :erlang.trace(me, false, [:call])

    refute events?(me, 300), "if this ever fires, ERTS changed the self-tracer rule"
  end

  @tag :tracebug
  test "B: worker pid + separate tracer process yields call events (working pattern)" do
    # 1. dedicated tracer process forwards every event back tagged with a ref
    report_to = self()
    ref = make_ref()
    {:ok, tracer_pid} = Task.start(fn -> tracer_loop(report_to, ref) end)

    # 2. worker does the traced calls OFF the ExUnit process
    parent = self()

    worker =
      spawn(fn ->
        receive do
          :go ->
            tab = :ets.new(:tracebug_b, [:public])
            :ets.insert(tab, {1, 1})
            _ = Target.ping()
            send(parent, :worker_done)
        end
      end)

    # 3. pattern with default flags (== local+global; do NOT pass the
    #    combined list, OTP 29 badargs on it)
    assert 1 = :erlang.trace_pattern({:ets, :insert, 2}, [])
    assert 1 = :erlang.trace_pattern({Target, :ping, 0}, [])

    traced = :erlang.trace(worker, true, [:call, {:tracer, tracer_pid}])
    assert traced >= 1

    send(worker, :go)
    assert_receive :worker_done, 5_000
    events = collect(300)

    :erlang.trace_pattern({:ets, :insert, 2}, false)
    :erlang.trace_pattern({Target, :ping, 0}, false)

    assert mf_seen?(events, :ets, :insert, 2) and mf_seen?(events, Target, :ping, 0),
           "leg B: expected call events for both M:F/A via separate tracer, " <>
             "got: #{inspect(Enum.take(events, 5))}"
  end

  @tag :tracebug
  test "C: trace without any trace_pattern yields zero events (control)" do
    report_to = self()
    ref = make_ref()
    {:ok, tracer_pid} = Task.start(fn -> tracer_loop(report_to, ref) end)

    parent = self()

    worker =
      spawn(fn ->
        receive do
          :go ->
            tab = :ets.new(:tracebug_c, [:public])
            :ets.insert(tab, {1, 1})
            send(parent, :worker_done)
        end
      end)

    # no ACTIVE pattern for this MFA: pause anything leaked from sibling
    # tests (patterns are node-global and outlive their test)
    :erlang.trace_pattern({:ets, :insert, 2}, false)

    traced = :erlang.trace(worker, true, [:call, {:tracer, tracer_pid}])
    assert traced >= 1

    send(worker, :go)
    assert_receive :worker_done, 5_000
    events = collect(300)

    refute mf_seen?(events, :ets, :insert, 2),
           "leg C: unexpected events with no active pattern — got: " <> inspect(Enum.take(events, 5))
  end

  # -- plumbing --------------------------------------------------------------

  defp tracer_loop(report_to, ref) do
    receive do
      {:trace, _, :call, mfa} ->
        send(report_to, {ref, {:call, mfa}})
        tracer_loop(report_to, ref)

      :stop ->
        :ok
    end
  end

  defp collect(_timeout) do
    collect_loop([])
  end

  defp collect_loop(acc) do
    receive do
      {_, ev} -> collect_loop([ev | acc])
    after
      300 -> Enum.reverse(acc)
    end
  end

  defp events?(pid, timeout) do
    receive do
      {:trace, ^pid, :call, _} -> true
    after
      timeout -> false
    end
  end

  defp mf_seen?(events, m, f, arity) do
    Enum.any?(events, fn
      {:call, {^m, ^f, args}} when is_list(args) -> length(args) == arity
      {:call, {^m, ^f, ^arity}} -> true
      _ -> false
    end)
  end
end
