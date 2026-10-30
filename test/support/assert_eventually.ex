defmodule SmaltTest.AssertEventually do
  @moduledoc """
  Bounded poll on a real observable (no-sleep doctrine, test side).

  Polls `fun` immediately and then on a `Process.send_after` cadence until it
  returns a truthy value or the deadline lapses — never `Process.sleep`.

      assert_eventually(fn -> connected?(pid) end)
      assert_eventually(fn -> connected?(pid) end, timeout: 2_000, interval: 20)
  """

  @default_timeout 2_000
  @default_interval 20

  @spec assert_eventually((-> boolean | term), keyword) :: term
  def assert_eventually(fun, opts \\ []) when is_function(fun, 0) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    interval = Keyword.get(opts, :interval, @default_interval)
    deadline = System.monotonic_time(:millisecond) + timeout

    poll(fun, interval, deadline)
  end

  defp poll(fun, interval, deadline) do
    if result = fun.() do
      result
    else
      now = System.monotonic_time(:millisecond)

      if now >= deadline do
        flunk(fun, deadline)
      else
        me = self()
        ref = make_ref()

        Process.send_after(
          me,
          {:assert_eventually_tick, ref},
          min(interval, max(deadline - now, 1))
        )

        receive do
          {:assert_eventually_tick, ^ref} -> poll(fun, interval, deadline)
        end
      end
    end
  end

  defp flunk(_fun, _deadline), do: flunk_default()

  defp flunk_default do
    raise ExUnit.AssertionError,
      message:
        "assert_eventually: observable did not become truthy within the bounded deadline"
  end
end
