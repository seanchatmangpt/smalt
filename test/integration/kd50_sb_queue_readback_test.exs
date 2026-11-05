defmodule Smalt.Integration.Kd50SbQueueReadbackTest do
  use ExUnit.Case, async: false

  # KD-COVERS: KD-50 — SB queue property camelCase readback. PUT/GET round-trip
  # through the real ARM router + real :smalt_resources store (no mocks):
  # a queue provisioned with camelCase `lockDuration` must read back camelCase
  # (lossy snake_case normalization is the registered divergence) and must
  # feed the delivery-claim lock path (queue_settings/1), not starve it into
  # the 30 s default. Lock-expiry falsifier uses the pure LockManager.expired?/2
  # clock (injectable `now`), never Process.sleep (no-sleep doctrine).
  # Wire witness with real SDK redelivery: docs/jira/v26.10.20/receipts/kd47-kd50-kd72-k6-witness.md

  alias Plug.Conn
  import Plug.Test

  @parsers_opts Plug.Parsers.init(
                  parsers: [:json, :urlencoded],
                  pass: ["*/*"],
                  json_decoder: {Smalt.JsonCompat, :decode!, []}
                )

  # The mounted ARM pipeline runs Plug.Parsers before the router; standalone
  # dispatch reproduces that state with the REAL Plug.Parsers — no mocks
  # (same composition as acr_test.exs / container_groups_test.exs). XML bodies
  # pass through Plug.Parsers untouched (pass: ["*/*"]) but body_params is
  # fetched, which the receipt turnstile requires.
  defp dispatch(conn) do
    conn
    |> Plug.Conn.fetch_query_params()
    |> Plug.Parsers.call(@parsers_opts)
    |> then(&Smalt.ArmGateway.Router.call(&1, []))
  end

  defp find_resource_key(name) do
    suffix = "/queues/#{String.downcase(name)}"

    case Enum.find(Smalt.Store.keys(:smalt_resources), &String.ends_with?(&1, suffix)) do
      nil -> {:error, :not_found}
      key -> {:ok, key}
    end
  end

  # Namespace parent must exist (GraphLaw: skuName required) before the queue
  # child PUT is admitted — real ARM ordering.
  defp ensure_namespace do
    conn =
      "PUT"
      |> conn("/subscriptions/emulator-atom/resourceGroups/emulator/providers/Microsoft.ServiceBus/namespaces/emulator?api-version=2024-01-01", Jason.encode!(%{"location" => "eastus", "sku" => %{"name" => "Standard", "tier" => "Standard"}}))
      |> Conn.put_req_header("content-type", "application/json")
      |> dispatch()

    assert conn.status in [200, 201, 202]
  end

  defp put_queue(name, props) do
    # Real Azure mgmt-SDK wire shape: camelCase properties under "properties"
    # (JSON — the exact face KD-50 registered: camelCase lockDuration via ARM PUT).
    body = Jason.encode!(%{"properties" => props})

    "PUT"
    |> conn("/subscriptions/emulator-atom/resourceGroups/emulator/providers/Microsoft.ServiceBus/namespaces/emulator/queues/#{name}?api-version=2024-01-01", body)
    |> Conn.put_req_header("content-type", "application/json")
    |> dispatch()
  end

  defp get_queue(name) do
    "GET"
    |> conn("/subscriptions/emulator-atom/resourceGroups/emulator/providers/Microsoft.ServiceBus/namespaces/emulator/queues/#{name}?api-version=2024-01-01")
    |> dispatch()
  end

  test "PT2S queue: camelCase PUT readback is camelCase on the GET wire and feeds the lock path" do
    name = "kd50-pt2s-#{System.system_time(:millisecond)}"

    ensure_namespace()
    put = put_queue(name, %{"lockDuration" => "PT2S", "maxDeliveryCount" => 5, "requiresSession" => false})
    assert put.status in [200, 201, 202]

    # 1. stored record: camelCase keys, no lossy snake_case normalization
    {:ok, key} = find_resource_key(name)
    {:ok, record} = Smalt.Store.get(:smalt_resources, key)
    assert record["properties"]["lockDuration"] == "PT2S"
    refute Map.has_key?(record["properties"], "lock_duration")
    assert record["properties"]["maxDeliveryCount"] == 5

    # 2. GET readback: camelCase on the wire (byte shape real SDKs read back)
    get = get_queue(name)
    assert get.status == 200
    assert get.resp_body =~ "\"lockDuration\""
    refute get.resp_body =~ "lock_duration"

    # 3. delivery-claim lock path: PT2S survives to queue_settings, not clamped to 30 s
    settings = Smalt.Amqp.QueueStore.queue_settings(name)
    assert settings.lock_duration_ms == 2_000
    assert settings.max_delivery_count == 5

    # 4. falsifier: PT2S queue enforces 2 s lock expiry (pure clock, no sleep)
    now = System.system_time(:millisecond)
    locked_until = now + settings.lock_duration_ms
    assert Smalt.Amqp.LockManager.expired?(locked_until, now + 2_000)
    refute Smalt.Amqp.LockManager.expired?(locked_until, now + 1_999)

    assert get_queue(name).status == 200
  end

  test "default-30s control queue does NOT expire the lock at 2 s" do
    name = "kd50-ctrl-#{System.system_time(:millisecond)}"

    ensure_namespace()
    assert put_queue(name, %{"maxDeliveryCount" => 10}).status in [200, 201, 202]

    # control reads back the 30 s default and is NOT expired at T+2 s —
    # proving test 1's expiry comes from the read-back PT2S, not the clamp default
    settings = Smalt.Amqp.QueueStore.queue_settings(name)
    assert settings.lock_duration_ms == 30_000

    now = System.system_time(:millisecond)
    refute Smalt.Amqp.LockManager.expired?(now + settings.lock_duration_ms, now + 2_000)
  end
end
