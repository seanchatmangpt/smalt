# W4-2 — Chicago-school staged block upload leg over the REAL smalt
# substrate (data plane 8443). No mocks: staged_roundtrip/1 walks the real
# Put Block / Put Block List / Get Blob / Delete Blob wire arms with
# base64 block ids and a real blocklist XML body, over the shared
# PopcornDemo.Transport (:httpc on host). A down substrate surfaces as a
# loud FAIL naming the step, never a fake pass.
#
# Context: solo (live substrate leg, host-side :httpc).

defmodule PopcornDemo.LiveBlobBlocksTest do
  use ExUnit.Case, async: false

  alias PopcornDemo.LiveBlob

  @base "http://127.0.0.1:8443"
  @sts "http://127.0.0.1:9443"
  @tenant "smalt-tenant"
  @account "popcorn"
  @ms_version "2021-12-02"

  defp fresh_container,
    do: "w42b" <> Integer.to_string(System.system_time(:millisecond)) <>
          "-" <> Integer.to_string(:erlang.unique_integer([:positive]))

  describe "staged_roundtrip/1 over live substrate" do
    test "assembles committed bytes from two staged blocks, then cleans up" do
      container = fresh_container()

      assert {:ok, "blob-staged=OK(" <> rest} = LiveBlob.staged_roundtrip(container)

      # "popcorn/<container>/staged-receipt.bin:<n>-<cleaned|worm-retained>-staged-roundtrip)"
      # W7-A: extract n and the retention suffix from the full message tail —
      # the previous `case rest` matched the bare suffix against the WHOLE
      # tail (account/container/blob prefix + trailing paren), which can never
      # match, so the test flunked even on a green walk.
      {n, suffix} =
        case Regex.run(~r/:(\d+)-(cleaned|worm-retained)-staged-roundtrip\)$/, rest) do
          [_, n_str, which] -> {String.to_integer(n_str), which}
          nil -> flunk("unexpected staged-roundtrip message: " <> inspect(rest))
        end

      # first half (>= 40 bytes) + second half (512 B's + stamp text)
      assert n > 600

      # Real wire state: the blob is either deleted (walk reports "-cleaned")
      # or WORM-retained by the account's default immutable-container pinion
      # (walk reports "-worm-retained"); the two must agree on the wire.
      case suffix do
        "cleaned" ->
          assert {:ok, %{status: 404}} = raw_get(container)

        "worm-retained" ->
          assert {:ok, %{status: 200}} = raw_get(container)
      end
    end

    test "run/0 (simple roundtrip) still walks OK alongside the staged walk" do
      assert {:ok, "blob=OK(" <> _} = LiveBlob.run()
    end
  end

  # -- real collaborator: raw :httpc GET against the walked container -------

  defp raw_get(container) do
    {:ok, token} = mint()

    PopcornDemo.Transport.Httpc.request(%{
      method: "GET",
      url: @base <> "/#{@account}/#{container}/staged-receipt.bin",
      headers: [
        {"authorization", "Bearer " <> token},
        {"x-ms-version", @ms_version}
      ],
      body: nil
    })
  end

  defp mint do
    {:ok, %{status: 200, body: body}} =
      PopcornDemo.Transport.Httpc.request(%{
        method: "POST",
        url: @sts <> "/#{@tenant}/oauth2/v2.0/token",
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        body: "grant_type=client_credentials&client_id=popcorn-demo&client_secret=not-checked"
      })

    %{"access_token" => tok} = Jason.decode!(body)
    {:ok, tok}
  end
end
