defmodule SmaltTest.SleepWindows do
  @moduledoc """
  Named, parameterized B1 time-advance windows (docs/NO_SLEEP_DOCTRINE.md,
  Law 1 B1 annotated exception).

  At a B1 site the condition under test IS time itself — rate-limit window
  alignment/rollover, lock-expiry choreography, LRO delay/retention elapse,
  keep-alive idle gap — so no observable can be polled. Each window here is
  NAMED and derived from its configured constant (never a bare literal at
  the call site); the adjacent sleep keeps its
  `# SLEEP-CLASS: TIME-ADVANCE` annotation (a reviewed diff, never silent).

  Windows (13-site census, rewrite-drafts/sleeps.md §B1):

    - `second_boundary_ms/1`     — wall-clock 1 s fixed-window alignment
    - `fixed_window_rollover_ms/0` — full 1 s window rollover (counter reset)
    - `lro_delay_elapse_ms/1`    — LRO delay elapse before sweep/poll
    - `lro_retention_elapse_ms/1`— LRO retention-window crossing
    - `sweeper_grace_elapse_ms/0`— tombstone grace-window elapse
    - `mcp_idle_gap_ms/0`        — wire keep-alive idle gap
  """

  @doc """
  Milliseconds to sleep so execution resumes just after the NEXT wall-clock
  second boundary.

  Law: the rate limiter's 1-second fixed window makes its admit count
  exactly assertable only when all requests land inside ONE window — the
  test aligns to the boundary first so the window rolls over mid-test only
  after the assertable burst.

  The margin guarantees the resumed position is past the boundary, not
  racing it. Returns a duration for `Process.sleep/1` (0 is a lawful
  return: already aligned).
  """
  @spec second_boundary_ms(pos_integer()) :: non_neg_integer()
  def second_boundary_ms(margin_ms \\ 5) when is_integer(margin_ms) and margin_ms >= 0 do
    ms = System.system_time(:millisecond)
    1000 - rem(ms, 1000) + margin_ms
  end

  @doc """
  Milliseconds to sleep so execution resumes in the NEXT 1-second fixed
  window, regardless of current position (fixed-window counter reset).

  Law: the rate limiter is a fixed window, not a permanent ban — proving
  reset requires crossing the full window boundary, and the +100 ms
  guards against landing exactly ON the boundary.
  """
  @spec fixed_window_rollover_ms(non_neg_integer()) :: non_neg_integer()
  def fixed_window_rollover_ms(margin_ms \\ 100) do
    ms = System.system_time(:millisecond)
    1000 - rem(ms, 1000) + margin_ms
  end

  @doc """
  Milliseconds to sleep past the configured LRO delay
  (`:smalt, :lro_delay_ms`, default 20) plus `extra_ms`.

  Law: an LRO's terminal state is produced only after its server-side
  delay elapses; the sweep/poll that closes it is lawful only from the
  far side of that real window — no observable exists before it.
  """
  @spec lro_delay_elapse_ms(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def lro_delay_elapse_ms(extra_ms \\ 10, default_delay_ms \\ 20) do
    Application.get_env(:smalt, :lro_delay_ms, default_delay_ms) + extra_ms
  end

  @doc """
  Milliseconds to sleep past the LRO deadline for at-rest sweeps
  (enclave testbed: deadline = `:lro_delay_ms`, sweep runs after a
  4x multiple so all 50 concurrent ops are far past deadline).

  Law: the at-rest sweeper terminalizes only past-deadline operations —
  the crossing is the mechanism under test, not a settle guess.
  """
  @spec lro_deadline_elapse_ms(non_neg_integer()) :: non_neg_integer()
  def lro_deadline_elapse_ms(default_delay_ms \\ 15) do
    Application.get_env(:smalt, :lro_delay_ms, default_delay_ms) * 4
  end

  @doc """
  Milliseconds to sleep past the tombstone grace window
  (`:smalt, :amqp_sweeper_lock_grace_ms`, default 1) plus epsilon.

  Law: a sweeper-passed tombstone expires only after
  `first_swept_at + grace_ms`; the 404 :not_found contract exists only
  on the far side of that real window.
  """
  @spec sweeper_grace_elapse_ms(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def sweeper_grace_elapse_ms(epsilon_ms \\ 4, default_grace_ms \\ 1) do
    Application.get_env(:smalt, :amqp_sweeper_lock_grace_ms, default_grace_ms) + epsilon_ms
  end

  @doc """
  Wire keep-alive idle gap (`:smalt, :mcp_idle_keep_alive_gap_ms`,
  default 1500).

  Law: socket keep-alive survival across an idle gap is a property of
  the gap's duration itself — the second request must arrive after the
  gap for the survival claim to carry any bits.
  """
  @spec mcp_idle_gap_ms(non_neg_integer()) :: non_neg_integer()
  def mcp_idle_gap_ms(default_gap_ms \\ 1_500) do
    Application.get_env(:smalt, :mcp_idle_keep_alive_gap_ms, default_gap_ms)
  end
end
