defmodule PopcornDemo.LiveCertsTest do
  @moduledoc """
  Chicago-school test for the Key Vault certificate lifecycle walk: the only
  collaborators are the REAL substrate (data plane 8443 + STS 9443) over real
  `:gen_tcp` sockets. No mocks. Skips loudly only when the substrate is down.

  Under test: the KD-15 challenge handshake against the /certificates face
  (tokenless first touch must 401 with a www-authenticate header naming the
  STS authority) plus the full certificate lifecycle CREATE -> pending LRO
  completed -> LIST -> GET -> DELETE (soft) -> deletedCertificate bundle ->
  RECOVER -> DELETE -> PURGE (204).
  """

  use ExUnit.Case, async: false

  substrate_down? =
    with {:ok, sock} <-
           :gen_tcp.connect(~c"127.0.0.1", 9443, [:binary, active: false], 2_000) do
      :gen_tcp.close(sock)
      false
    else
      _ -> true
    end

  @substrate_skip if(substrate_down?, do: "substrate down — run 9>&- just substrate-up", else: false)

  if substrate_down? do
    IO.puts(:stderr, "[popcorn_demo] SKIP: #{@substrate_skip}")
  end

  @tag skip: @substrate_skip
  test "KD-15 challenge observed on /certificates: tokenless first touch 401s with www-authenticate naming the STS authority" do
    {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", 8443, [:binary, packet: :raw, active: false], 5_000)

    :ok =
      :gen_tcp.send(
        sock,
        "GET /certificates?api-version=7.4 HTTP/1.1\r\n" <>
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
  test "full certificate lifecycle: create, pending LRO completed, list, get, soft delete, deleted bundle, recover, purge" do
    assert {:ok, frag} = PopcornDemo.LiveCerts.run()
    assert frag =~ ~r/certs=OK\(popcorn-cert-\d+:purge\)/
  end

  @tag skip: @substrate_skip
  test "run/0 is repeatable: a second run over the same name also lands at purge (no 409 residue)" do
    assert {:ok, frag} = PopcornDemo.LiveCerts.run()
    assert frag =~ ~r/certs=OK\(popcorn-cert-\d+:purge\)/
  end

  # -- raw socket helper -------------------------------------------------------

  defp read_all(sock), do: read_all(sock, [])

  defp read_all(sock, acc) do
    case :gen_tcp.recv(sock, 0, 10_000) do
      {:ok, chunk} -> read_all(sock, [acc | [chunk]])
      {:error, :closed} -> {:ok, IO.iodata_to_binary(Enum.reverse(acc))}
    end
  end
end
