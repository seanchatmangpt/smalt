defmodule Smalt.Test.Internal.TraceSessionCourtTest do
  @moduledoc """
  AR-OBS-01 court (v26.10.21, IMPL-4): isolated multi-session tracing via
  `trace:session_create/3` (OTP 27+ session API; the session is the FIRST
  argument of `trace:process/4` and `trace:function/4` — kernel trace.erl).

  Three legs, all on real collaborators:

  1. **Isolation gate (ARD gate, N=2 concurrent courts)**: two ExUnit-async
     tests each open their own trace session over the SAME traced function
     (`Smalt.EgressRouter.egress_cors/2` invoked through the real
     `Smalt.EgressRouter.call/2` plug pipeline), while a 20-task concurrent
     cosmos-path workload runs. Each session records ALL matching events
     (20/20) with zero cross-drop, because session flag/filters are
     independent — the inverse of the old global-trace collision where one
     court's trace_pattern invalidated another's.

  2. **Zero cross-drop cross-check**: both sessions' counts equal the number
     of workload requests issued (20), so neither session dropped frames and
     neither observed the other's bookkeeping.

  3. **TRACEBUG boundary pin**: ERTS drops call-trace events whose
     destination IS the traced process (destination-based suppression; root
     cause of the v26.10.20 TRACEBUG,
     docs/jira/v26.10.20/receipts/tracebug-mixtest-tracing.md).
     Session isolation does NOT fix it: a session whose tracer is self still
     records ZERO of the self-executed calls (negative leg), while the SAME
     session records the identical calls when executed on a separate worker
     (positive control). The court documents what isolation does not fix.

  Toolchain: repo standard OTP 29 (TOOLUP, .tool-versions erlang 29.1.2 /
  elixir 1.20.4-otp-29), MIX_BUILD_ROOT=_build-impl4.
  """

  use ExUnit.Case, async: true

  Code.require_file("poll_helper.exs", Path.join(__DIR__, "../internal"))

  alias Smalt.EgressRouter

  @tag :trace_session_court
  @tag timeout: 120_000
  test "AR-OBS-01 isolation gate: two concurrent sessions trace the same MFA with zero cross-drop (court A)" do
    isolation_gate(20)
  end

  @tag :trace_session_court
  @tag timeout: 120_000
  test "AR-OBS-01 isolation gate: two concurrent sessions trace the same MFA with zero cross-drop (court B)" do
    isolation_gate(20)
  end

  test "TRACEBUG boundary pin: self-traced process still drops its own events (destination-based)" do
    mfa = {EgressRouter, :queue_plane_route, 3}
    # Tracer MUST be self here: destination-based suppression only bites when
    # the event destination IS the traced process. Count in our own mailbox.
    name = String.to_atom("trace_bug_#{System.unique_integer([:positive])}")
    session = :trace.session_create(name, self(), [])

    try do
      # Flags: self (the suppressed destination) + all new/existing so the
      # positive-control worker (spawned below) is flagged in THIS session.
      assert :trace.process(session, self(), true, [:call]) >= 0
      assert :trace.process(session, :all, true, [:call]) >= 0
      # Arming matches zero clauses when the module is not loaded (same
      # witnessed class as arm/2 — ensure_loaded is the structural sync).
      {:module, _} = Code.ensure_loaded(elem(mfa, 0))
      assert :trace.function(session, mfa, [], [:local]) >= 1

      for i <- 1..5 do
        EgressRouter.queue_plane_route("GET", ["acc#{i}"], %{})
      end

      # Negative leg: zero of self's own events — the trap that made
      # "tracing under mix test" look inert (v26.10.20 TRACEBUG). Bounded
      # deadline-checked absence window (the one lawful shape of an
      # absence assertion): nothing arrives, so nothing is counted.
      assert mailbox_events(250) == 0,
             "self-traced events must be suppressed (destination-based drop)"

      # Positive control on the SAME session: a separate worker executing the
      # identical calls DOES deliver — proves the zero above is destination
      # suppression, not a dead pattern or dead flags.
      # Plain spawn from the flagged test process (NOT Task.async: tasks run
      # under Task.Supervisor, so set_on_spawn from self never reaches them).
      parent = self()
      done = make_ref()

      worker =
        spawn(fn ->
          for i <- 1..5 do
            EgressRouter.queue_plane_route("GET", ["acc-ctl#{i}"], %{})
          end

          send(parent, {done, :ok})
        end)

      worker_done =
        receive do
          {^done, :ok} -> true
        after
          5_000 -> false
        end

      assert worker_done, "positive-control worker never finished"

      assert await_mailbox(5, 5_000) == 5,
             "same session must deliver worker-executed events (drop is destination-based)"
    after
      disarm(session)
    end
  end

  # Bounded receive-drain of OUR OWN mailbox (tracer = self leg): counts
  # matching events arriving within the window.
  defp mailbox_events(window_ms) do
    mailbox_events(window_ms, 0)
  end

  defp mailbox_events(window_ms, n) do
    receive do
      {:trace, _pid, :call, {EgressRouter, :queue_plane_route, _args}} ->
        mailbox_events(window_ms, n + 1)
    after
      window_ms -> n
    end
  end

  # Bounded poll until target matching events have arrived (deadline-checked,
  # audited-poll shape over the mailbox observable).
  defp await_mailbox(target, budget) do
    n = mailbox_events(0)

    if n >= target do
      n
    else
      case SmaltTest.Internal.Poll.eventually(
             fn ->
               m = mailbox_events(0)
               if n + m >= target, do: {:ok, n + m}, else: :waiting
             end,
             timeout_ms: budget,
             poll_ms: 25
           ) do
        {:ok, total} -> total
        {:timeout, _} -> flunk("mailbox count never reached #{target}")
      end
    end
  end

  # -- isolation gate body (one court) -----------------------------------------

  defp isolation_gate(workload) do
    mfa = {EgressRouter, :egress_cors, 2}
    {:ok, ta, sa} = open_session()
    {:ok, tb, sb} = open_session()

    try do
      arm(sa, mfa)
      arm(sb, mfa)

      # 20 concurrent cosmos-path ops through the real egress plug pipeline.
      # Status/halt are whatever the plane answers (200/401/404/503 all prove
      # the router ran); the court's claim is about EVENT DELIVERY.
      results =
        1..workload
        |> Task.async_stream(fn _ ->
          conn =
            Plug.Test.conn(:get, "/dbs/trace-court-#{System.unique_integer([:positive])}")

          conn = EgressRouter.call(conn, [])
          {conn.status, conn.halted}
        end)
        |> Enum.to_list()
        |> Enum.map(fn {:ok, v} -> v end)

      assert length(results) == workload
      assert Enum.all?(results, fn {status, _} -> is_integer(status) end)

      # Bounded poll on the real observable (tracer counters), no fixed sleep.
      ca = await_count(ta, workload, 5_000)
      cb = await_count(tb, workload, 5_000)

      # Zero cross-drop: BOTH sessions recorded ALL matching events.
      assert ca == workload, "session A recorded #{ca}/#{workload} events (cross-drop)"
      assert cb == workload, "session B recorded #{cb}/#{workload} events (cross-drop)"

      # Cross-talk poison check: session A still alive and delivering AFTER
      # session B's bookkeeping exists — order-independent isolation.
      warmup =
        1..5
        |> Task.async_stream(fn _ ->
          conn = Plug.Test.conn(:get, "/dbs/trace-court-warm-#{System.unique_integer()}")
          conn = EgressRouter.call(conn, [])
          conn.status
        end)
        |> Enum.to_list()
        |> Enum.map(fn {:ok, v} -> v end)

      assert length(warmup) == 5
      assert await_count(ta, workload + 5, 5_000) == workload + 5
      assert await_count(tb, workload + 5, 5_000) == workload + 5
    after
      disarm(sa)
      disarm(sb)
    end
  end

  # -- session helpers ---------------------------------------------------------

  # A dedicated counting tracer per session: with tracer = self() for BOTH
  # sessions the events would be indistinguishable in one mailbox; a per-
  # session counter keeps the courts' books separate. Tail-recursive count,
  # replies to {get, from} on demand and keeps counting.
  defp open_session do
    parent = self()

    counter =
      Task.async(fn ->
        count_loop(0, parent)
      end)

    name = String.to_atom("trace_court_#{System.unique_integer([:positive])}")
    session = :trace.session_create(name, counter.pid, [])
    {:ok, counter, session}
  end

  defp count_loop(n, parent) do
    receive do
      {:trace, _pid, :call, _mfa} -> count_loop(n + 1, parent)
      {:get, from} ->
        send(from, {:count, n})
        count_loop(n, parent)
      _other -> count_loop(n, parent)
    end
  end

  defp get_count(counter) do
    send(counter.pid, {:get, self()})
    receive do
      {:count, n} -> n
    after
      2_000 -> :timeout
    end
  end

  # Session-scoped arm: flags on all processes + local match-all pattern.
  defp arm(session, mfa) do
    # :trace.function arming matches ZERO clauses when the target module is
    # not loaded (witnessed: census 2026-10-25 — arm/2 returned 0 for
    # {EgressRouter, :egress_cors, 2} when the court ran before any test had
    # loaded the router; ensure_loaded makes the arm structural, not
    # order-dependent).
    {:module, _} = Code.ensure_loaded(elem(mfa, 0))
    assert :trace.process(session, :all, true, [:call, :set_on_spawn]) >= 0
    assert :trace.function(session, mfa, [], [:local]) >= 1
    :ok
  end

  defp disarm(session) do
    _ = :trace.process(session, :all, false, [:call, :set_on_spawn])
    _ = :trace.function(session, {EgressRouter, :_, :_}, false, [:local])
    _ = :trace.session_destroy(session)
    :ok
  end

  # Bounded observable poll via the audited poll helper (no-sleep doctrine):
  # observe the tracer counter until it reaches target or deadline passes.
  defp await_count(counter, target, timeout_ms) do
    case SmaltTest.Internal.Poll.eventually(
           fn ->
             n = get_count(counter)
             if n >= target, do: {:ok, n}, else: :waiting
           end,
           timeout_ms: timeout_ms,
           poll_ms: 25
         ) do
      {:ok, n} -> n
      {:timeout, last} -> flunk("count never reached #{target}: last=#{inspect(last)}")
    end
  end
end
