defmodule PopcornDemo.AzureCostTest do
  # Chicago-style: the real collaborator is the FETCHED rate card on disk
  # (no network, no mocks) - the same artifact the runtime prices against.
  use ExUnit.Case, async: true

  alias PopcornDemo.AzureCost
  alias PopcornDemo.AzureCost.Line

  @card "azurite-spike/rate-card.json"

  setup_all do
    {rates, meta} = AzureCost.load_rates(@card)
    {:ok, rates: rates, meta: meta}
  end

  test "loads 10 fetched rates with full citations", ctx do
    assert map_size(ctx.rates) == 10
    assert ctx.meta["region"] == "eastus"
    assert ctx.meta["currency"] == "USD"
    assert ctx.meta["rate_count"] == 10

    for {_k, r} <- ctx.rates do
      assert %Line.Rate{} = r
      assert is_binary(r.meter_name) and r.meter_name != ""
      assert is_binary(r.unit) and r.unit != ""
      assert is_number(r.retail_price)
      assert r.fetched_at
    end
  end

  describe "price/3" do
    test "zero profile prices to $0.00 with no lines", ctx do
      assert {:ok, %{lines: [], total: 0.0}} = AzureCost.price(%{}, ctx.rates)
    end

    test "fixed profile arithmetic on fetched rates", ctx do
      hours = 730.0

      profile = %{
        cosmos_reads: 2_000_000,
        cosmos_writes: 500_000,
        cosmos_ru_budget: 400,
        blob_tx: 120_000,
        blob_tx_writes: 30_000,
        blob_gb: 25.0,
        sb_ops: 1_500_000,
        kv_ops: 60_000,
        eh_ingress_gb: 36.0
      }

      assert {:ok, %{lines: lines, total: total}} =
               AzureCost.price(profile, ctx.rates)

      keys = Enum.map(lines, & &1.key)
      for k <- ~w(cosmos_reservation cosmos_burst_overage blob_read_tx
                  blob_write_tx blob_capacity sb_base_unit sb_ops
                  sb_premium_mus kv_ops eh_ingress)a do
        assert k in keys, "missing line #{k}"
      end

      by_key = Map.new(lines, &{&1.key, &1.amount})
      amt = fn k -> Map.fetch!(by_key, k) end

      # Cosmos reservation: 730h * 400/100 = 2920 blocks x 0.008 = 23.36
      assert_in_delta amt.(:cosmos_reservation), 2920 * 0.008, 1.0e-6
      # Burst overage: (2M x 1 + 0.5M x 5)/1M = 4.5 units x 0.25 = 1.125
      assert_in_delta amt.(:cosmos_burst_overage), 4.5 * 0.25, 1.0e-6
      # Blob: 12 x 0.005 + 3 x 0.065 + 25 GB-month x 0.021 = 0.06+0.195+0.525
      assert_in_delta amt.(:blob_read_tx), 120_000 / 10_000 * 0.005, 1.0e-6
      assert_in_delta amt.(:blob_write_tx), 30_000 / 10_000 * 0.065, 1.0e-6
      assert_in_delta amt.(:blob_capacity), 25 * 0.021, 1.0e-6
      # SB: 730 x 0.013441 + 1.5 x 0.0 + 730 x 0.9275
      assert_in_delta amt.(:sb_base_unit), 730 * 0.013441, 1.0e-6
      assert_in_delta amt.(:sb_ops), 0.0, 1.0e-9
      assert_in_delta amt.(:sb_premium_mus), 730 * 0.9275, 1.0e-6
      # KV: 60_000/10K = 6 x 0.03 = 0.18
      assert_in_delta amt.(:kv_ops), 6 * 0.03, 1.0e-6
      # EH: 36 GB / 3.6 = 10 TU-hours x 0.03 = 0.30
      assert_in_delta amt.(:eh_ingress), 10 * 0.03, 1.0e-6

      # every line cites its fetched meter
      for line <- lines do
        assert %Line{} = line
        assert line.rate.meter_name
        assert_in_delta line.rate.retail_price, line.amount / line.qty, 1.0e-9
      end

      # total = sum of lines: 23.36 + 1.125 + 0.06 + 0.195 + 0.525
      #   + 9.81193 + 0.0 + 677.075 + 0.18 + 0.30 = 712.63193
      assert_in_delta total, 712.63193, 1.0e-6
      assert_in_delta total,
                      Enum.sum(Map.values(by_key)),
                      1.0e-9
    end

    test "every output line carries its meter citation", ctx do
      profile = %{cosmos_reads: 100, kv_ops: 5, eh_ingress_gb: 7.2}

      assert {:ok, %{lines: lines}} = AzureCost.price(profile, ctx.rates)

      for line <- lines do
        assert is_binary(line.rate.meter_name)
        assert is_binary(line.rate.sku_name)
        assert is_binary(line.rate.unit)
        assert is_number(line.rate.retail_price)
        assert line.amount == line.rate.retail_price * line.qty
      end
    end

    test "displacement/2 equals the azure bill of the local workload", ctx do
      profile = %{blob_tx: 5_000, sb_ops: 2_000}

      assert {:ok, d} = AzureCost.displacement(profile, ctx.rates)
      assert {:ok, p} = AzureCost.price(profile, ctx.rates)
      assert d.total == p.total
      assert d.lines == p.lines
    end

    test "missing rate fails loudly, not silently zero" do
      bad = %{"kv_ops" => nil}
      assert {:error, {:missing_rates, ["kv_ops"]}} =
               AzureCost.price(%{kv_ops: 10}, bad)
    end

    test "unknown profile key is rejected" do
      {rates, _} = AzureCost.load_rates(@card)
      assert {:error, {:unknown_profile_keys, [:wat]}} =
               AzureCost.price(%{wat: 1}, rates)
    end
  end
end
