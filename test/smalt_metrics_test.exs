defmodule Smalt.MetricsWireTest do
  @moduledoc """
  Wire conformance for the Azure Monitor metrics surface
  (microsoft.insights/metrics): emit N custom points -> query -> timeseries
  continuity asserted; unknown resource -> typed EMPTY value[] envelope;
  monotonic api-version admission.
  """

  use ExUnit.Case, async: false
  use Plug.Test

  alias Smalt.ArmGateway.Router
  alias Smalt.Store

  @opts Router.init([])
  @sub "00000000-0000-0000-0000-000000000000"
  @rg "metrics-rg"

  # NO-SLEEP-DOCTRINE form (v26.10.18 W14): the local ensure_store/0 with a
  # 500ms receive-after `:ok` fallback was a wait-and-hope (it could proceed
  # against a dead store). Canonical resilient_setup instead — the seed runs
  # INSIDE AssertEventually's retry window, so no clock fallback exists.
  setup do
    SmaltTest.Store.resilient_setup(
      post_seed: fn ->
        Store.put(:smalt_subscriptions, @sub, %{
          "id" => "/subscriptions/#{@sub}",
          "subscriptionId" => @sub,
          "displayName" => "Sovereign Smalt Subscription",
          "state" => "Enabled"
        })
      end
    )
  end

  defp call(conn), do: Router.call(conn, @opts)

  defp resource_path(ns \\ "Microsoft.DevTestLab", type \\ "schedules", name \\ "shutdown-19h") do
    "/subscriptions/#{@sub}/resourceGroups/#{@rg}/providers/#{ns}/#{type}/#{name}"
  end

  defp put_resource do
    path =
      resource_path() <>
        "?api-version=#{Smalt.Registry.latest_version("Microsoft.DevTestLab/schedules")}"

    conn =
      conn(:put, path, %{"location" => "smalt-local", "properties" => %{}})
      |> call()

    assert conn.status in [200, 201], "resource PUT failed: #{conn.status}"
  end

  defp metrics_query(params) do
    resource_path() <> "/providers/microsoft.insights/metrics?" <> URI.encode_query(params)
  end

  defp get_metrics(params) do
    conn(:get, metrics_query(params)) |> call()
  end

  # ---------------------------------------------------------------------------
  # emit N custom points -> query -> timeseries continuity
  # ---------------------------------------------------------------------------
  test "POST custom points then GET returns dense bucketed timeseries" do
    put_resource()

    # Emit 3 points at fixed times inside ONE PT1M bucket (12:00:00Z minute)
    # and 1 point in a second bucket, so continuity across the gap is proven.
    t1 = "2026-10-16T12:00:10Z"
    t2 = "2026-10-16T12:00:20Z"
    t3 = "2026-10-16T12:00:30Z"
    t4 = "2026-10-16T12:05:00Z"

    for {t, v} <- [{t1, 1.0}, {t2, 2.0}, {t3, 3.5}, {t4, 7.0}] do
      conn =
        conn(:post, metrics_query(%{"api-version" => "2024-02-01"}), %{
          "metric" => "CustomQueueDepth",
          "value" => v,
          "time" => t,
          "unit" => "Count"
        })
        |> put_req_header("content-type", "application/json")
        |> call()

      assert conn.status == 200, "POST metrics failed: #{conn.status} #{inspect(conn.resp_body)}"
    end

    conn =
      get_metrics(%{
        "api-version" => "2024-02-01",
        "metricnames" => "CustomQueueDepth",
        "timespan" => "2026-10-16T11:55:00Z/2026-10-16T12:10:00Z",
        "interval" => "PT1M"
      })

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)

    assert is_list(body["value"]) and length(body["value"]) == 1
    series = hd(body["value"])
    assert series["name"]["value"] == "CustomQueueDepth"
    assert series["unit"] == "Count"

    data = hd(series["timeseries"])["data"]

    # Continuity: 11:55..12:10 at PT1M = 16 dense buckets, step == 60s.
    assert length(data) == 16

    stamps = Enum.map(data, & &1["timeStamp"])
    assert hd(stamps) == "2026-10-16T11:55:00Z"
    assert List.last(stamps) == "2026-10-16T12:10:00Z"

    # Step between consecutive buckets is exactly the PT1M interval.
    step_ms =
      stamps
      |> Enum.map(&DateTime.from_iso8601/1)
      |> Enum.map(fn {:ok, dt, _} -> DateTime.to_unix(dt, :millisecond) end)
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [a, b] -> b - a end)
      |> Enum.uniq()

    assert step_ms == [60_000]

    # Bucket totals: the 12:00 bucket sums 1.0+2.0+3.5 with count 3 and
    # average 13/6; the 12:05 bucket carries 7.0 count 1.
    b1200 = Enum.find(data, &(&1["timeStamp"] == "2026-10-16T12:00:00Z"))
    assert_in_delta b1200["total"], 6.5, 1.0e-9
    assert b1200["count"] == 3
    assert_in_delta b1200["average"], 6.5 / 3, 1.0e-9

    b1205 = Enum.find(data, &(&1["timeStamp"] == "2026-10-16T12:05:00Z"))
    assert_in_delta b1205["total"], 7.0, 1.0e-9
    assert b1205["count"] == 1

    # Empty bucket: only timeStamp (real Azure Monitor zero-fill shape).
    empty = Enum.find(data, &(&1["timeStamp"] == "2026-10-16T12:02:00Z"))
    assert empty["timeStamp"] == "2026-10-16T12:02:00Z"
    refute Map.has_key?(empty, "total")
  end

  test "lifecycle PUT emits a Requests point visible on GET" do
    put_resource()

    conn =
      get_metrics(%{
        "api-version" => "2024-02-01",
        "metricnames" => "Requests",
        "timespan" => "#{iso_now_back_1h()}/#{iso_now()}",
        "interval" => "PT1H"
      })

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    series = hd(body["value"])
    assert series["name"]["value"] == "Requests"

    data = hd(series["timeseries"])["data"]
    assert length(data) >= 1

    totals = Enum.map(Enum.filter(data, &Map.has_key?(&1, "total")), & &1["total"])
    assert 1.0 in totals
  end

  # ---------------------------------------------------------------------------
  # Unknown resource -> typed EMPTY value[] envelope (real Azure semantics)
  # ---------------------------------------------------------------------------
  test "GET metrics for unknown resource -> 200 with empty value[]" do
    conn =
      get_metrics(%{
        "api-version" => "2024-02-01",
        "metricnames" => "Requests",
        "timespan" => "2026-10-16T00:00:00Z/2026-10-16T01:00:00Z",
        "interval" => "PT15M"
      })

    assert conn.status == 200
    assert %{"value" => []} == Jason.decode!(conn.resp_body)
  end

  # ---------------------------------------------------------------------------
  # api-version monotonic admission (family pattern)
  # ---------------------------------------------------------------------------
  test "stale metrics api-version admitted (monotonic <= latest)" do
    put_resource()

    conn = get_metrics(%{"api-version" => "2021-05-01"})
    assert conn.status == 200
  end

  test "newer-than-latest metrics api-version -> 400 InvalidApiVersionParameter" do
    put_resource()

    conn = get_metrics(%{"api-version" => "2099-01-01"})

    assert conn.status == 400

    body = Jason.decode!(conn.resp_body)
    assert body["error"]["code"] == "InvalidApiVersionParameter"
    assert body["error"]["message"] =~ "2099-01-01"
    assert body["error"]["message"] =~ "2024-02-01"
  end

  test "missing metrics api-version -> 400 MissingApiVersionParameter" do
    put_resource()

    conn = conn(:get, resource_path() <> "/providers/microsoft.insights/metrics") |> call()
    assert conn.status == 400
    assert %{"error" => %{"code" => "MissingApiVersionParameter"}} = Jason.decode!(conn.resp_body)
  end

  test "malformed metrics api-version -> 400" do
    put_resource()
    conn = get_metrics(%{"api-version" => "not-a-date"})
    assert conn.status == 400
  end

  # ---------------------------------------------------------------------------
  # POST emit on unknown resource -> 404 ResourceNotFound
  # ---------------------------------------------------------------------------
  test "POST custom metric for unknown resource -> 404" do
    conn =
      conn(:post, metrics_query(%{"api-version" => "2024-02-01"}), %{
        "metric" => "X",
        "value" => 1
      })
      |> put_req_header("content-type", "application/json")
      |> call()

    assert conn.status == 404
    assert %{"error" => %{"code" => "ResourceNotFound"}} = Jason.decode!(conn.resp_body)
  end

  # ---------------------------------------------------------------------------
  # Unit-level: interval parser
  # ---------------------------------------------------------------------------
  test "parse_interval handles the common ISO durations" do
    assert {:ok, 60_000} = Smalt.Metrics.parse_interval("PT1M")
    assert {:ok, 300_000} = Smalt.Metrics.parse_interval("PT5M")
    assert {:ok, 3_600_000} = Smalt.Metrics.parse_interval("PT1H")
    assert {:ok, 86_400_000} = Smalt.Metrics.parse_interval("P1D")
    assert {:ok, 61_500} = Smalt.Metrics.parse_interval("PT1M1.5S")
    assert :error = Smalt.Metrics.parse_interval("bogus")
    assert {:ok, 60_000} = Smalt.Metrics.parse_interval(nil)
  end

  # -- helpers ------------------------------------------------------------------

  defp iso_now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp iso_now_back_1h do
    DateTime.utc_now() |> DateTime.add(-3_600_000, :millisecond) |> DateTime.to_iso8601()
  end
end
