# GraphLaw gate cost — in-process microbenchmarks (pure calls, no HTTP).
# Run by scripts/stress/gate_cost.py via:  MIX_ENV=dev mix run --no-start <this file>
#
# Measures:
#   1. Per-type validate_resource latency: 38 admitted types x 500 valid +
#      500 malformed payloads, p50/p95 in microseconds (engine fast-path off).
#   2. Registry lookup cost: 100k calls each of shape_for/latest_version/
#      admitted?, nanoseconds per op.
#
# Writes tmp/gate-cost-inproc.json.

defmodule GateCost do
  # Valid payload per shape (covers every required path; extra keys allowed
  # because no shape in priv/shacl/smalt-shapes.ttl is sh:closed).
  @valid_by_shape %{
    "DefaultShape" => %{"location" => "eastus"},
    "ResourceGroupShape" => %{"location" => "eastus"},
    "VNetShape" => %{"location" => "eastus", "addressPrefixes" => ["10.0.0.0/8"]},
    "SubnetShape" => %{"addressPrefix" => "10.0.0.0/24"},
    "NsgShape" => %{"location" => "eastus"},
    "VirtualMachineShape" => %{"location" => "eastus", "vmSize" => "Standard_D2s_v3"},
    "KeyVaultShape" => %{"location" => "eastus", "skuName" => "standard"},
    "ManagedHsmShape" => %{"location" => "eastus", "skuName" => "standard"},
    "StorageAccountShape" => %{"location" => "eastus", "skuName" => "Standard"},
    "ServiceBusNamespaceShape" => %{"location" => "eastus", "skuName" => "Standard"},
    "CosmosAccountShape" => %{"location" => "eastus"}
  }

  @n 500

  def run do
    types = Smalt.Registry.admitted_resource_types()

    unless length(types) == 38 do
      IO.puts(:stderr, "expected 38 admitted types, got #{length(types)}")
      System.halt(2)
    end

    # sanity: every type resolves to a known shape, valid payloads pass,
    # malformed payloads are refused/invalid
    per_type =
      Enum.map(types, fn type ->
        shape_name = Smalt.Registry.shape_for(type)
        payload = Map.fetch!(@valid_by_shape, shape_name)

        {:ok} = Smalt.GraphLaw.Validator.validate_resource(type, payload)

        assert_bad(type)

        {valid_ts, invalid_ts} = bench_type(type, payload)

        %{
          "type" => type,
          "shape" => shape_name,
          "required_props" => required_count(shape_name),
          "valid_p50_us" => p50(valid_ts),
          "valid_p95_us" => p95(valid_ts),
          "invalid_p50_us" => p50(invalid_ts),
          "invalid_p95_us" => p95(invalid_ts),
          "n_valid" => length(valid_ts),
          "n_invalid" => length(invalid_ts)
        }
      end)

    reg = bench_registry()

    result = %{
      "schema" => "smalt-gate-cost-inproc/v1",
      "elixir" => System.version(),
      "otp" => :otp_release |> :erlang.system_info() |> List.to_string(),
      "per_type" => per_type,
      "registry" => reg
    }

    json = Jason.encode!(result)
    File.write!("tmp/gate-cost-inproc.json", json)
    IO.puts(json)
  end

  # NOTE: Microsoft.Network/networkSecurityGroups binds NsgShape, which
  # declares zero constraints (no required props, sh:closed false) — the empty
  # payload is legitimately conforming there, so only {:ok} is special-cased.
  defp assert_bad("Microsoft.Network/networkSecurityGroups") do
    {:ok} = Smalt.GraphLaw.Validator.validate_resource("Microsoft.Network/networkSecurityGroups", %{})
    :ok
  end

  defp assert_bad(type) do
    case Smalt.GraphLaw.Validator.validate_resource(type, %{}) do
      {:invalid, _violations} -> :ok
      {:refused, _} -> :ok
      {:ok} -> raise "empty payload admitted for #{type}"
      other -> raise "unexpected verdict #{inspect(other)} for #{type}"
    end
  end

  defp bench_type(type, payload) do
    v = Smalt.GraphLaw.Validator
    # warmup
    for _ <- 1..200, do: v.validate_resource(type, payload)
    for _ <- 1..200, do: v.validate_resource(type, %{})

    valid_ts =
      for _ <- 1..@n do
        t0 = System.monotonic_time(:nanosecond)
        {:ok} = v.validate_resource(type, payload)
        System.monotonic_time(:nanosecond) - t0
      end

    invalid_ts =
      for _ <- 1..@n do
        t0 = System.monotonic_time(:nanosecond)
        _ = v.validate_resource(type, %{})
        System.monotonic_time(:nanosecond) - t0
      end

    {valid_ts, invalid_ts}
  end

  defp required_count("NsgShape"), do: 0
  defp required_count(shape), do: length(Smalt.GraphLaw.Validator.shapes()[shape].required)

  defp bench_registry do
    types = Smalt.Registry.admitted_resource_types()
    count = length(types)

    run100k = fn f ->
      for _ <- 1..100_000, do: f.()
      :ok
    end

    t_shape = time_100k(run100k, fn i -> Smalt.Registry.shape_for(Enum.at(types, rem(i, count))) end)
    t_version = time_100k(run100k, fn i -> Smalt.Registry.latest_version(Enum.at(types, rem(i, count))) end)
    t_admitted = time_100k(run100k, fn i -> Smalt.Registry.admitted?(Enum.at(types, rem(i, count))) end)

    %{
      "n" => 100_000,
      "shape_for_ns_per_op" => t_shape,
      "latest_version_ns_per_op" => t_version,
      "admitted_ns_per_op" => t_admitted
    }
  end

  defp time_100k(_runner, f) do
    t0 = System.monotonic_time(:nanosecond)
    for i <- 1..100_000, do: f.(i - 1)
    dt = System.monotonic_time(:nanosecond) - t0
    Float.round(dt / 100_000, 1)
  end

  defp p50(ts), do: pct(ts, 50) / 1000.0
  defp p95(ts), do: pct(ts, 95) / 1000.0

  defp pct(ts, p) do
    sorted = Enum.sort(ts)
    k = round(p / 100.0 * (length(sorted) - 1))
    Enum.at(sorted, k)
  end
end

GateCost.run()
