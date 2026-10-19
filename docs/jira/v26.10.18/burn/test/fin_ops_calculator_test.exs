defmodule Smalt.FinOps.CalculatorTest do
  use ExUnit.Case, async: true

  alias Smalt.FinOps.Calculator

  describe "retail_tariffs/0 — exact-rate rows ported from workspace/lib/finops/calculator.ts" do
    test "storage_account: $0.02/mo prorated /730 + $0.05/GB" do
      t = Calculator.retail_tariffs().storage_account
      assert_in_delta t.usd_per_hour, 0.02 / 730, 1.0e-12
      assert t.usd_per_unit == 0.05
    end

    test "key_vault: $0.03 per secret-version, no hourly" do
      t = Calculator.retail_tariffs().key_vault
      assert t.usd_per_hour == 0.0
      assert t.usd_per_unit == 0.03
    end

    test "eventhub_standard: $0.03/hour, no unit charge" do
      t = Calculator.retail_tariffs().eventhub_standard
      assert_in_delta t.usd_per_hour, 0.03, 1.0e-12
      assert t.usd_per_unit == 0.0
    end

    test "servicebus_standard: $0.05/hour" do
      t = Calculator.retail_tariffs().servicebus_standard
      assert_in_delta t.usd_per_hour, 0.05, 1.0e-12
      assert t.usd_per_unit == 0.0
    end

    test "cosmos_serverless: $0.25/mo prorated + $0.25/GB" do
      t = Calculator.retail_tariffs().cosmos_serverless
      assert_in_delta t.usd_per_hour, 0.25 / 730, 1.0e-12
      assert t.usd_per_unit == 0.25
    end

    test "resource_group is free (TS note: management-plane construct only)" do
      t = Calculator.retail_tariffs().resource_group
      assert t.usd_per_hour == 0.0 and t.usd_per_unit == 0.0
    end
  end

  describe "avoided_tariff_cents/2,3" do
    test "exact-rate: 1 GB storage over 730 hours = 2 + 5 = 7 cents" do
      assert {:ok, 7} = Calculator.avoided_tariff_cents(:storage_account, 1, hours: 730.0)
    end

    test "exact-rate: 10 key vault secret-versions = 30 cents" do
      assert {:ok, 30} = Calculator.avoided_tariff_cents(:key_vault, 10)
    end

    test "exact-rate: 1 eventhub standard hour = 3 cents" do
      assert {:ok, 3} = Calculator.avoided_tariff_cents(:eventhub_standard, 1)
    end

    test "fractional metering rounds to integer cents" do
      # 1 storage unit for 365h: 0.01 + 0.05 = 0.06 USD = 6 cents exactly
      assert {:ok, 6} = Calculator.avoided_tariff_cents(:storage_account, 1, hours: 365.0)
      # 1 servicebus hour × 0.05 → 5 cents
      assert {:ok, 5} = Calculator.avoided_tariff_cents(:servicebus_standard, 1)
    end

    test "zero quantity is zero cents" do
      assert {:ok, 0} = Calculator.avoided_tariff_cents(:eventhub_standard, 0)
    end

    test "unknown resource → typed {:error, :unknown_resource} (TS UNKNOWN_RESOURCE_TYPE)" do
      assert {:error, :unknown_resource} =
               Calculator.avoided_tariff_cents(:virtual_machine, 1)

      assert {:error, :unknown_resource} = Calculator.avoided_tariff_cents(:blob_gpus, 3)
    end

    test "region multiplier: westus2 at 1.08 scales eastus baseline" do
      {:ok, base} = Calculator.avoided_tariff_cents(:key_vault, 1000)
      {:ok, west} = Calculator.avoided_tariff_cents(:key_vault, 1000, region: :westus2)
      assert base == 3000
      assert west == round(base * 1.08)
      assert west == 3240
    end

    test "default region is eastus (multiplier 1.0, identical to explicit)" do
      {:ok, default} = Calculator.avoided_tariff_cents(:eventhub_standard, 5)
      {:ok, explicit} = Calculator.avoided_tariff_cents(:eventhub_standard, 5, region: :eastus)
      assert default == explicit
      assert default == 15
    end

    test "unknown region → {:error, :unknown_region}" do
      assert {:error, :unknown_region} =
               Calculator.avoided_tariff_cents(:key_vault, 1, region: :moonbase1)
    end

    test "deterministic: repeated calls byte-identical" do
      results =
        for _ <- 1..50 do
          Calculator.avoided_tariff_cents(:storage_account, 3, region: :northeurope, hours: 24.0)
        end

      assert Enum.uniq(results) == [hd(results)]
      assert {:ok, _} = hd(results)
    end
  end

  describe "avoided_spend_cents/2 — manifest form of TS computeAvoidedSpend" do
    test "matches TS formula Σ count*(hourly*hours+unit) × cycles" do
      manifest = [
        %{type: :storage_account, count: 2},
        %{type: :key_vault, count: 10}
      ]

      # hours = 1h: 2*(0.02/730 + 0.05) + 10*0.03 = 0.4000547945.. USD *100 = 40.005 → 40
      assert {:ok, 40} = Calculator.avoided_spend_cents(manifest, durations_ms: 3_600_000)
    end

    test "cycles multiply the per-cycle total (TS totalUsd = perCycleUsd * cycles)" do
      manifest = [%{type: :eventhub_standard, count: 1}]

      {:ok, one} = Calculator.avoided_spend_cents(manifest, durations_ms: 3_600_000)
      {:ok, three} = Calculator.avoided_spend_cents(manifest, durations_ms: 3_600_000, cycles: 3)
      assert three == one * 3
    end

    test "unknown resource in manifest → {:error, :unknown_resource}" do
      assert {:error, :unknown_resource} =
               Calculator.avoided_spend_cents([%{type: :nat_gateway, count: 1}])
    end
  end
end
