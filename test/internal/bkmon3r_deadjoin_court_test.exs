# BK-MON3R court (v26.10.22): the monitor accumulator fallback join in
# ArmGateway.Router.handle_metrics/6 — BK-MON3-F1 (HIGH, pre-existing).
#
# Defect (docs/jira/v26.10.22/receipts/bkmon3-final-standing.md): the
# fallback predicate `String.starts_with?(r, downcase(res_id) <> "|")`
# was dead code — Smalt.Monitor.Metrics.record/4 keys rows
# `{downcased resource, metric, bucket}` with NOTHING after the resource,
# so acc_rows was 0 for every res_id and every store-miss metrics GET
# returned the real-Azure empty envelope even when the accumulator held
# rows for that exact resource. The same dead "|" idiom also lived in
# Smalt.Monitor.Metrics.series/5's row filter.
#
# Fix: exact downcased-resource equality in both filters (the "|" idiom
# belongs to Smalt.Metrics' string-keyed table, not this tuple-keyed ETS).
#
# Chicago discipline: real telemetry events into the real attached
# handler, real tuple-keyed ETS, real HTTP/1.1 over loopback against the
# self-booted ArmGateway.Router. No mocks, no sleeps. Falsifiers:
#   L1: store-miss GET for resource X with recorded rows -> 200 carrying
#       nonzero Requests/RequestDuration totals (pre-fix: empty envelope)
#   L2: store-miss GET for unknown Y -> 200 empty envelope
#   L3: casing-insensitive match (rows recorded under mixed-case path
#       from resource_from_path; route id in another casing) still served
#   L4: witnessed pre-fix crash shape stays fixed — the GET is a real
#       200 envelope, never a 500 (L1 exercises the exact pre-fix crash
#       state: store-miss + non-empty accumulator)
#
# Context: solo (internal tier, in-process wire faces).

defmodule Smalt.Test.Internal.Bkmon3rDeadjoinCourtTest do
  use ExUnit.Case, async: false

  @api "2021-04-01"

  setup do
    case GenServer.start_link(Smalt.Store, []) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)
    :ok
  end

  defp base, do: "http://127.0.0.1:#{Application.get_env(:smalt, :arm_port)}"

  defp get(url) do
    :httpc.request(:get, {String.to_charlist(url), []}, [], body_format: :binary)
    |> case do
      {:ok, {{_v, status, _phrase}, _hds, rsp}} -> {status, rsp}
      {:error, reason} -> flunk("httpc error on #{url}: #{inspect(reason)}")
    end
  end

  # Record real rows for path via the REAL attached :telemetry handler
  # (same event shape bandit emits; :telemetry.execute is synchronous, so
  # rows are on the table when this returns).
  defp record_requests(path, duration_ms) do
    :telemetry.execute(
      [:bandit, :request, :stop],
      %{duration: System.convert_time_unit(duration_ms, :millisecond, :native)},
      %{conn: %Plug.Conn{request_path: path}}
    )
  end

  defp res(sub, rg, ns, type, name),
    do: "/subscriptions/#{sub}/resourceGroups/#{rg}/providers/#{ns}/#{type}/#{name}"

  defp metrics_url(res_id, metric),
    do:
      "#{base()}#{res_id}/providers/microsoft.insights/metrics?api-version=#{@api}&metricnames=#{metric}"

  defp decode_envelope(rsp) do
    assert {:ok, %{"value" => value}} = Jason.decode(rsp)
    value
  end

  test "L1: store-miss GET for X with accumulator rows serves the real series (200, nonzero)" do
    sub = "sub-bkmon3r-l1"
    path = res(sub, "rg-bkmon3r", "Microsoft.Storage", "storageAccounts", "bkmon3racct")

    # X is intentionally NOT PUT into :smalt_resources — the fallback
    # branch is the subject. Seed rows through the real telemetry handler.
    record_requests(path, 42)

    {status, rsp} = get(metrics_url(path, "Requests"))

    assert status == 200, "expected 200, got #{status}: #{inspect(rsp)}"
    value = decode_envelope(rsp)
    assert [%{"timeseries" => [%{"data" => data}]}] = value

    totals =
      data |> Enum.map(&Map.get(&1, "total")) |> Enum.reject(&is_nil/1) |> Enum.sum()

    assert totals >= 1.0,
           "expected nonzero Requests totals from the accumulator, got #{inspect(data)}"

    # RequestDuration rows for the same resource are separately addressable.
    {status2, rsp2} = get(metrics_url(path, "RequestDuration"))
    assert status2 == 200
    value2 = decode_envelope(rsp2)
    assert [%{"timeseries" => [%{"data" => data2}]}] = value2

    assert Enum.any?(data2, fn b -> Map.get(b, "total", 0) >= 42.0 end),
           "expected RequestDuration total >= 42.0, got #{inspect(data2)}"
  end

  test "L2: store-miss GET for unknown Y returns the empty envelope (200)" do
    y = res("sub-bkmon3r-l2", "rg-bkmon3r", "Microsoft.Storage", "storageAccounts", "noacct")

    {status, rsp} = get(metrics_url(y, "Requests"))

    assert status == 200, "expected 200, got #{status}: #{inspect(rsp)}"
    assert decode_envelope(rsp) == []
  end

  test "L3: case-insensitive — rows recorded under the handler's mixed-case canonical path, route id in another casing" do
    sub = "sub-bkmon3r-l3"
    path = res(sub, "Rg-BkMon3R", "Microsoft.Storage", "storageAccounts", "CaseAcct")

    record_requests(path, 7)

    # Route id in a different casing than the recorded canonical path.
    route_id = res(sub, "rg-BKMON3R", "microsoft.storage", "storageaccounts", "caseacct")
    {status, rsp} = get(metrics_url(route_id, "Requests"))

    assert status == 200
    value = decode_envelope(rsp)
    assert [%{"timeseries" => [%{"data" => data}]}] = value

    assert Enum.any?(data, fn b -> Map.get(b, "total", 0) >= 1.0 end),
           "expected case-insensitive match, got #{inspect(data)}"
  end

  test "L4: series/5 exact-equality does not leak a sibling resource's rows" do
    sub = "sub-bkmon3r-l4"
    a = res(sub, "rg-bkmon3r", "Microsoft.EventHub", "namespaces", "nsl4")
    b = res(sub, "rg-bkmon3r", "Microsoft.EventHub", "namespaces", "nsl4x")

    record_requests(a, 11)

    {status, rsp} = get(metrics_url(b, "Requests"))
    assert status == 200
    assert decode_envelope(rsp) == []
  end
end
