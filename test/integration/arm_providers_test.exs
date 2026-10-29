# AZURE-FIDELITY lane 1 — ARM provider completeness sweep (integration tier).
#
# Chicago discipline: real in-process dispatch through Smalt.ArmGateway.Router,
# real ProviderState ETS, real Store rows. No mocks. Each new route answers the
# documented Microsoft Learn ARM wire shape; registration lifecycle is stateful
# (register/unregister persist; a later GET of the provider reads the stored
# state back); PUT -> RG listing -> DELETE round-trip over an admitted type.
defmodule Smalt.Internal.ArmProvidersCompletenessTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias Smalt.ArmGateway.Router

  @sub "sub-prov-lane1"
  @rg "rg-prov-lane1"
  @base "/subscriptions/#{@sub}/resourceGroups/#{@rg}"
  @av "api-version=2021-04-01"

  # -- GET /providers (+ subscription scope): documented ProviderListResult -----

  test "GET /providers and /subscriptions/:sub/providers answer the documented list envelope" do
    for path <- ["/providers?#{@av}", "/subscriptions/#{@sub}/providers?#{@av}"] do
      conn = dispatch(:get, path)

      assert conn.status == 200

      body = Jason.decode!(conn.resp_body)

      assert %{"value" => providers} = body

      assert is_list(providers) and providers != []

      for p <- providers do
        assert is_binary(p["namespace"])
        assert is_list(p["resourceTypes"])
      end
    end
  end

  test "GET /providers/:ns answers the documented provider shape; unknown ns 404s typed" do
    conn = dispatch(:get, "/providers/Microsoft.Compute?#{@av}")

    assert conn.status == 200

    body = Jason.decode!(conn.resp_body)

    assert body["namespace"] == "Microsoft.Compute"
    assert body["registrationState"] in ["Registered", "Unregistered", "Unregistering", "Registering"]
    assert %{"resourceTypes" => rts} = body

    assert Enum.any?(rts, &(&1["resourceType"] == "virtualMachines" and is_list(&1["apiVersions"])))

    missing = dispatch(:get, "/providers/Not.AProvider?#{@av}")

    assert missing.status == 404

    assert Jason.decode!(missing.resp_body)["error"]["code"] == "ResourceNotFound"
  end

  # -- Per-provider operations index (documented GET /providers/{ns}/operations) --

  test "GET /providers/:ns/operations derives from the provider matrix; subscription scope too" do
    for path <- [
          "/providers/Microsoft.Compute/operations?#{@av}",
          "/subscriptions/#{@sub}/providers/Microsoft.Compute/operations?#{@av}"
        ] do
      conn = dispatch(:get, path)

      assert conn.status == 200

      ops =
        conn.resp_body
        |> Jason.decode!()
        |> Map.fetch!("value")
        |> Map.new(&{&1["name"], &1})

      # read/write/delete per admitted resource type + the operations self-row.
      assert Map.has_key?(ops, "Microsoft.Compute/virtualMachines/read")
      assert Map.has_key?(ops, "Microsoft.Compute/virtualMachines/write")
      assert Map.has_key?(ops, "Microsoft.Compute/virtualMachines/delete")
      assert Map.has_key?(ops, "Microsoft.Compute/operations/read")

      for {_name, op} <- ops do
        assert %{"display" => %{"provider" => "Microsoft.Compute"}, "is_data_action" => false} = op
      end
    end
  end

  test "GET /providers/:ns/operations for an unknown namespace 404s ResourceNotFound" do
    conn = dispatch(:get, "/providers/Not.AProvider/operations?#{@av}")

    assert conn.status == 404

    assert Jason.decode!(conn.resp_body)["error"]["code"] == "ResourceNotFound"
  end

  # -- Registration lifecycle is STATEFUL ----------------------------------------

  test "register/unregister persists: a later GET of the provider reads the stored state" do
    ns = "Microsoft.EventHub"

    on_exit(fn -> Smalt.ArmGateway.ProviderState.clear_registration(@sub, ns) end)

    reg = dispatch(:post, "/subscriptions/#{@sub}/providers/#{ns}/register?#{@av}")

    assert reg.status == 200

    assert Jason.decode!(reg.resp_body)["registrationState"] == "Registered"

    # Separate request: the state PERSISTED (stateful, not echoed).
    get = dispatch(:get, "/subscriptions/#{@sub}/providers/#{ns}?#{@av}")

    assert Jason.decode!(get.resp_body)["registrationState"] == "Registered"

    unreg = dispatch(:post, "/subscriptions/#{@sub}/providers/#{ns}/unregister?#{@av}")

    assert unreg.status == 200

    assert Jason.decode!(unreg.resp_body)["registrationState"] == "Unregistering"

    get2 = dispatch(:get, "/subscriptions/#{@sub}/providers/#{ns}?#{@av}")

    assert Jason.decode!(get2.resp_body)["registrationState"] == "Unregistering"

    # The provider listing at subscription scope reflects the stored state too.
    listing =
      dispatch(:get, "/subscriptions/#{@sub}/providers?#{@av}")
      |> resp_json()
      |> Map.fetch!("value")
      |> Enum.find(&(&1["namespace"] == ns))

    assert listing["registrationState"] == "Unregistering"

    # Restore the default posture for later lanes.
    Smalt.ArmGateway.ProviderState.clear_registration(@sub, ns)
  end

  test "unknown namespace register/unregister 404s ResourceNotFound" do
    for verb <- ["register", "unregister"] do
      conn = dispatch(:post, "/subscriptions/#{@sub}/providers/Not.AProvider/#{verb}?#{@av}")

      assert conn.status == 404

      assert Jason.decode!(conn.resp_body)["error"]["code"] == "ResourceNotFound"
    end
  end

  # -- RG-scoped CRUD round trip (PUT -> RG listing -> DELETE) -------------------

  test "PUT creates a vnet visible in the RG type listing; DELETE removes it" do
    vnet = "vnet-lane1-#{:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)}"
    path = "#{@base}/providers/Microsoft.Network/virtualNetworks/#{vnet}?#{@av}"

    put_conn = dispatch(:put, path, %{"location" => "eastus", "properties" => %{"addressPrefixes" => ["10.42.0.0/16"]}})

    assert put_conn.status == 201

    put_body = Jason.decode!(put_conn.resp_body)

    assert put_body["name"] == vnet
    assert put_body["type"] == "Microsoft.Network/virtualNetworks"

    assert put_body["properties"]["provisioningState"] == "Succeeded"

    # Visible in the RG type listing.
    list_conn = dispatch(:get, "#{@base}/providers/Microsoft.Network/virtualNetworks?#{@av}")

    assert list_conn.status == 200

    names =
      list_conn.resp_body
      |> resp_json()
      |> Map.fetch!("value")
      |> Enum.map(& &1["name"])

    assert vnet in names

    # GET readback echoes.
    get_conn = dispatch(:get, path)

    assert get_conn.status == 200

    assert Jason.decode!(get_conn.resp_body)["properties"]["provisioningState"] == "Succeeded"

    # PATCH 200 partial update.
    patch_conn =
      dispatch(:patch, path, %{"tags" => %{"lane" => "azure-fidelity"}})

    assert patch_conn.status == 200

    # DELETE removes (sync 200, or ARM LRO 202 + Azure-AsyncOperation header
    # — poll the operation to terminal). GET then 404s typed, and the type
    # listing drops it.
    del_conn = dispatch(:delete, path)

    assert del_conn.status in [200, 202]

    if del_conn.status == 202 do
      op_url =
        del_conn |> Plug.Conn.get_resp_header("azure-asyncoperation") |> List.first() ||
          del_conn |> Plug.Conn.get_resp_header("location") |> List.first()

      assert is_binary(op_url)

      op_path = String.replace(op_url, "https://localhost:9443", "")
      poll_delete_to_terminal(op_path, 50)
    end

    gone = dispatch(:get, path)

    assert gone.status == 404

    assert Jason.decode!(gone.resp_body)["error"]["code"] == "ResourceNotFound"

    names_after =
      dispatch(:get, "#{@base}/providers/Microsoft.Network/virtualNetworks?#{@av}")
      |> resp_json()
      |> Map.fetch!("value")
      |> Enum.map(& &1["name"])

    refute vnet in names_after
  end

  # -- $expand=createdTime,changedTime on documented list operations -------------

  test "$expand projects lifecycle timestamps on Resources and ResourceGroups lists" do
    vnet = "vnet-exp-#{:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)}"

    path = "#{@base}/providers/Microsoft.Network/virtualNetworks/#{vnet}"

    vnet_body = %{
      "location" => "eastus",
      "properties" => %{"addressPrefixes" => ["10.43.0.0/16"]}
    }

    assert dispatch(:put, "#{path}?#{@av}", vnet_body).status == 201

    on_exit(fn -> dispatch(:delete, "#{path}?#{@av}") end)

    # Absent $expand: timestamps are absent (real ARM omits them by default).
    plain =
      dispatch(:get, "/subscriptions/#{@sub}/resources?#{@av}")
      |> resp_json()
      |> Map.fetch!("value")
      |> Enum.find(&(&1["name"] == vnet))

    assert %{"name" => ^vnet} = plain
    refute Map.has_key?(plain, "createdTime")
    refute Map.has_key?(plain, "changedTime")

    expanded =
      dispatch(:get, "/subscriptions/#{@sub}/resources?#{@av}&$expand=createdTime,changedTime")
      |> resp_json()
      |> Map.fetch!("value")
      |> Enum.find(&(&1["name"] == vnet))

    assert is_binary(expanded["createdTime"])
    assert is_binary(expanded["changedTime"])

    # ResourceGroups list carries the same documented $expand semantics.
    assert dispatch(:put, "/subscriptions/#{@sub}/resourcegroups/#{@rg}?#{@av}", %{"location" => "eastus"}).status in [200, 201]

    rg_expanded =
      dispatch(:get, "/subscriptions/#{@sub}/resourcegroups?#{@av}&$expand=createdTime,changedTime")
      |> resp_json()
      |> Map.fetch!("value")
      |> Enum.find(&(&1["name"] == @rg))

    assert is_binary(rg_expanded["createdTime"])
  end

  test "unparseable/unknown $expand fields are ignored (default shape, no timestamps)" do
    conn = dispatch(:get, "/subscriptions/#{@sub}/resources?#{@av}&$expand=notAField")

    assert conn.status == 200

    for item <- Jason.decode!(conn.resp_body)["value"] do
      refute Map.has_key?(item, "createdTime")
    end
  end

  # -- helpers -------------------------------------------------------------------

  defp resp_json(%Plug.Conn{} = conn), do: Jason.decode!(conn.resp_body)
  defp resp_json(body) when is_binary(body), do: Jason.decode!(body)

  # Bounded poll on a real observable (the LRO operation endpoint reaching a
  # terminal status) — never a fixed sleep.
  defp poll_delete_to_terminal(_op_path, 0), do: flunk("LRO delete never reached terminal status")

  defp poll_delete_to_terminal(op_path, remaining) do
    conn = dispatch(:get, op_path)
    status = Jason.decode!(conn.resp_body)["status"]

    if status in ["Succeeded", "Failed", "Canceled"] do
      assert status == "Succeeded"
    else
      poll_delete_to_terminal(op_path, remaining - 1)
    end
  end

  defp dispatch(method, path, body \\ nil) do
    conn =
      if body do
        conn(method, path, Jason.encode!(body))
        |> Plug.Conn.put_req_header("content-type", "application/json")
      else
        conn(method, path)
      end

    Router.call(conn, [])
  end
end
