# W4-5 — Chicago-school live leg over the REAL smalt substrate (ARM control
# plane 9443, resource-tags via the generic provider resource PUT). No mocks:
# run/0 walks the real ARM face — STS mint, RG PUT, tagged containerApp PUT,
# GET round-trip, tag update — all over real :httpc. A down substrate
# surfaces as a loud FAIL/SKIP naming the step, never a fake pass.
#
# Context: solo (live substrate leg, host-side :httpc).

defmodule PopcornDemo.LiveTagsTest do
  use ExUnit.Case, async: false

  alias PopcornDemo.LiveTags

  describe "run/0 full walk over live substrate" do
    test "returns OK with the tags round-trip count" do
      assert {:ok, "tags=OK(" <> rest} = LiveTags.run()
      n = rest |> String.split("-tags-roundtrip") |> hd() |> String.to_integer()
      assert n >= 2
    end
  end

  describe "real wire state" do
    test "GET round-trip carries the v1 tag set byte-shape exact" do
      record = fetch_via_http!()

      assert record["tags"] == LiveTags.tags_v1() or record["tags"] == LiveTags.tags_v2(),
             "wire tags #{inspect(record["tags"])} match neither witnessed set"

      assert is_map(record["tags"]) and map_size(record["tags"]) >= 2
    end

    test "tokenless GET is refused 401 with a WWW-Authenticate challenge" do
      # Transport now surfaces headers; the KD-15 challenge is witnessed at
      # header level (real wire state, not a status-only proxy).
      assert {:ok, %{status: 401, headers: headers}} = LiveTags.fetch_tokenless()

      assert {"www-authenticate", challenge} =
               Enum.find(headers, fn {k, _} -> k == "www-authenticate" end),
             "no www-authenticate header in #{inspect(headers)}"

      assert challenge =~ "Bearer"
    end
  end

  # -- Real collaborator ------------------------------------------------------

  # A real :httpc GET (with fresh STS mint) against the same endpoint run/0
  # uses; if the app answers 404 (test-order independence), re-run the real
  # walk and retry once.
  defp fetch_via_http! do
    case LiveTags.fetch_tagged_app() do
      {:ok, record} ->
        record

      {:error, "tags=FAIL(get_app:HTTP-404" <> _} ->
        assert {:ok, _} = LiveTags.run()
        assert {:ok, record} = LiveTags.fetch_tagged_app()
        record

      other ->
        flunk("live tagged-app GET failed: #{inspect(other)}")
    end
  end
end
