defmodule Smalt.Test.Integration.Kd156SbShapeTest do
  @moduledoc """
  KD-156 court — ARM REST SB provisioning shape gate.

  Chicago-style: real HTTP-shaped dispatch through `Smalt.ArmGateway.Router`
  (in-process, ephemeral self-booted app, no mocks), asserting final wire
  state. Fences:

    1. namespace PUT minimal body `{"location": .., "sku": ..}` admits
    2. a child queue PUT body WITHOUT `location` admits (Azure parity:
       children inherit region from the parent) — fences the KD-156 fix
    3. queue PUT under a MISSING namespace → 404 ResourceNotFound
       (Azure-matching parent-existence gate; conformant, no fix)
    4. namespace PUT without location still refuses typed
       InvalidResourceShape (the SB namespace shape's own minCount stays loud)

  A regression of any leg flips its assertion and exits 1.
  """

  use ExUnit.Case, async: false

  import Plug.Test

  @api_version "2022-10-01-preview"
  @sub "sub-kd156"
  @rg "rg-kd156"
  @base "/subscriptions/#{@sub}/resourceGroups/#{@rg}"

  setup_all do
    {:ok, _} = Application.ensure_all_started(:smalt)
    :ok
  end

  defp arm_req(method, path, body \\ nil) do
    url = "#{path}?api-version=#{@api_version}"

    conn =
      if body do
        conn(method, url, Jason.encode!(body))
        |> Plug.Conn.put_req_header("content-type", "application/json")
      else
        conn(method, url)
      end

    Smalt.ArmGateway.Router.call(Plug.Conn.fetch_query_params(conn), [])
  end

  defp put_ns(ns, body),
    do: arm_req(:put, "#{@base}/providers/Microsoft.ServiceBus/namespaces/#{ns}", body)

  defp put_queue(ns, q, body),
    do: arm_req(:put, "#{@base}/providers/Microsoft.ServiceBus/namespaces/#{ns}/queues/#{q}", body)

  defp decode(conn), do: Jason.decode!(conn.resp_body)

  test "KD-156 leg 1: namespace PUT minimal body admits" do
    ns = "kd156a-#{System.unique_integer([:positive])}"

    conn = put_ns(ns, %{"location" => "eastus", "sku" => %{"name" => "Standard"}})

    assert conn.status in [201, 202],
           "namespace PUT minimal body must admit, got #{conn.status}: #{conn.resp_body}"
  end

  test "KD-156 leg 2: queue PUT without location admits (DefaultShape not coerced)" do
    ns = "kd156b-#{System.unique_integer([:positive])}"
    assert put_ns(ns, %{"location" => "eastus", "sku" => %{"name" => "Standard"}}).status in [201, 202]

    conn =
      put_queue(ns, "qnoloc", %{
        "properties" => %{"lockDuration" => "PT1M"}
      })

    assert conn.status in [201, 200],
           "child queue PUT without location must admit, got #{conn.status}: #{conn.resp_body}"

    refute conn.resp_body =~ "at most one location"
  end

  test "KD-156 leg 3: queue under missing namespace 404s (Azure-conformant gate)" do
    conn = put_queue("nosuchns-kd156", "q2", %{})

    assert conn.status == 404
    assert decode(conn)["error"]["code"] == "ResourceNotFound"
  end

  test "KD-156 leg 4: namespace PUT without location still refuses typed InvalidResourceShape" do
    ns = "kd156d-#{System.unique_integer([:positive])}"

    conn = put_ns(ns, %{"sku" => %{"name" => "Standard"}})

    assert conn.status == 400
    assert decode(conn)["error"]["code"] == "InvalidResourceShape"
    assert decode(conn)["error"]["message"] =~ "serviceBus namespaces require location"
  end
end
