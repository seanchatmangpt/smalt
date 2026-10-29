defmodule Smalt.Impl6.ProcessLabelTest do
  @moduledoc """
  IMPL-6 Chicago court: real substrate actors carry an OTP process label
  (`Process.set_label/1`, schema `%{service:, role:, correlation_id:}` where
  context exists), and a crashed labeled actor's proc_lib crash report
  carries that label through the Logger pipeline.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  require Logger

  describe "real substrate actors carry their process label" do
    test "AMQP + ARM actor families are labeled as booted" do
      labeled =
        for {mod, expect} <- [
              {Smalt.Amqp.Sweeper, %{service: :amqp, role: :sweeper}},
              {Smalt.ArmGateway.LRO.Sweeper, %{service: :arm, role: :lro_sweeper}},
              {Smalt.ArmGateway.LRO.Notifier, %{service: :arm, role: :lro_notifier}}
            ] do
          pid = GenServer.whereis(mod)
          assert pid, "expected #{inspect(mod)} to be running (app self-boots under mix test)"

          {:label, label} = :erlang.process_info(pid, :label)
          assert label[:service] == expect[:service]

          assert label[:role] == expect[:role],
                 "#{inspect(mod)} label #{inspect(label)} did not match #{inspect(expect)}"
        end

      assert length(labeled) == 3
    end

    test "per-connection AMQP actors are labeled at spawn time" do
      # Per-connection processes and the ARM LRO family are started lazily or
      # gated on SMALT_PLANES. Spawn the real Connection init path over a real
      # socketpair socket to prove the label lands on the actual spawn site.
      {:ok, lsock} =
        :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

      {:ok, port} = :inet.port(lsock)
      {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

      {:ok, pid} =
        Smalt.Amqp.Connection.start_link(socket: sock, mode: :eh)

      assert {:label, %{service: :amqp, role: :connection, correlation_id: :eh}} =
               :erlang.process_info(pid, :label)

      GenServer.stop(pid)
      :gen_tcp.close(lsock)
    end
  end

  test "crash report of a labeled actor carries the label (proc_lib -> Logger)" do
    label = %{service: :arm, role: :lro_sweeper}
    name = Module.concat(__MODULE__, :crash_court_sweeper)

    log =
      capture_log(fn ->
        # Real labeled substrate module, test-owned instance, unlinked so the
        # crash stays scoped to this test.
        {:ok, pid} = GenServer.start(Smalt.ArmGateway.LRO.Sweeper, [tick_ms: :manual], name: name)
        assert {:label, ^label} = :erlang.process_info(pid, :label)

        # Real process exit: unknown message terminates the GenServer.
        catch_exit(GenServer.call(name, :impl6_unknown_message))

        # Order fence: the crash report's logger handler call happens inside the
        # dying process (before DOWN is queued); logging a probe from THIS
        # process after DOWN proves the capture buffer already holds it.
        Logger.error("IMPL6-PROBE")
        :ok
      end)

    assert log =~ "IMPL6-PROBE"
    assert log =~ "Process Label:"
    assert log =~ "service: :arm"
    assert log =~ "role: :lro_sweeper"
  end

  test "label schema: correlation_id omitted where no context exists" do
    name = Module.concat(__MODULE__, :schema_court_sweeper)

    log =
      capture_log(fn ->
        {:ok, _pid} = GenServer.start(Smalt.ArmGateway.LRO.Sweeper, [tick_ms: :manual], name: name)

        catch_exit(GenServer.call(name, :impl6_unknown_message))
        Logger.error("IMPL6-PROBE-2")
        :ok
      end)

    assert log =~ "IMPL6-PROBE-2"
    assert log =~ "Process Label:"
    # Exact schema assert: a connection-family crash report (which does carry
    # correlation_id) can land async in this window, so pin the whole line.
    assert log =~ "Process Label: %{service: :arm, role: :lro_sweeper}\n"
    assert log =~ "Process Label: %{service: :arm, role: :lro_sweeper}"  end
# IMPL-26 (AR-OBS-02 adoption): the remaining spawned-process families.
describe "IMPL-26: remaining spawn-site families are labeled" do
  test "labeled spawn shows the label; unlabeled spawn shows none" do
    parent = self()
    labeled =
      spawn(fn ->
        Process.set_label(%{service: :court, role: :labeled_probe})
        # Event-driven park: exit when the test process dies (no sleep).
        mref = Process.monitor(parent)
        receive do
          {:DOWN, ^mref, :process, ^parent, _} -> :ok
        end
      end)

    unlabeled =
      spawn(fn ->
        mref = Process.monitor(parent)
        receive do
          {:DOWN, ^mref, :process, ^parent, _} -> :ok
        end
      end)

    # The spawned process sets its own label concurrently with this test's
    # process_info call — bounded poll on the real observable, no sleep.
    label =
      Enum.reduce_while(1..500, :undefined, fn _, _ ->
        case :erlang.process_info(labeled, :label) do
          {:label, %{service: :court}} = info -> {:halt, info}
          _ -> Process.sleep(1) && {:cont, :undefined} # SLEEP-CLASS: POLL-STEP (bounded label poll, 500x1ms attempt bound)
        end
      end)

    assert {:label, %{service: :court, role: :labeled_probe}} = label

    # An unlabeled process reports {:label, :undefined} — the info item exists
    # on OTP 29, the label value is undefined.
    assert {:label, :undefined} = :erlang.process_info(unlabeled, :label)
    Process.exit(labeled, :kill)
    Process.exit(unlabeled, :kill)
  end

  test "APIM rate-table owner carries its label" do
    # JA-1 fix (2026-10-21): Smalt.Apim is now a NAMED GenServer under
    # Smalt.Supervisor, so the self-booted app already holds the name —
    # accept the app-booted instance instead of asserting a fresh start.
    # The persistent_term key still publishes the (named) owner's pid.
    case start_supervised({Smalt.Apim, []}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    owner = :persistent_term.get({Smalt.Apim, :rate_table_owner})

    {:label, label} = :erlang.process_info(owner, :label)
    assert label == %{service: :apim, role: :rate_table_owner}
  end
end

end
