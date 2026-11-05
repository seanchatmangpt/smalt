defmodule Smalt.Test.Integration.SignInsLogTest do
  @moduledoc """
  AF-L14-GAP-1 closure court — GET /v1.0/auditLogs/signIns over the real wire.

  Chicago discipline: the real ARM gateway STS mint endpoint (POST
  /:tenant/oauth2/v2.0/token) is hit twice over real HTTP; the sign-ins route
  assembles the ring into the documented Graph envelope. Assertions on final
  wire state — two minted rows newest-first, the createdDateTime ge/le $filter
  subset, and the documented empty envelope on an empty ring. No mocks.
  """

  use ExUnit.Case, async: false

  @tenant "00000000-0000-0000-0000-000000000000"

  setup_all do
    {:ok, _} = Application.ensure_all_started(:smalt)
    :timer.sleep(1500)
    :ok
  end

  defp arm_url do
    "http://127.0.0.1:" <>
      Integer.to_string(Application.fetch_env!(:smalt, :arm_port)) <>
      "/" <> @tenant <> "/oauth2/v2.0/token"
  end

  defp mint do
    {:ok, {{_, 200, _}, _, body}} =
      :httpc.request(:post,
        {String.to_charlist(arm_url()), [], ~c"application/x-www-form-urlencoded",
         "grant_type=client_credentials&client_id=signins-court&client_secret=x&scope=s"},
        [],
        []
      )

    %{"access_token" => token} = Jason.decode!(body)
    token
  end

  defp fetch_signins(token, query \\ "") do
    url =
      "http://127.0.0.1:" <>
        Integer.to_string(Application.fetch_env!(:smalt, :egress_port)) <>
        "/v1.0/auditLogs/signIns" <> query

    {:ok, {{_, status, _}, _, body}} =
      :httpc.request(:get,
        {String.to_charlist(url),
         [
           {'authorization', String.to_charlist("Bearer " <> token)}
         ]},
        [],
        []
      )

    {status, body}
  end

  test "mint twice -> two sign-in rows, newest first, documented row shape" do
    Smalt.Egress.SignIns.clear()
    token = mint()
    token = mint()

    {200, body} = fetch_signins(token)
    assert %{"@odata.context" => ctx, "value" => rows} = Jason.decode!(body)
    assert ctx =~ "$metadata#signIns"
    assert length(rows) == 2

    [newest, oldest | []] = rows
    assert %{"id" => id, "createdDateTime" => dt, "appDisplayName" => "workspace-console"} = newest

    assert is_binary(id)
    assert %{"errorCode" => 0} = newest["status"]
    assert newest["ipAddress"] =~ ~r/^\d+\.\d+\.\d+\.\d+$/
    assert newest["userPrincipalName"] == nil

    assert DateTime.compare(
             d!(newest["createdDateTime"]),
             d!(oldest["createdDateTime"])
           ) == :gt
  end

  test "$filter createdDateTime ge/le selects the documented subset" do
    Smalt.Egress.SignIns.clear()
    token = mint()

    {200, body} = fetch_signins(token)
    assert [%{"createdDateTime" => dt}] = Jason.decode!(body)["value"]

    # ge at the exact mint timestamp keeps the row; le one second earlier
    # excludes it.
    {200, body_ge} = fetch_signins(token, "?$filter=createdDateTime%20ge%20" <> dt)
    assert [%{}] = Jason.decode!(body_ge)["value"]

    cutoff =
      dt
      |> d!()
      |> DateTime.add(-1)
      |> DateTime.to_iso8601()

    {200, body_le} = fetch_signins(token, "?$filter=createdDateTime%20le%20" <> cutoff)
    assert [] = Jason.decode!(body_le)["value"]

    # conjunctive window that contains the row
    window =
      URI.encode_www_form(
        "$filter=createdDateTime ge #{DateTime.add(d!(dt), -10) |> DateTime.to_iso8601()} and createdDateTime le #{dt}"
      )

    {200, body_and} = fetch_signins(token, "?" <> window)
    assert [%{}] = Jason.decode!(body_and)["value"]

    # unsupported property -> documented Graph 400
    {400, body_400} = fetch_signins(token, "?$filter=userPrincipalName%20eq%20%27x%27")
    %{"error" => %{"code" => "BadRequest"}} = Jason.decode!(body_400)
  end

  test "empty ring -> documented empty envelope" do
    Smalt.Egress.SignIns.clear()
    token = mint()

    # clear AFTER minting so the ring is empty but the token is real.
    Smalt.Egress.SignIns.clear()
    {200, body} = fetch_signins(token)
    assert %{"@odata.context" => ctx, "value" => []} = Jason.decode!(body)
    assert ctx =~ "$metadata#signIns"
  end

  # C9 ring-cap courts: these drive the REAL recording site
  # (Smalt.Egress.SignIns.record_mint/3 — the exact hook ArmGateway's mint
  # invokes) rather than the cordoned wire mint (WO-32: the BEAM no longer
  # binds 9443; the wire legs above predate the cordon and are premised on
  # the pre-WO-32 STS endpoint).
  defp record(appid \\ "c9-ring-court") do
    Smalt.Egress.SignIns.record_mint("00000000-0000-0000-0000-000000000000", appid, conn())
  end

  defp conn do
    Plug.Test.conn(:get, "/c9", nil) |> Map.put(:remote_ip, {127, 0, 0, 1})
  end

  test "257 records -> exactly 256 events, newest first (ring cap)" do
    Smalt.Egress.SignIns.clear()

    for _ <- 1..257, do: record()

    events = Smalt.Egress.SignIns.events()
    assert length(events) == 256

    # head is the most recently recorded event (newest first) — record one
    # more and it must land at the head.
    last_seen = hd(Smalt.Egress.SignIns.events())
    record("c9-after-cap")
    new_head = hd(Smalt.Egress.SignIns.events())
    assert new_head.id != last_seen.id
    assert new_head.appid == "c9-after-cap"
  end

  test "clear -> zero events" do
    record()
    assert Smalt.Egress.SignIns.events() != []
    assert Smalt.Egress.SignIns.clear() == :ok
    assert Smalt.Egress.SignIns.events() == []
  end

  defp d!(iso) do
    {:ok, dt, _} = DateTime.from_iso8601(iso)
    dt
  end
end
