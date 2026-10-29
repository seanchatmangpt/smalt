defmodule PopcornDemo.LiveAppConfigTest do
  @moduledoc """
  Chicago-school test for the leg-X5 App Configuration + feature-flag walk:
  the only collaborators are the REAL substrate (data plane 8443 + STS 9443)
  over real sockets. No mocks. Skips loudly only when the substrate is down.
  """

  use ExUnit.Case, async: false

  @skip_reason "substrate down — run 9>&- just substrate-up"

  substrate_down? =
    with {:ok, sock} <-
           :gen_tcp.connect(~c"127.0.0.1", 9443, [:binary, active: false], 2_000) do
      :gen_tcp.close(sock)
      false
    else
      _ -> true
    end

  @substrate_skip if(substrate_down?, do: @skip_reason, else: false)

  if substrate_down? do
    IO.puts(:stderr, "[popcorn_demo] SKIP: #{@skip_reason}")
  end

  @tag skip: @substrate_skip
  test "KD-15 challenge observed on the appconfig kv surface: tokenless 401 with www-authenticate naming the STS" do
    {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", 8443, [:binary, packet: :raw, active: false], 5_000)

    :ok =
      :gen_tcp.send(
        sock,
        "GET /kv/.appconfig.key%2Fprobe-tokenless HTTP/1.1\r\n" <>
          "host: 127.0.0.1:8443\r\nconnection: close\r\n\r\n"
      )

    {:ok, raw} = read_all(sock)
    :gen_tcp.close(sock)

    assert String.contains?(raw, "401")
    assert String.contains?(raw, "www-authenticate:")

    assert Regex.run(~r/authorization="([^"]+)"/, raw) |> Enum.at(1) =~
             "http://127.0.0.1:9443"
  end

  @tag skip: @substrate_skip
  test "full appconfig lifecycle: kv set/get byte-equal, feature flag put/get, list both, delete both, 404 re-get" do
    assert {:ok, "appconfig=OK(" <> rest} = PopcornDemo.LiveAppConfig.run()

    assert [name, suffix] = String.split(rest, ":", parts: 2)
    assert String.starts_with?(name, "popcorn-ac-")
    assert suffix == "kv+flag-lifecycle)"
  end

  @tag skip: @substrate_skip
  test "walk is repeatable (second run also OK — unique name each run)" do
    assert {:ok, "appconfig=OK(" <> _} = PopcornDemo.LiveAppConfig.run()
    assert {:ok, "appconfig=OK(" <> _} = PopcornDemo.LiveAppConfig.run()
  end

  @tag skip: @substrate_skip
  test "outcomes are typed: run/0 never returns an untagged value" do
    outcome = PopcornDemo.LiveAppConfig.run()

    assert match?({:ok, _}, outcome) or match?({:skip, _}, outcome) or
             match?({:error, _}, outcome)
  end

  defp read_all(sock, acc \\ []) do
    case :gen_tcp.recv(sock, 0, 5_000) do
      {:ok, chunk} -> read_all(sock, [acc | [chunk]])
      {:error, :closed} -> {:ok, IO.iodata_to_binary(Enum.reverse(acc))}
    end
  end
end
