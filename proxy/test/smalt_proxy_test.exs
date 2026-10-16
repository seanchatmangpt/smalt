defmodule SmaltProxyTest do
  use ExUnit.Case, async: false

  alias SmaltProxy.Namespace

  @alphabet Enum.map(~c"abcdefghijklmnopqrstuvwxyz0123456789", &<<&1>>)

  # ---- dependency-free generators (Chicago: real data, no mocks) ----

  defp lanes(n) do
    for _ <- 1..n do
      len = :rand.uniform(8)
      len = if len == 0, do: 1, else: len

      1..len
      |> Enum.map(fn _ -> Enum.random(@alphabet) end)
      |> Enum.join()
    end
  end

  defp names(n) do
    for _ <- 1..n do
      1..:rand.uniform(12)
      |> Enum.map(fn _ -> Enum.random(@alphabet ++ ["-", ".", "_", "/"]) end)
      |> Enum.join()
    end
  end

  defp check_all(gen, prop) do
    :rand.seed(:exsss, {2026, 10, 15})

    for x <- gen, do: prop.(x)

    :ok
  end

  # ---- grammar properties ----

  test "every valid lane yields prefix s<lane>-" do
    check_all(lanes(500), fn lane ->
      assert Namespace.valid_lane?(lane)
      assert Namespace.prefix(lane) == "s" <> lane <> "-"
    end)
  end

  test "invalid lanes are rejected" do
    for bad <- [nil, "", 5, "ABC", "toolonglane", "a-b", "a_b", "ä", String.duplicate("a", 9)] do
      refute Namespace.valid_lane?(bad), "expected invalid: #{inspect(bad)}"
    end
  end

  test "prefix/1 raises on invalid lane" do
    assert_raise ArgumentError, fn -> Namespace.prefix("nope-nope") end
  end

  # ---- stamp / owns? properties ----

  test "stamp composes prefix <> name and lane owns its stamps" do
    check_all(Enum.zip(lanes(500), names(500)), fn {lane, name} ->
      stamped = Namespace.stamp(lane, name)
      assert stamped == "s" <> lane <> "-" <> name
      assert Namespace.owns?(lane, stamped)
    end)
  end

  test "lane B never owns lane A's stamped resources" do
    check_all(Enum.zip(lanes(500), lanes(500)), fn {a, b} ->
      if a == b do
        :ok
      else
        stamped = Namespace.stamp(a, "res")
        refute Namespace.owns?(b, stamped), "#{b} owns #{stamped} stamped by #{a}"
        assert Namespace.disjoint?(a, b)
      end
    end)
  end

  test "scan_bound is prefix <> 0xFF and exceeds every stamped key" do
    check_all(Enum.zip(lanes(500), names(500)), fn {lane, name} ->
      bound = Namespace.scan_bound(lane)
      assert bound == Namespace.prefix(lane) <> <<0xFF>>
      assert Namespace.stamp(lane, name) < bound
    end)
  end

  # ---- loopback listener ----

  test "listener accepts on 127.0.0.1:9460 and echoes" do
    assert SmaltProxy.Router.port() == 9460

    {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", 9460, [:binary, active: false])
    :ok = :gen_tcp.send(sock, "sln1-queue-a")
    assert {:ok, "sln1-queue-a"} = :gen_tcp.recv(sock, 0, 5_000)
    :gen_tcp.close(sock)

    assert {:ok, "ssh3-hub"} = SmaltProxy.Router.echo("ssh3-hub")
  end
end
