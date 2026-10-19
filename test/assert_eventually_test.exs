defmodule SmaltTest.AssertEventuallyTest do
  use ExUnit.Case, async: true

  alias SmaltTest.AssertEventually

  test "eventually_stays/2: condition holding truthy for the window returns :ok" do
    assert :ok =
             AssertEventually.eventually_stays(
               fn -> true end,
               within_ms: 1_000,
               stability_ms: 20,
               interval_ms: 5,
               desc: "holds"
             )
  end

  test "eventually_stays/2: absence violated -> typed failure naming desc, window, LAST observation" do
    # The bad thing never appears: must end in a typed flunk, never a bare
    # timeout, and the flunk carries the LAST observation.
    try do
      AssertEventually.eventually_stays(
        fn -> false end,
        within_ms: 150,
        stability_ms: 50,
        interval_ms: 10,
        desc: "shadow namespace must stay empty"
      )

      flunk("expected eventually_stays to raise on violated absence")
    rescue
      e in ExUnit.AssertionError ->
        msg = Exception.message(e)

        assert msg =~ "eventually_stays(shadow namespace must stay empty)"
        assert msg =~ "never held stable for 50ms within 150ms"
        assert msg =~ "last observation: false"
    end
  end

  test "eventually_stays/2: observation flip false->true resets the stability clock" do
    {:ok, pid} = Agent.start_link(fn -> false end)

    flip_at = System.monotonic_time(:millisecond) + 80

    # Condition turns true at ~80ms and must then hold for the full stability
    # window; a helper that did not reset the clock on flip would return early
    # or flunk. Passes only with honest stability accounting.
    assert :ok =
             AssertEventually.eventually_stays(
               fn ->
                 if System.monotonic_time(:millisecond) >= flip_at,
                   do: Agent.update(pid, fn _ -> true end)

                 Agent.get(pid, & &1)
               end,
               within_ms: 5_000,
               stability_ms: 60,
               interval_ms: 10,
               desc: "flip then hold"
             )

    Agent.stop(pid)
  end

  test "eventually_stays/2: exception inside fun is a false observation, rides the flunk" do
    try do
      AssertEventually.eventually_stays(
        fn -> raise "still settling" end,
        within_ms: 80,
        stability_ms: 20,
        interval_ms: 10,
        desc: "raises forever"
      )

      flunk("expected eventually_stays to raise on violated absence")
    rescue
      e in ExUnit.AssertionError ->
        msg = Exception.message(e)

        assert msg =~ "eventually_stays(raises forever) never held stable for 20ms within 80ms"
        assert msg =~ "last observation: {:raise, :error, %RuntimeError{message: \"still settling\"}}"
    end
  end
end
