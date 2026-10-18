defmodule Smalt.Test.Ratio do
  @moduledoc """
  Relative-ratio timing fences (AZB-12, v26.10.18).

  Replaces absolute `assert us < N` latency bounds with machine-independent
  same-run ratios against a calibrated control op. Contract per call site:

    * subject and baseline are timed in MICROSECONDS (`:timer.tc`)
    * baseline is an INDEPENDENT path — it must not ride the same function
      clause (let alone the same refusal clause) as the subject, so a
      slowdown injected into the subject clause cannot slow the baseline
      too and collapse the ratio (the fence10-ratio vacuity lesson,
      docs/jira/v26.10.18/receipts/b3-fence10.md §3)
    * baseline is sleep-free-by-construction: the control op is a plain
      computation, never a `Process.sleep`-paced waiter
    * the same-run median of 5 sheds scheduler noise (paired measurement,
      fleet-load jitter hits both legs co-monotonically)

  Anti-vacuity contract: a 10x slowdown injected into the subject op must
  push the measured ratio past `max:` and fail the assertion.
  """

  @default_rounds 5

  @doc "Times `fun` once in microseconds."
  @spec time_us((-> any())) :: non_neg_integer()
  def time_us(fun), do: :timer.tc(fun) |> elem(0)

  @doc """
  Calibrated same-run baseline: median of `rounds` (default 5) samples of
  the control op `fun`. Sleep-free by construction.
  """
  @spec calibrate((-> any()), pos_integer()) :: non_neg_integer()
  def calibrate(fun, rounds \\ @default_rounds) do
    1..rounds
    |> Enum.map(fn _ -> time_us(fun) end)
    |> Enum.sort()
    |> Enum.at(div(rounds, 2))
  end

  @doc """
  Best-of-`rounds` (min) sample of a REPEATABLE subject op: the min sheds
  one-off scheduler desched spikes that would otherwise flip a
  microsecond-scale fence with no product change (the falsifier class).
  Only valid when calling the subject repeatedly is observationally neutral
  (refusals, idempotent reads/sweeps) — never for state-mutating legs.
  """
  @spec floor_us((-> any()), pos_integer()) :: non_neg_integer()
  def floor_us(fun, rounds \\ @default_rounds) do
    1..rounds
    |> Enum.map(fn _ -> time_us(fun) end)
    |> Enum.min()
  end

  @doc """
  Asserts `subject_us / baseline_us < max` (strict), flunking with the
  measured geometry so a RED names both legs.

  ## Options

    * `:max` — ratio ceiling (required in practice; float)
    * `:context` — string named in the failure message
  """
  @spec assert_ratio(non_neg_integer(), non_neg_integer(), keyword()) :: :ok
  def assert_ratio(subject_us, baseline_us, opts \\ []) do
    max = Keyword.fetch!(opts, :max)
    context = Keyword.get(opts, :context, "ratio fence")

    ratio = subject_us / max(baseline_us, 1)

    if ratio < max do
      :ok
    else
      ExUnit.Assertions.flunk("""
      #{context}: ratio #{Float.round(ratio, 2)} >= max #{max}
        subject_us #{subject_us} / baseline_us #{baseline_us}
      A 10x subject-op slowdown must fail this assertion (AZB-12 anti-vacuity).
      """)
    end
  end
end
