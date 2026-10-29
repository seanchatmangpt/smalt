defmodule PopcornDemo.LiveKVTest do
  @moduledoc """
  Chicago-school test for the ERRC-R5 Key Vault walk: the only collaborators
  are the REAL substrate (data plane 8443 + STS 9443) over real `:gen_tcp`
  sockets. No mocks. Skips loudly only when the substrate is actually down.

  The KD-15 challenge handshake itself is under test: run/0 must observe a
  real 401 with a `www-authenticate` header, mint the bearer from the STS
  named by that header's `authorization=` authority, and complete the full
  secret lifecycle (SET -> GET byte-equal -> DELETE -> 404 SecretNotFound).
  """

  use ExUnit.Case, async: false

  @skip_reason "substrate down — run 9>&- just substrate-up"

  # :httpc is broken under the popcorn_demo mix env (witnessed 2026-10-20,
  # see LiveBlob moduledoc) — the down-probe rides :gen_tcp like the walk.
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
  test "KD-15 challenge observed: tokenless first touch 401s with www-authenticate naming the STS authority" do
    {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", 8443, [:binary, packet: :raw, active: false], 5_000)

    :ok =
      :gen_tcp.send(
        sock,
        "GET /secrets/popcorn-secret?api-version=7.4 HTTP/1.1\r\n" <>
          "host: 127.0.0.1:8443\r\nconnection: close\r\n\r\n"
      )

    {:ok, raw} = read_all(sock)
    :gen_tcp.close(sock)

    assert String.contains?(raw, "401")
    assert String.contains?(raw, "www-authenticate:")

    # The challenge names the authority run/0 will mint the bearer at.
    assert Regex.run(~r/authorization="([^"]+)"/, raw) |> Enum.at(1) =~
             "http://127.0.0.1:9443"
  end

  @tag skip: @substrate_skip
  test "full secret lifecycle: set, get byte-equal, delete, re-get 404" do
    assert {:ok, "kv=OK(popcorn-secret-" <> rest} = PopcornDemo.LiveKV.run()

    # run/0 returns "kv=OK(<run-unique-secret-name>:<n>-bytes-lifecycle)" —
    # the unique name itself carries digits, so split on ":" before parsing.
    assert [secret, count] = String.split(rest, ":", parts: 2)
    assert secret != "" and count != ""
    assert {n, "-bytes-lifecycle)"} = Integer.parse(count)
    assert n > 0
  end

  @tag skip: @substrate_skip
  test "walk is repeatable (second run also OK — unique payload each run)" do
    assert {:ok, "kv=OK(" <> _} = PopcornDemo.LiveKV.run()
    assert {:ok, "kv=OK(" <> _} = PopcornDemo.LiveKV.run()
  end

  @tag skip: @substrate_skip
  test "outcomes are typed: run/0 never returns an untagged value" do
    outcome = PopcornDemo.LiveKV.run()

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
