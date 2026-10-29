# AZURE-FIDELITY lane 5: activity log integration court.
#
# Chicago discipline: real dispatch through Smalt.ArmGateway.Router (real
# bearer mint via Smalt.Auth.StsKey.mint/1, real Store rows, real ETS ring),
# assertions on the real wire envelope. No mocks.

defmodule Smalt.Internal.ArmActivityLogTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias Smalt.ArmGateway.Router

  @caller "11111111-2222-3333-4444-555555555555"
  @sub "sub-activity-log"

  setup do
    Smalt.ArmGateway.ActivityLog.reset()
    :ok
  after
    Smalt.ArmGateway.ActivityLog.reset()
  end

  test "PUT then GET eventtypes: logged event carries the documented schema" do
    {url, path} = storage_path()

    conn = dispatch(:put, url, %{"location" => "eastus"}, auth: token())
    assert conn.status in [200, 201, 202]

    %{"value" => [event]} = query()

    assert event["caller"] == @caller
    assert event["status"]["value"] == "Succeeded"
    assert event["resourceId"] == path
    assert event["operationName"]["value"] == "Microsoft.Storage/storageAccounts/write"
    assert event["resourceGroup"] == "rg-actlog"
    assert {:ok, _, _} = DateTime.from_iso8601(event["eventTimestamp"])
    assert is_binary(event["eventDataId"])
    assert is_binary(event["correlationId"])
    assert is_binary(event["operationId"])
    assert event["resourceProvider"]["value"] == "Microsoft.Storage"
    assert event["level"] == "Informational"
    assert event["submissionTimestamp"]
  end

  test "each CRUD op lands one event with correct operationName per verb" do
    {url, path} = storage_path()

    assert dispatch(:put, url, %{"location" => "eastus"}, auth: token()).status in [200, 201, 202]
    assert dispatch(:patch, url, %{"tags" => %{"env" => "test"}}, auth: token()).status in [200, 202]
    assert dispatch(:delete, url, nil, auth: token()).status in [200, 202]

    %{"value" => events} = query()
    if length(events) != 3, do: flunk("EVENTS: " <> inspect(Enum.map(events, &{&1["operationName"]["value"], &1["resourceId"]})))

    assert Enum.all?(events, &(&1["caller"] == @caller))
    assert Enum.all?(events, &(&1["resourceId"] == path))
    assert Enum.all?(events, &(&1["status"]["value"] == "Succeeded"))

    # Most-recent-first: the DELETE is the newest event.
    assert hd(events)["operationName"]["value"] == "Microsoft.Storage/storageAccounts/delete"
    assert List.last(events)["operationName"]["value"] == "Microsoft.Storage/storageAccounts/write"

    # The PUT and PATCH both render the write verb.
    assert Enum.count(events, &(&1["operationName"]["value"] =~ "/write")) == 2
  end

  test "$filter resourceId eq returns only that resource's events" do
    {url, path} = storage_path()
    {other, _} = storage_path()

    # `{url, id}` — `other` here is the URL to PUT.

    assert dispatch(:put, url, %{"location" => "eastus"}, auth: token()).status in [200, 201, 202]
    assert dispatch(:put, other, %{"location" => "eastus"}, auth: token()).status in [200, 201, 202]

    %{"value" => events} = query("$filter=resourceId eq '#{path}'")
    assert length(events) == 1
    assert hd(events)["resourceId"] == path
  end

  test "$filter operationName eq filters by verb" do
    {url, _} = storage_path()

    assert dispatch(:put, url, %{"location" => "eastus"}, auth: token()).status in [200, 201, 202]
    assert dispatch(:delete, url, nil, auth: token()).status in [200, 202]

    %{"value" => events} = query("$filter=operationName eq 'Microsoft.Storage/storageAccounts/delete'")
    assert length(events) == 1
    assert hd(events)["operationName"]["value"] == "Microsoft.Storage/storageAccounts/delete"
  end

  test "$filter eventTimestamp ge/le windows" do
    {url, _} = storage_path()

    assert dispatch(:put, url, %{"location" => "eastus"}, auth: token()).status in [200, 201, 202]

    # A window strictly after now yields the documented empty envelope.
    future = DateTime.add(DateTime.utc_now(), 3600, :second) |> DateTime.to_iso8601()
    %{"value" => events, "nextLink" => next} = query("$filter=eventTimestamp ge '#{future}'")
    assert events == []
    assert is_nil(next)

    # A window covering now yields the event.
    past = DateTime.add(DateTime.utc_now(), -3600, :second) |> DateTime.to_iso8601()
    %{"value" => events2} = query("$filter=eventTimestamp ge '#{past}' and eventTimestamp le '#{future}'")
    assert length(events2) == 1
  end

  test "unsupported api-version answers typed 400 InvalidApiVersionParameter" do
    conn =
      dispatch(
        :get,
        "/subscriptions/#{@sub}/providers/microsoft.insights/eventtypes/management/values?api-version=1999-01-01"
      )

    assert conn.status == 400

    %{"error" => err} = Jason.decode!(conn.resp_body)
    assert err["code"] == "InvalidApiVersionParameter"
  end

  # -- helpers -------------------------------------------------------------------

  defp storage_path do
    name = "actlog#{:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)}"

    path =
      "/subscriptions/#{@sub}/resourceGroups/rg-actlog/providers/Microsoft.Storage/storageAccounts/#{name}?api-version=2022-09-01"

    id =
      "/subscriptions/#{@sub}/resourceGroups/rg-actlog/providers/Microsoft.Storage/storageAccounts/#{name}"

    {path, id}
  end

  defp token do
    now = System.system_time(:second)

    claims = %{
      "aud" => "https://management.azure.com/",
      "iss" => "https://login.microsoftonline.com/00000000-0000-0000-0000-000000000000/v2.0",
      "exp" => now + 600,
      "nbf" => now,
      "tid" => "00000000-0000-0000-0000-000000000000",
      "appid" => @caller
    }

    {:ok, token} = Smalt.Auth.StsKey.mint(claims)
    token
  end

  defp query(query_string \\ nil) do
    qs = if query_string, do: String.replace("#{query_string}&", " ", "%20"), else: ""

    conn =
      dispatch(
        :get,
        "/subscriptions/#{@sub}/providers/microsoft.insights/eventtypes/management/values?#{qs}api-version=2015-04-01"
      )

    assert conn.status == 200

    Jason.decode!(conn.resp_body)
  end

  defp dispatch(method, path, body \\ nil, opts \\ []) do
    base = conn(method, path, body && Jason.encode!(body))

    base =
      if body,
        do: Plug.Conn.put_req_header(base, "content-type", "application/json"),
        else: base

    base =
      case Keyword.get(opts, :auth) do
        nil -> base
        token -> Plug.Conn.put_req_header(base, "authorization", "Bearer #{token}")
      end

    Router.call(Plug.Conn.fetch_query_params(base), [])
  end
end
