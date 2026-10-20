# ERRC RAISE lane (v26.10.19 window W2): multi-table DCR streams, per-table
# retention sweep, per-table stats arm. Chicago-style: real Store rows, assert
# on final state; no mocks. Table keys are already per-stream
# (`{dcr}/{stream}/{seq20}`) — these tests witness the separation and exercise
# the new administration arms (Sentinel.set_retention/3, table_stats/1,
# retention_sweep/1) end to end against the real Store.
defmodule DataPlane.SentinelMultitableTest do
  use ExUnit.Case, async: false

  alias Smalt.DataPlane.Sentinel
  alias Smalt.Store

  @api_version "2023-01-01"

  setup do
    dcr = "dcr-mt-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    handler_id = "sentinel-mt-test-#{inspect(self())}"

    :telemetry.attach(handler_id, [:smalt, :sentinel, :retention_sweep], fn _event, measurements,
                                                                             metadata, pid ->
      send(pid, {:sweep_telemetry, measurements, metadata})
    end, self())

    on_exit(fn ->
      :telemetry.detach(handler_id)

      for k <- Store.prefix_keys(:smalt_sentinel_rows, dcr),
          do: Store.delete(:smalt_sentinel_rows, k)

      for k <- Store.prefix_keys(:smalt_sentinel_streams, dcr),
          do: Store.delete(:smalt_sentinel_streams, k)
    end)

    %{dcr: dcr}
  end

  test "witness: one DCR, two streams -> rows land in separate tables, stats separate", %{dcr: dcr} do
    assert {:ok, 204, ""} = Sentinel.ingest(dcr, "StreamA", [%{"m" => "a1"}, %{"m" => "a2"}], @api_version)
    assert {:ok, 204, ""} = Sentinel.ingest(dcr, "StreamB", [%{"m" => "b1"}], @api_version)

    assert 2 == length(Store.list_prefix(:smalt_sentinel_rows, "#{dcr}/StreamA/"))
    assert 1 == length(Store.list_prefix(:smalt_sentinel_rows, "#{dcr}/StreamB/"))

    stats = Sentinel.table_stats(dcr)
    assert %{count: 2, oldest: o, newest: n} = Map.fetch!(stats, "#{dcr}/StreamA")
    assert is_binary(o) and is_binary(n)
    assert %{count: 1} = Map.fetch!(stats, "#{dcr}/StreamB")
  end

  test "set_retention refuses non-positive and non-integer days", %{dcr: dcr} do
    assert {:ok, 204, ""} = Sentinel.ingest(dcr, "S", [%{"m" => 1}], @api_version)

    for bad <- [0, -3, "30", 1.5] do
      assert {:error, 400, %{"error" => %{"code" => "InvalidRetention"}}} =
               Sentinel.set_retention(dcr, "S", bad)
    end
  end

  test "witness: retention sweep drops aged rows ONLY from the configured table", %{dcr: dcr} do
    old = DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -10 * 86_400, :second))
    fresh = DateTime.to_iso8601(DateTime.utc_now())

    assert {:ok, 204, ""} = Sentinel.ingest(dcr, "Keep", [%{"m" => 1, "TimeGenerated" => old}], @api_version)
    assert {:ok, 204, ""} = Sentinel.ingest(dcr, "Sweep", [%{"m" => 2, "TimeGenerated" => old}], @api_version)
    assert {:ok, 204, ""} = Sentinel.ingest(dcr, "Sweep", [%{"m" => 3, "TimeGenerated" => fresh}], @api_version)

    assert {:ok, 1} = Sentinel.set_retention(dcr, "Sweep", 1)

    results = Sentinel.retention_sweep(dcr)
    assert %{dropped: 1, kept: 1} = Map.fetch!(results, "#{dcr}/Sweep")
    assert %{dropped: 0, kept: 1} = Map.fetch!(results, "#{dcr}/Keep")
    assert 1 == length(Store.list_prefix(:smalt_sentinel_rows, "#{dcr}/Sweep/"))
    assert 1 == length(Store.list_prefix(:smalt_sentinel_rows, "#{dcr}/Keep/"))
  end

  test "sweep keeps rows with unparseable TimeGenerated (fail-open keep)", %{dcr: dcr} do
    assert {:ok, 204, ""} = Sentinel.ingest(dcr, "S", [%{"m" => 1, "TimeGenerated" => "not-a-date"}], @api_version)
    assert {:ok, 1} = Sentinel.set_retention(dcr, "S", 1)

    assert %{dropped: 0, kept: 1} = Map.fetch!(Sentinel.retention_sweep(dcr), "#{dcr}/S")
    assert 1 == length(Store.list_prefix(:smalt_sentinel_rows, "#{dcr}/S/"))
  end

  test "table_stats: empty DCR -> empty map; stats report oldest/newest", %{dcr: dcr} do
    assert %{} = Sentinel.table_stats(dcr)

    old = DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -3600, :second))
    assert {:ok, 204, ""} = Sentinel.ingest(dcr, "S", [%{"TimeGenerated" => old}, %{}], @api_version)

    assert %{count: 2, oldest: ^old, newest: newest} = Map.fetch!(Sentinel.table_stats(dcr), "#{dcr}/S")
    assert is_binary(newest) and newest >= old
  end

  test "witness: typed telemetry emitted per swept stream", %{dcr: dcr} do
    assert {:ok, 204, ""} = Sentinel.ingest(dcr, "S", [%{"m" => 1}], @api_version)
    assert {:ok, 1} = Sentinel.set_retention(dcr, "S", 1)

    assert %{dropped: 0, kept: 1} = Map.fetch!(Sentinel.retention_sweep(dcr), "#{dcr}/S")

    assert_received {:sweep_telemetry, %{dropped: 0, kept: 1},
                    %{dcr: ^dcr, stream: "S", retention_days: 1}}
  end
end
