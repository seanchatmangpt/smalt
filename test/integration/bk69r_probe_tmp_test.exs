defmodule Bk69rProbeTmpTest do
  use ExUnit.Case, async: false
  Code.require_file("../internal/poll_helper.exs", __DIR__)

  test "probe: ensemble-kill semantics" do
    base = Smalt.Store
    :ok = base.put(:smalt_resources, "probe-k", %{"v" => 1})
    pid = Process.whereis(base)
    IO.puts("WITNESS whereis=#{inspect(pid)}")
    Process.exit(pid, :kill)

    # BK-70r: replaced the inline sleep-paced wait/2 with the audited bounded
    # poll (test/internal/poll_helper.exs) — no-sleep doctrine.
    new =
      case SmaltTest.Internal.Poll.eventually(
             fn ->
               p = Process.whereis(base)

               if is_pid(p) and p != pid and Process.alive?(p) and
                    Enum.all?(Smalt.Store.table_names(), &(:ets.info(&1) != :undefined)) do
                 {:ok, p}
               else
                 :retry
               end
             end,
             timeout_ms: 10_000
           ) do
        {:ok, p} -> p
        {:timeout, last} -> flunk("store did not restart after kill: #{inspect(last)}")
      end
    IO.puts("WITNESS new_sup=#{inspect(new)}")
    IO.puts("WITNESS table_exists=#{:ets.info(:smalt_resources) != :undefined}")
    IO.puts("WITNESS get=#{inspect(base.get(:smalt_resources, "probe-k"))}")
    IO.puts("WITNESS raw=#{inspect(:ets.lookup(:smalt_resources, "probe-k"))}")
    assert true
  end
end
