defmodule PopcornDemo.LiveScvd do
  @moduledoc """
  LANE S14-A — in-browser SCVD leg (Tier-1..3 of the PRD): actor fan-out +
  contention verification that runs entirely inside the wasm BEAM with zero
  egress BY CONSTRUCTION (the harness, `PopcornDemo.Concurrency`, spawns
  plain processes over deterministic in-memory walks and one public ETS
  table — no sockets, no fetch, no shared mutable state).

  One `run/0`:

    1. `Concurrency.ramp(16)`  — 16 isolated actors each run the
       deterministic three-module verification walk (CosmosSql / SbRules /
       Registry pins). Leg law: ALL n actors `:verified` AND zero
       `:invariance_breach`, else the leg FAILS loudly.
    2. `Concurrency.ramp(256)` — the Tier-3 rung (same law, all verified).
    3. `Concurrency.contention(32)` — 32 actors race 8 keys under
       optimistic CAS; the harness itself asserts the deterministic final
       ETS state (exactly one winner per key, loser partition exact) and
       returns `{:error, {:not_deterministic, per-key detail}}` on any
       deviation — surfaced as FAIL, never a coerced pass.
    4. `Concurrency.contention(128)` — the Tier-3 contention rung.
    5. `Concurrency.contention(256)` — the Tier-4 contention rung (T22).

  Each leg is bounded at a 15s envelope (a harness defect degrades to a
  loud typed FAIL, never a hang).

  The harness module is guarded with `Code.ensure_loaded?/1` (S1 owns
  `lib/popcorn_demo/concurrency.ex`): until it compiles the leg emits the
  loud typed skip `scvd=SKIP(harness-missing)` — never a fake pass.

  Receipts (run/0 return), house style:
    {:ok,    "scvd=OK(t16:<ms>ms,p99:<us>us;t256:<ms>ms,p99:<us>us;c128:<outcome>;c256:<outcome>)"}
    {:skip,  "scvd=SKIP(harness-missing)"}
    {:error, "scvd=FAIL(<step>:<reason>)"}

  `deep/0` is the OPTIONAL deep-ramp probe beyond the host Threshold Wall
  (host wall N=512; the wasm subject was untested beyond 256): ramp(512)
  then ramp(1024), each bounded at the leg budget with a loud typed
  `TIMEOUT@<n>` marker and skip to the next rung. run/0 is unchanged.

  Static-leg law: referenced literally from
  `PopcornDemo.Application.@static_legs` so the cooked bundle keeps it.
  Export `run/0` only (plus the optional `deep/0` probe).
  """

  @ramp_actors 16
  @ramp_actors_tier3 256
  @contention_actors 32
  @contention_actors_tier3 128
  @contention_actors_tier4 256
  @deep_rungs [512, 1024]

  # Leg budget: the composed receipt times legs at #{@leg_budget_ms}ms; the
  # leg itself is bounded under the same budget so a harness defect (S1's
  # ramp/1 receive loop has no timeout — a crashed actor never sends and the
  # parent blocks forever) degrades to a loud typed FAIL, never a hang.
  @leg_budget_ms 15_000

  @doc """
  Tier-1..3 SCVD: ramp(#{@ramp_actors}) + ramp(#{@ramp_actors_tier3}) +
  contention(#{@contention_actors_tier3}) + contention(#{@contention_actors_tier4}),
  fail-closed.
  """
  @spec run() :: {:ok, binary()} | {:skip, binary()} | {:error, binary()}
  def run do
    if Code.ensure_loaded?(PopcornDemo.Concurrency) do
      run_loaded()
    else
      {:skip, "scvd=SKIP(harness-missing)"}
    end
  end

  defp run_loaded do
    with {:ok, ramp16} <- bounded("ramp16", fn -> do_ramp(@ramp_actors) end),
         {:ok, ramp256} <- bounded("ramp256", fn -> do_ramp(@ramp_actors_tier3) end),
         {:ok, _c32} <- bounded("contention", fn -> do_contention(@contention_actors) end),
         {:ok, c128} <- bounded("contention128", fn -> do_contention(@contention_actors_tier3) end),
         {:ok, c256} <- bounded("contention256", fn -> do_contention(@contention_actors_tier4) end) do
      {:ok,
       "scvd=OK(t16:#{ramp16.wall_ms()}ms,p99:#{ramp16.p99_us()}us;" <>
         "t256:#{ramp256.wall_ms()}ms,p99:#{ramp256.p99_us()}us;" <>
         "c128:#{c128};" <>
         "c256:#{c256})"}
    end
  end

  @doc """
  Deep-ramp probe past the host wall: ramp(512) then ramp(1024), each
  bounded at the leg budget. A rung that misses the budget (or crashes)
  contributes a loud typed `TIMEOUT@<n>` (or `FAIL@<n>:<reason>`) marker and
  the probe skips to the next rung — never a hang, never a coerced pass.
  All rungs timed out => typed {:error, ...}, not an OK with all markers.

  Fragment shapes (single line, sanitized, run/0's receipt stays stable):
    {:ok,    "scvd-deep=OK(512:<ms>ms;1024:<ms>ms)"}
    {:ok,    "scvd-deep=OK(1024:<ms>ms|TIMEOUT@512)"}
    {:error, "scvd-deep=FAIL(all-rungs-missed-15s-budget)"}
    {:skip,  "scvd-deep=SKIP(harness-missing)"}
  """
  @spec deep() :: {:ok, binary()} | {:skip, binary()} | {:error, binary()}
  def deep do
    if Code.ensure_loaded?(PopcornDemo.Concurrency) do
      {parts, marks, oks} =
        Enum.reduce(@deep_rungs, {[], [], 0}, fn n, {parts, marks, oks} ->
          case bounded("deep-ramp#{n}", fn -> do_ramp(n) end) do
            {:ok, r} ->
              {["#{n}:#{r.wall_ms()}ms" | parts], marks, oks + 1}

            {:error, reason} ->
              mark =
                if reason =~ "timeout" do
                  "TIMEOUT@#{n}"
                else
                  "FAIL@#{n}:#{slice(reason)}"
                end

              {parts, [mark | marks], oks}
          end
        end)

      cond do
        oks == 0 and marks != [] ->
          {:error, "scvd-deep=FAIL(all-rungs-missed-#{div(@leg_budget_ms, 1000)}s-budget)"}

        marks == [] ->
          {:ok, "scvd-deep=OK(#{parts |> Enum.reverse() |> Enum.join(";")})"}

        true ->
          {:ok,
           "scvd-deep=OK(" <> Enum.join(Enum.reverse(parts) ++ Enum.reverse(marks), "|") <> ")"}
      end
    else
      {:skip, "scvd-deep=SKIP(harness-missing)"}
    end
  end

  # Bounded execution: each leg returns within ~15s.
  defp bounded(step, fun) do
    task = Task.async(fun)

    case Task.yield(task, @leg_budget_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, "scvd=FAIL(#{step}:harness-timeout-#{@leg_budget_ms}ms)"}
      other -> {:error, "scvd=FAIL(#{step}:#{slice(other)})"}
    end
  end

  # ramp: all actors verified + zero breaches, or the leg FAILS naming the
  # counts (never a partial pass).
  defp do_ramp(n) do
    r = PopcornDemo.Concurrency.ramp(n)

    if r.verified == n and r.breaches == 0 do
      {:ok, r}
    else
      {:error,
       "scvd=FAIL(ramp#{n}:verified-#{r.verified}-of-#{r.n}-breaches-#{r.breaches})"}
    end
  end

  # contention: the harness already asserts determinism; surface the typed
  # non-determinism detail as a loud FAIL. The composed fragment carries the
  # c128 outcome (winners/losers/committed) as the Tier-3 witness; a c32
  # non-determinism FAILs the whole leg before c128 runs.
  defp do_contention(n) do
    case PopcornDemo.Concurrency.contention(n) do
      {:ok, row} ->
        {:ok, "w#{row.winners}/l#{row.losers}/committed#{row.committed_rows}"}

      {:error, {:not_deterministic, detail}} ->
        {:error, "scvd=FAIL(contention#{n}:not_deterministic:#{slice(detail)})"}
    end
  end

  defp slice(t), do: t |> inspect() |> String.slice(0, 100)
end
