# POWL-8 (writer lane): in-memory Service Bus rule manager + HSM signer,
# Chicago-style over real ETS/GenServer/:crypto collaborators, no mocks.
# Rule evaluation reuses the substrate parser (Smalt.SbRules) — one calculus,
# no second filter implementation. No sleeps: dead-pid waits poll the
# Process.alive? observable with a bounded deadline.
defmodule Smalt.Test.Internal.Powl2PrimitivesTest do
  use ExUnit.Case, async: false

  alias Smalt.Powl2.HsmSigner
  alias Smalt.Powl2.ServiceBusRuleManager

  setup do
    # Unlinked start: the manager's ETS tables must outlive each test process.
    if is_nil(Process.whereis(ServiceBusRuleManager)) do
      {:ok, _} = GenServer.start(ServiceBusRuleManager, :ok, name: ServiceBusRuleManager)
    end

    if is_nil(Process.whereis(HsmSigner)) do
      {:ok, _} = GenServer.start(HsmSigner, :ok, name: HsmSigner)
    end

    on_exit(fn ->
      if Process.whereis(ServiceBusRuleManager) do
        :ets.delete_all_objects(ServiceBusRuleManager.table())
        :ets.delete_all_objects(ServiceBusRuleManager.dlq())
      end
    end)

    :ok
  end

  test "true_filter rule: publish delivers {:amqp_transfer, meta} to live pid" do
    parent = self()
    consumer = spawn_consumer(parent)

    :ok = ServiceBusRuleManager.put_rule("t1", "s1", "$Default", :true_filter, consumer)

    msg = %{body: "hello", message_id: "m-1", label: "evt", app_props: %{"k" => "v"}}
    assert {:ok, [^consumer]} = ServiceBusRuleManager.publish("t1", msg)

    assert_receive {:amqp_transfer,
                    %{topic: "t1", sub: "s1", body: "hello", message_id: "m-1",
                      label: "evt", app_props: %{"k" => "v"}}},
                   1_000

    send(consumer, :stop)
    :ok = await_dead(consumer)
  end

  test "sql filter match delivers; filter false does not deliver (DLQ)" do
    consumer = spawn_consumer(self())

    :ok =
      ServiceBusRuleManager.put_rule("t2", "s2", "r1", "prio = 'high' OR sys.label = 'alert'",
        consumer)

    assert {:dlq, [], _} =
             ServiceBusRuleManager.publish("t2", %{
               body: "x",
               app_props: %{"prio" => "low"},
               label: "info"
             })

    assert [row] = ServiceBusRuleManager.dlq_rows()
    assert elem(row, 1) == "t2"
    assert elem(row, 2).body == "x"

    assert {:ok, [_]} =
             ServiceBusRuleManager.publish("t2", %{
               body: "y",
               app_props: %{"prio" => "high"},
               label: "info"
             })

    assert {:ok, [_]} =
             ServiceBusRuleManager.publish("t2", %{body: "z", app_props: %{}, label: "alert"})

    send(consumer, :stop)
    :ok = await_dead(consumer)
  end

  test "invalid SQL filter refused with typed 400, rule not stored" do
    assert {:error, 400, "InvalidFilter"} =
             ServiceBusRuleManager.put_rule("t9", "s9", "bad", "prio > 3", self())

    assert [] = ServiceBusRuleManager.get_rules("t9", "s9")
  end

  test "dead target pid: zero-delivery lands in DLQ ordered_set, FIFO by monotone key" do
    consumer = spawn_consumer(self())
    :ok = ServiceBusRuleManager.put_rule("t3", "s3", "r", :true_filter, consumer)

    assert {:ok, [_]} = ServiceBusRuleManager.publish("t3", %{body: "a"})

    send(consumer, :stop)
    :ok = await_dead(consumer)

    assert {:dlq, [], k1} = ServiceBusRuleManager.publish("t3", %{body: "b1"})
    assert {:dlq, [], k2} = ServiceBusRuleManager.publish("t3", %{body: "b2"})
    assert k2 > k1

    rows = ServiceBusRuleManager.dlq_rows()
    assert [%{body: "b1"}, %{body: "b2"}] = Enum.map(rows, fn {_k, _t, m} -> m end)
  end

  test "signer: roundtrip, wrong-digest false, non-32-byte typed 400" do
    digest = :crypto.hash(:sha256, "payload")
    assert byte_size(digest) == 32

    assert {:ok, sig} = HsmSigner.sign_digest(digest)
    assert HsmSigner.verify_digest(digest, sig)

    wrong = :crypto.hash(:sha256, "other")
    refute HsmSigner.verify_digest(wrong, sig)

    assert {:error, 400, msg} = HsmSigner.sign_digest(<<1, 2, 3>>)
    assert msg =~ "InvalidDigest"

    refute HsmSigner.verify_digest(<<1, 2, 3>>, sig)
  end

  test "get_rules / delete_rule surface" do
    pid = self()

    :ok = ServiceBusRuleManager.put_rule("t4", "s4", "rA", "n = 1", pid)
    :ok = ServiceBusRuleManager.put_rule("t4", "s4", "rB", :true_filter, pid)

    rules = ServiceBusRuleManager.get_rules("t4", "s4")
    names = Enum.map(rules, fn {name, _filter, _pid} -> name end)
    assert names == ["rA", "rB"]

    true = ServiceBusRuleManager.delete_rule("t4", "s4", "rA")
    assert [{"rB", _, _}] = ServiceBusRuleManager.get_rules("t4", "s4")
  end

  # BK-CENS3 F8 shared-ETS falsifiers (bkcens3-final-hop.md): the heir'd
  # named tables survive a CRASH death under :init ownership; without the
  # init stale-delete the restarted GenServer's :ets.new raises
  # :already_exists (witnessed ×6 under batch load).

  test "crash-killed manager: stale :init-heir-held table is stale-deleted, restart owns table" do
    old = Process.whereis(ServiceBusRuleManager)
    :ok = ServiceBusRuleManager.put_rule("tk", "sk", "rk", :true_filter, self())

    GenServer.stop(old, :kill)

    # Crash death: terminate/2 never ran; the table survives under the :init
    # heir carrying the stale rule row.
    table = ServiceBusRuleManager.table()
    assert :ets.info(table) != :undefined
    assert :ets.info(table, :owner) == Process.whereis(:init)
    assert :ets.match_object(table, {{"tk", "sk", :_}, :_, :_}) != []

    {:ok, new} = GenServer.start(ServiceBusRuleManager, :ok, name: ServiceBusRuleManager)
    assert new != old
    # ets_auto-shaped convergence law: the RESTARTED pid owns the table.
    assert :ets.info(table, :owner) == new
    # Fresh table: the stale row did not leak into the new incarnation.
    assert [] = :ets.match_object(table, {{"tk", "sk", :_}, :_, :_})
  end

  test "batch restart fan-out: 6 kill/restart cycles never raise :already_exists" do
    table = ServiceBusRuleManager.table()

    Enum.each(1..6, fn i ->
      case Process.whereis(ServiceBusRuleManager) do
        nil -> :ok
        pid -> GenServer.stop(pid, :kill)
      end

      assert {:ok, pid} = GenServer.start(ServiceBusRuleManager, :ok, name: ServiceBusRuleManager)
      assert :ets.info(table, :owner) == pid
      :ok = ServiceBusRuleManager.put_rule("tb#{i}", "sb", "r", :true_filter, self())
    end)
  end

  test "load under restart: concurrent writers green across a kill/restart cycle" do
    table = ServiceBusRuleManager.table()

    writers =
      for i <- 1..16 do
        Task.async(fn ->
          Enum.each(1..25, fn j ->
            :ok = ServiceBusRuleManager.put_rule("tw#{i}", "sw", "r#{j}", :true_filter, self())
          end)
        end)
      end

    Task.await_many(writers, 10_000)

    case Process.whereis(ServiceBusRuleManager) do
      nil -> :ok
      pid -> GenServer.stop(pid, :kill)
    end

    assert {:ok, new} = GenServer.start(ServiceBusRuleManager, :ok, name: ServiceBusRuleManager)
    assert :ets.info(table, :owner) == new
    :ok = ServiceBusRuleManager.put_rule("tw", "sw", "r", :true_filter, self())
    me = self()
    assert [{{"tw", "sw", "r"}, {true, nil}, ^me}] =
             :ets.match_object(table, {{"tw", "sw", :_}, :_, :_})
  end

  defp spawn_consumer(parent) do
    {:ok, pid} =
      Task.start(fn -> consume_loop(parent) end)

    pid
  end

  defp consume_loop(parent) do
    receive do
      :stop -> :ok
      msg ->
        send(parent, msg)
        consume_loop(parent)
    end
  end

  defp await_dead(pid, deadline) when is_integer(deadline) do
    if Process.alive?(pid) do
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("consumer did not die in time")
      end

      await_dead(pid, deadline)
    else
      :ok
    end
  end

  defp await_dead(pid), do: await_dead(pid, System.monotonic_time(:millisecond) + 2_000)
end
