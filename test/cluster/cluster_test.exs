Code.require_file("poll_helper.exs", Path.join(__DIR__, "../internal"))

defmodule Smalt.ClusterTest do
  @moduledoc """
  Chicago-style: real second BEAM via :peer (a real dist node, not a mock),
  real DNS name ("localhost" resolves 127.0.0.1 via the host table fallback).
  """

  use ExUnit.Case, async: false

  describe "disabled by default" do
    test "start_link refuses when disabled (solo boot stays byte-identical)" do
      Application.put_env(:smalt, :cluster, enabled: false)

      assert_spawn_argument_error(fn -> Smalt.Cluster.start_link([]) end)

      status = Smalt.Cluster.cluster_status()
      assert %{enabled: false, joined: 0, nodes: []} = status
      assert status.self == node()
    end

    test "start_link refuses when enabled but dns_name missing" do
      Application.put_env(:smalt, :cluster, enabled: true, dns_name: nil)

      assert_spawn_argument_error(fn -> Smalt.Cluster.start_link([]) end)
    end
  end

  describe "two-node join over real distribution" do
    setup do
      # real second BEAM on 127.0.0.1; test node becomes distributed on demand
      Application.put_env(:smalt, :cluster,
        enabled: true,
        dns_name: "localhost",
        node_prefix: "smalt_clu_peer",
        poll_ms: 100,
        max_retries: 3
      )

      on_exit(fn -> Application.delete_env(:smalt, :cluster) end)
      :ok
    end

    test "poller connects to peer resolved from dns_name and reports joined: 1" do
      ensure_distribution()
      ensure_epmd()

      cookie = Node.get_cookie()

      peer =
        :peer.start(%{
          name: String.to_charlist("smalt_clu_peer"),
          host: String.to_charlist("127.0.0.1"),
          cookie: cookie
        })

      assert {:ok, pid, _peer_node} = peer
      on_exit(fn -> :peer.stop(pid) end)

      assert {:ok, _} = Smalt.Cluster.start_link([])
      Smalt.Cluster.poll_now()

      {:ok, status} =
        SmaltTest.Internal.Poll.eventually(fn ->
          st = Smalt.Cluster.cluster_status()
          if st.joined >= 1, do: {:ok, st}, else: {:error, {:not_joined, st}}
        end)

      assert status.joined == 1
      assert String.to_atom("smalt_clu_peer@127.0.0.1") in status.nodes
      # alive peer answers a real RPC over the joined cluster and lists us back
      {:ok, _} =
        SmaltTest.Internal.Poll.eventually(fn ->
          case :rpc.call(String.to_atom("smalt_clu_peer@127.0.0.1"), :erlang, :nodes, [:connected]) do
            [_] = back -> {:ok, back}
            other -> {:error, {:no_bidirectional, other}}
          end
        end)

      assert :rpc.call(String.to_atom("smalt_clu_peer@127.0.0.1"), :erlang, :nodes, [:connected]) == [node()]
    end

    test "connect failure records last_error and burns the bounded budget" do
      ensure_distribution()
      ensure_epmd()

      # dns_name resolves, but no node named smalt_nobody@127.0.0.1 exists
      Application.put_env(:smalt, :cluster,
        enabled: true,
        dns_name: "localhost",
        node_prefix: "smalt_nobody",
        poll_ms: 100,
        max_retries: 2
      )

      assert {:ok, _} = Smalt.Cluster.start_link([])
      Smalt.Cluster.poll_now()

      {:ok, status} =
        SmaltTest.Internal.Poll.eventually(fn ->
          st = Smalt.Cluster.cluster_status()

          if st.last_error == {:connect_failed, :"smalt_nobody@127.0.0.1"} and
               Enum.member?(st.exhausted, {127, 0, 0, 1}) do
            {:ok, st}
          else
            {:error, {:no_budget_burn, st}}
          end
        end)

      assert status.joined == 0
      assert Enum.member?(status.exhausted, {127, 0, 0, 1})
    end
  end

  defp assert_spawn_argument_error(fun) do
    {pid, ref} = spawn_monitor(fun)

    assert_receive {:DOWN, ^ref, :process, ^pid, {%ArgumentError{}, _stack}}, 5_000
  end

  defp ensure_distribution do
    if node() == :nonode@nohost do
      assert {:ok, _} = :net_kernel.start([:"smalt_clu_main@127.0.0.1"])
    end

    :ok
  end

  defp ensure_epmd do
    case :net_adm.names() do
      {:ok, _} -> :ok
      _ ->
        {_, 0} = System.cmd("epmd", ["-daemon"])
        :ok
    end
  end
end
