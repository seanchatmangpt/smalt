# AZURE-FIDELITY lane 4 — tags/locks/role-assignments ARM surface.
#
# Gate:
# - tag CRUD at all three scopes (subscription / RG / resource)
# - THE LAW: CanNotDelete lock -> generic resource DELETE answers the
#   documented 409 ScopeLocked and the resource SURVIVES
# - ReadOnly lock -> writes denied (PUT/PATCH/tags-write at resource scope)
# - delete lock then unlock -> delete succeeds (202 LRO)
# - role-assignment list shape
#
# Chicago discipline: real Store tables, real ARM router dispatch (Plug
# in-process), real Smalt.Policy lock table — asserts on final store state,
# no mocks.
#
# Context: AZURE-FIDELITY wave, lane 4 (this file). Lane 1's ProviderState
# lifecycle rows are consumed read-only via drop_lifecycle/1 on delete.

defmodule Integration.TagsLocksTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias Smalt.Store

  @api_version "2021-04-01"
  @sub "00000000-0000-0000-0000-000000000000"
  @rg "rg-tl"
  @base "/subscriptions/#{@sub}/resourceGroups/#{@rg}"
  @vnet_res_id "/subscriptions/#{@sub}/resourceGroups/#{@rg}/providers/Microsoft.Network/virtualNetworks/vnet1"

  setup do
    case GenServer.start_link(Store, []) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    # State hygiene: the previous test's locks/deletes must not leak into this
    # one (shared store, async: false).
    delete_lock(@vnet_res_id, "ro")
    delete_lock(@vnet_res_id, "no-del")
    delete_lock(@base, "rg-lock")
    arm_req(:delete, "#{@base}/providers/Microsoft.Network/virtualNetworks/vnet1")

    :ok
  end

  defp arm_req(method, path, body \\ nil, api_version \\ @api_version) do
    url = "#{path}?api-version=#{api_version}"

    conn =
      if body do
        conn(method, url, Jason.encode!(body))
        |> Plug.Conn.put_req_header("content-type", "application/json")
      else
        conn(method, url)
      end

    Smalt.ArmGateway.Router.call(Plug.Conn.fetch_query_params(conn), [])
  end

  defp put_rg do
    arm_req(:put, "/subscriptions/#{@sub}/resourceGroups/#{@rg}", %{
      "location" => "eastus",
      "tags" => %{"env" => "test"}
    })
  end

  defp put_vnet do
    arm_req(:put, "#{@base}/providers/Microsoft.Network/virtualNetworks/vnet1", %{
      "location" => "eastus",
      "addressPrefixes" => ["10.0.0.0/16"],
      "properties" => %{"addressSpace" => %{"addressPrefixes" => ["10.0.0.0/16"]}}
    })
  end

  defp put_lock(scope_path, name, level) do
    arm_req(:put, "#{scope_path}/providers/Microsoft.Authorization/locks/#{name}", %{
      "properties" => %{"level" => level, "notes" => "lane4 court"}
    }, "2020-05-01")
  end

  defp delete_lock(scope_path, name) do
    arm_req(:delete, "#{scope_path}/providers/Microsoft.Authorization/locks/#{name}", nil, "2020-05-01")
  end

  defp scope_locked?(conn), do: conn.status == 409 and conn.resp_body =~ "ScopeLocked"

  defp assert_create(conn), do: assert(conn.status in [200, 201], "got #{conn.status}: #{conn.resp_body}")

  # -- tags at all scopes ------------------------------------------------------

  test "tags CRUD at subscription scope: PUT replace, PATCH merge, GET envelope" do
    assert_create(put_rg())

    put_url = "/subscriptions/#{@sub}/providers/Microsoft.Resources/tags"

    # PUT = replace
    conn = arm_req(:put, put_url, %{"tags" => %{"a" => "1"}})
    assert %{status: 200} = conn
    assert conn.resp_body =~ "\"a\":\"1\""

    # PATCH = merge (a survives, b added)
    conn = arm_req(:patch, put_url, %{"tags" => %{"b" => "2"}})
    assert %{status: 200} = conn
    assert conn.resp_body =~ "\"a\":\"1\"" and conn.resp_body =~ "\"b\":\"2\""

    # PUT replace drops a
    conn = arm_req(:put, put_url, %{"tags" => %{"c" => "3"}})
    assert %{status: 200} = conn
    refute conn.resp_body =~ "\"a\""

    # GET renders the envelope
    conn = arm_req(:get, put_url)
    assert %{status: 200} = conn
    assert conn.resp_body =~ "Microsoft.Resources/tags"
    assert conn.resp_body =~ "\"c\":\"3\""

    # Store truth: tags live on the subscription record
    {:ok, sub} = Store.get(:smalt_subscriptions, @sub)
    assert sub["tags"] == %{"c" => "3"}
  end

  test "tags at subscription scope: unknown subscription 404" do
    conn = arm_req(:put, "/subscriptions/sub-missing/providers/Microsoft.Resources/tags", %{"tags" => %{"x" => "y"}})
    assert %{status: 404} = conn
    assert conn.resp_body =~ "SubscriptionNotFound"
  end

  test "tags CRUD at RG scope (pre-existing KD-113 leg) and null-when-empty law" do
    assert_create(put_rg())

    url = "#{@base}/providers/Microsoft.Resources/tags"
    assert %{status: 200} = arm_req(:put, url, %{"properties" => %{"tags" => %{"k" => "v"}}})

    # empty replace -> null-when-empty law
    conn = arm_req(:put, url, %{"tags" => %{}})
    assert %{status: 200} = conn
    assert conn.resp_body =~ "\"tags\":null"

    {:ok, rg} =
      Store.get(:smalt_resource_groups, String.downcase("/subscriptions/#{@sub}/resourceGroups/#{@rg}"))

    assert rg["tags"] == nil
  end

  test "tags at resource scope: PUT replace / PATCH merge / GET; 404 for missing resource" do
    assert_create(put_rg())
    assert_create(put_vnet())

    url = "#{@vnet_res_id}/providers/Microsoft.Resources/tags"

    # PUT = replace
    assert %{status: 200} = arm_req(:put, url, %{"tags" => %{"tier" => "1"}})

    # PATCH = merge
    conn = arm_req(:patch, url, %{"tags" => %{"env" => "prod"}})
    assert %{status: 200} = conn
    assert conn.resp_body =~ "\"tier\":\"1\"" and conn.resp_body =~ "\"env\":\"prod\""

    # GET envelope + store truth on the resource record
    conn = arm_req(:get, url)
    assert %{status: 200} = conn
    assert conn.resp_body =~ "Microsoft.Resources/tags"
    assert conn.resp_body =~ "\"tier\":\"1\""

    {:ok, rec} = Store.get(:smalt_resources, String.downcase(@vnet_res_id))
    assert rec["tags"] == %{"tier" => "1", "env" => "prod"}

    # unknown resource -> 404 ResourceNotFound
    conn = arm_req(:get, "#{@vnet_res_id}x/providers/Microsoft.Resources/tags")
    assert %{status: 404} = conn
    assert conn.resp_body =~ "ResourceNotFound"
  end

  # -- THE LAW: locks block ------------------------------------------------------

  test "CanNotDelete lock -> resource delete answers 409 ScopeLocked and resource survives" do
    assert_create(put_rg())
    assert_create(put_vnet())

    lock_scope = @vnet_res_id
    assert %{status: 201} = put_lock(lock_scope, "no-del", "CanNotDelete")

    conn = arm_req(:delete, "#{@base}/providers/Microsoft.Network/virtualNetworks/vnet1")
    assert scope_locked?(conn)

    # THE LAW: the resource SURVIVES
    assert {:ok, _rec} = Store.get(:smalt_resources, String.downcase(@vnet_res_id))
  end

  test "ReadOnly lock -> writes denied (PUT/PATCH/tags-write) but reads allowed" do
    assert_create(put_rg())
    assert_create(put_vnet())

    assert %{status: 201} = put_lock(@vnet_res_id, "ro", "ReadOnly")

    # PUT denied
    conn = put_vnet()
    assert scope_locked?(conn)

    # PATCH denied
    conn =
      arm_req(:patch, "#{@base}/providers/Microsoft.Network/virtualNetworks/vnet1", %{
        "tags" => %{"x" => "y"}
      })

    assert scope_locked?(conn)

    # tags write denied
    conn =
      arm_req(:put, "#{@vnet_res_id}/providers/Microsoft.Resources/tags", %{"tags" => %{"w" => "1"}})

    assert scope_locked?(conn)

    # reads still allowed
    assert %{status: 200} = arm_req(:get, "#{@base}/providers/Microsoft.Network/virtualNetworks/vnet1")
    assert %{status: 200} = arm_req(:get, "#{@vnet_res_id}/providers/Microsoft.Resources/tags")

    # store truth: the denied tags write never landed
    {:ok, rec} = Store.get(:smalt_resources, String.downcase(@vnet_res_id))
    refute rec["tags"] == %{"w" => "1"}
  end

  test "delete lock then unlock -> delete succeeds (202 LRO) and record is swept" do
    assert_create(put_rg())
    assert_create(put_vnet())

    assert %{status: 201} = put_lock(@vnet_res_id, "no-del", "CanNotDelete")
    assert scope_locked?(arm_req(:delete, "#{@base}/providers/Microsoft.Network/virtualNetworks/vnet1"))

    assert %{status: 200} = delete_lock(@vnet_res_id, "no-del")

    conn = arm_req(:delete, "#{@base}/providers/Microsoft.Network/virtualNetworks/vnet1")
    assert %{status: 202} = conn
    assert Plug.Conn.get_resp_header(conn, "location") != []

    # store truth: swept
    assert :error = Store.get(:smalt_resources, String.downcase(@vnet_res_id))
  end

  test "RG-scope lock covers child resource delete with ScopeLocked (prefix law)" do
    assert_create(put_rg())
    assert_create(put_vnet())

    assert %{status: 201} = put_lock("#{@base}", "rg-lock", "CanNotDelete")
    assert scope_locked?(arm_req(:delete, "#{@base}/providers/Microsoft.Network/virtualNetworks/vnet1"))
    assert {:ok, _} = Store.get(:smalt_resources, String.downcase(@vnet_res_id))
  end

  # -- role assignments ----------------------------------------------------------

  test "role-assignment list shape at subscription and RG scope" do
    assert_create(put_rg())

    body = %{
      "location" => "eastus",
      "properties" => %{
        "roleDefinitionId" => "/subscriptions/#{@sub}/providers/Microsoft.Authorization/roleDefinitions/acdd72a7-3385-48ef-bd42-f606fba81ae7",
        "principalId" => "11111111-2222-3333-4444-555555555555"
      }
    }

    assert %{status: 201} =
             arm_req(:put, "/subscriptions/#{@sub}/providers/Microsoft.Authorization/roleAssignments/ra-1", body)

    assert %{status: 201} =
             arm_req(:put, "#{@base}/providers/Microsoft.Authorization/roleAssignments/ra-2", body)

    conn = arm_req(:get, "/subscriptions/#{@sub}/providers/Microsoft.Authorization/roleAssignments")
    assert %{status: 200} = conn
    assert %{"value" => rows} = Jason.decode!(conn.resp_body)
    assert is_list(rows) and rows != []

    for ra <- rows do
      assert is_binary(ra["id"])
      assert ra["type"] == "Microsoft.Authorization/roleAssignments"
      assert is_binary(get_in(ra, ["properties", "principalId"]))
      assert is_binary(get_in(ra, ["properties", "roleDefinitionId"]))
    end

    conn = arm_req(:get, "#{@base}/providers/Microsoft.Authorization/roleAssignments")
    assert %{status: 200} = conn
    assert %{"value" => rows} = Jason.decode!(conn.resp_body)
    assert Enum.any?(rows, fn ra -> ra["name"] == "ra-2" end)
  end
end
