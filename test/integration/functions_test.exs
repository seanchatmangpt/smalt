# Integration-tier witness (Functions ARM + SCM-lite admin surface, integration tier): T-11 court (wave r13).
#
# Chicago discipline: real Store rows (:smalt_resources), real gateway dispatch
# (Smalt.ArmGateway.Router.call in-process — the integrator wiring patch mounts
# Smalt.ArmGateway.Providers.FunctionsRouter immediately BEFORE plug(:match),
# see docs/jira/v26.10.28/receipts/r13-t11-functions.md; WITHOUT that patch
# every route here 404s through the gateway catch-all). No mocks. Auth rides
# the gateway chain (:anonymous in the test env, like sb_arm_rules_test.exs).
#
#   ARM PUT site -> 201 (first) -> GET shape echo (kind functionapp, state Running)
#   config/appSettings PUT -> GET round-trip (StringDictionary shape)
#   synctriggers valid host.json -> 200 -> /admin/functions + /admin/host/status shapes
#   synctriggers malformed JSON / unknown extension / version < 2.0 -> typed 400s
#   /admin/host/keys GET shape + POST renew -> listHostKeys / listFunctionKeys faces
#   invocation endpoints -> typed FunctionRuntimeNotEmulated refusal (never a 200)
#   ARM DELETE -> 200 -> GET 404
#
# Context: solo (integration tier, in-process dispatch). CODE-COMPLETE r13 —
# runs with the next integration pass (compile-freeze SLA: no mix in this lane).

defmodule Smalt.Internal.FunctionsTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias Smalt.Store

  @created 201
  @ok 200
  @bad_request 400
  @not_found 404
  # Global ETS store persists across tests in this file: a site PUT after the
  # first is the idempotent 200, the very first is 201.
  @create_face [200, 201]

  @api_version "2021-04-01"
  @sub "sub-fn"
  @rg "rg-fn"
  @site "myfn"
  @rg_prefix "/subscriptions/#{@sub}/resourceGroups/#{@rg}"
  @site_path "#{@rg_prefix}/providers/Microsoft.Web/sites/#{@site}"
  @site_host "#{@site}.azurewebsites.net"

  setup do
    on_exit(fn ->
      Store.delete(:smalt_resources, String.downcase(@site_path))
    end)

    :ok
  end

  defp arm_req(method, path, body \\ nil) do
    json_conn(method, "#{path}?api-version=#{@api_version}", body)
  end

  # The admin surface lives on the site host: the Host header resolves the
  # site (<name>.azurewebsites.net) — exactly the Core Tools flow. No
  # api-version (the real host admin API carries none).
  defp admin_req(method, path, body \\ nil) do
    json_conn(method, path, body)
    |> Plug.Conn.put_req_header("host", @site_host)
  end

  defp json_conn(method, url, body) do
    conn =
      if body do
        conn(method, url, Jason.encode!(body))
        |> Plug.Conn.put_req_header("content-type", "application/json")
      else
        conn(method, url)
      end

    Smalt.ArmGateway.Router.call(Plug.Conn.fetch_query_params(conn), [])
  end

  defp put_site do
    arm_req(:put, @site_path, %{"location" => "eastus", "properties" => %{"httpsOnly" => true}})
  end

  # -- happy path ----------------------------------------------------------------

  test "ARM PUT site creates (201) -> GET shape echo: kind functionapp, state Running" do
    # Fresh name guarantees the create face regardless of test order.
    fresh = "myfn-#{System.unique_integer([:positive])}"
    fresh_path = "#{@rg_prefix}/providers/Microsoft.Web/sites/#{fresh}"

    on_exit(fn -> Store.delete(:smalt_resources, String.downcase(fresh_path)) end)

    conn = arm_req(:put, fresh_path, %{"location" => "eastus", "properties" => %{}})
    assert conn.status == @created

    site = Jason.decode!(conn.resp_body)
    # Key-level shape asserts (census: no whole-map equality).
    assert site["id"] == fresh_path
    assert site["name"] == fresh
    assert site["type"] == "Microsoft.Web/sites"
    assert site["kind"] == "functionapp"
    assert site["properties"]["state"] == "Running"
    assert site["properties"]["defaultHostName"] == "#{fresh}.azurewebsites.net"
    # Engine state never leaks on the ARM wire face.
    refute Map.has_key?(site["properties"], "hostKeys")
    refute Map.has_key?(site["properties"], "appSettings")

    get_conn = arm_req(:get, fresh_path)
    assert get_conn.status == @ok

    echoed = Jason.decode!(get_conn.resp_body)
    assert echoed["kind"] == "functionapp"
    assert echoed["properties"]["state"] == "Running"

    # Idempotent re-PUT is the 200 face (ARM upsert semantics).
    assert arm_req(:put, fresh_path, %{"location" => "eastus", "properties" => %{}}).status == @ok
  end

  test "config appSettings PUT -> GET round-trips the settings map (StringDictionary shape)" do
    assert put_site().status in @create_face

    settings = %{"AzureWebJobsStorage" => "UseDevelopmentStorage=true", "K1" => "v1"}

    put_conn = arm_req(:put, "#{@site_path}/config/appSettings", %{"properties" => settings})
    assert put_conn.status == @ok

    put_body = Jason.decode!(put_conn.resp_body)
    assert put_body["type"] == "Microsoft.Web/sites/config"
    assert put_body["id"] == "#{@site_path}/config/appSettings"
    assert put_body["properties"] == settings

    get_conn = arm_req(:get, "#{@site_path}/config/appSettings")
    assert get_conn.status == @ok
    assert Jason.decode!(get_conn.resp_body)["properties"] == settings

    # Typed 404 on an unknown site's settings — nothing stored.
    nosite_path = "#{@rg_prefix}/providers/Microsoft.Web/sites/nosite/config/appSettings"
    assert arm_req(:put, nosite_path, %{"properties" => settings}).status == @not_found
  end

  test "synctriggers with valid host.json publishes -> /admin/functions + /admin/host/status shapes" do
    assert put_site().status in @create_face

    valid_host_json =
      Jason.encode!(%{
        "version" => "2.0",
        "extensionBundle" => %{
          "id" => "Microsoft.Azure.Functions.ExtensionBundle",
          "version" => "[4.*, 5.0.0)"
        }
      })

    # The engine face itself: a valid host.json is literal :ok.
    assert Smalt.DataPlane.Functions.validate_host_json(valid_host_json) == :ok

    sync_conn =
      admin_req(:post, "/admin/host/synctriggers", %{
        "hostJson" => valid_host_json,
        "functions" => [
          %{"name" => "hello", "config" => %{"bindings" => [%{"type" => "httpTrigger"}]}}
        ]
      })

    assert sync_conn.status == @ok
    sync = Jason.decode!(sync_conn.resp_body)
    assert sync["functions"] == ["hello"]
    assert sync["hostJsonValidated"] == true

    # The real GET /admin/functions shape: a JSON array of function records.
    list_conn = admin_req(:get, "/admin/functions")
    assert list_conn.status == @ok

    functions = Jason.decode!(list_conn.resp_body)
    assert is_list(functions)
    hello = Enum.find(functions, &(&1["name"] == "hello"))
    assert hello["status"] == "Created"
    assert hello["function"]["enabled"] == true

    one_conn = admin_req(:get, "/admin/functions/hello")
    assert one_conn.status == @ok
    assert Jason.decode!(one_conn.resp_body)["name"] == "hello"

    assert admin_req(:get, "/admin/functions/ghost").status == @not_found

    # Real GET /admin/host/status shape (state is what health checks parse).
    status_conn = admin_req(:get, "/admin/host/status")
    assert status_conn.status == @ok

    status = Jason.decode!(status_conn.resp_body)
    assert status["state"] == "Running"
    assert is_binary(status["id"])
    assert is_binary(status["version"])
  end

  # -- typed host.json validation --------------------------------------------------

  test "host.json: malformed JSON / unknown top-level extension / version < 2.0 -> typed 400s" do
    assert put_site().status in @create_face

    # Every refused sync ALSO carries a marker function that must NOT get
    # published — the fail-closed witness, order-independent.
    refused_functions = [%{"name" => "refused-marker", "config" => %{}}]

    malformed =
      admin_req(:post, "/admin/host/synctriggers", %{
        "hostJson" => "{ not json",
        "functions" => refused_functions
      })

    assert malformed.status == @bad_request
    body = Jason.decode!(malformed.resp_body)
    assert body["error"]["code"] == "InvalidHostJson"
    assert body["error"]["message"] =~ "host.json"

    unknown =
      admin_req(:post, "/admin/host/synctriggers", %{
        "hostJson" => Jason.encode!(%{"version" => "2.0", "notAnExtension" => %{}}),
        "functions" => refused_functions
      })

    assert unknown.status == @bad_request
    body = Jason.decode!(unknown.resp_body)
    assert body["error"]["code"] == "UnknownHostJsonExtension"
    assert body["error"]["message"] =~ "Unknown extension 'notAnExtension'"

    bad_version =
      admin_req(:post, "/admin/host/synctriggers", %{
        "hostJson" => Jason.encode!(%{"version" => "1.0"}),
        "functions" => refused_functions
      })

    assert bad_version.status == @bad_request
    body = Jason.decode!(bad_version.resp_body)
    assert body["error"]["code"] == "InvalidHostJsonVersion"
    assert body["error"]["message"] =~ "2.0"

    # Fail-closed: the refused marker function was never published.
    functions = Jason.decode!(admin_req(:get, "/admin/functions").resp_body)
    refute "refused-marker" in Enum.map(functions, & &1["name"])
  end

  # -- keys ------------------------------------------------------------------------

  test "admin host keys shape + POST renew + listHostKeys / listFunctionKeys faces" do
    assert put_site().status in @create_face

    keys_conn = admin_req(:get, "/admin/host/keys")
    assert keys_conn.status == @ok

    keys = Jason.decode!(keys_conn.resp_body)
    # Real GET /admin/host/keys shape: masterKey / functionKeys / systemKeys.
    assert is_binary(keys["masterKey"]) and keys["masterKey"] != ""
    assert is_binary(keys["functionKeys"]["default"]) and keys["functionKeys"]["default"] != ""
    assert keys["systemKeys"] == %{}

    renew_conn = admin_req(:post, "/admin/host/keys", %{"name" => "cli-key"})
    assert renew_conn.status == @ok

    renewed = Jason.decode!(renew_conn.resp_body)
    assert renewed["name"] == "cli-key"
    assert is_binary(renewed["value"]) and renewed["value"] != ""

    keys_after = Jason.decode!(admin_req(:get, "/admin/host/keys").resp_body)
    assert keys_after["functionKeys"]["cli-key"] == renewed["value"]

    # ARM listHostKeys face: the same keys under {"properties": ...}.
    host_keys_conn = arm_req(:post, "#{@site_path}/listHostKeys")
    assert host_keys_conn.status == @ok

    host_keys = Jason.decode!(host_keys_conn.resp_body)["properties"]
    assert host_keys["masterKey"] == keys["masterKey"]
    assert host_keys["functionKeys"]["cli-key"] == renewed["value"]

    # listFunctionKeys face: a synced function has its default key; a ghost
    # function is a typed 404, not a fabricated key.
    admin_req(:post, "/admin/host/synctriggers", %{
      "functions" => [%{"name" => "hello", "config" => %{}}]
    })

    fn_keys_conn = arm_req(:post, "#{@site_path}/functions/hello/listFunctionKeys")
    assert fn_keys_conn.status == @ok

    %{"properties" => fn_keys} = Jason.decode!(fn_keys_conn.resp_body)
    assert is_binary(fn_keys["default"]) and fn_keys["default"] != ""

    assert arm_req(:post, "#{@site_path}/functions/ghost/listFunctionKeys").status == @not_found
  end

  # -- honest invocation refusal -----------------------------------------------------

  test "invocation endpoints answer the typed FunctionRuntimeNotEmulated refusal" do
    assert put_site().status in @create_face

    admin_req(:post, "/admin/host/synctriggers", %{"functions" => [%{"name" => "hello"}]})

    invoke_conn = arm_req(:post, "#{@site_path}/functions/hello/invocations")
    assert invoke_conn.status == @bad_request

    body = Jason.decode!(invoke_conn.resp_body)
    assert body["error"]["code"] == "FunctionRuntimeNotEmulated"
    assert body["error"]["message"] =~ "not emulated"

    # The admin-surface invocation face (POST /admin/functions/:name) refuses
    # with the same typed constant — never a fake 200.
    admin_invoke = admin_req(:post, "/admin/functions/hello")
    assert admin_invoke.status == @bad_request

    assert Jason.decode!(admin_invoke.resp_body)["error"]["code"] == "FunctionRuntimeNotEmulated"
  end

  # -- delete ----------------------------------------------------------------------

  test "ARM DELETE -> 200 -> GET 404 (the site row, settings included, is gone)" do
    assert put_site().status in @create_face

    del_conn = arm_req(:delete, @site_path)
    assert del_conn.status == @ok

    assert arm_req(:get, @site_path).status == @not_found
    assert arm_req(:get, "#{@site_path}/config/appSettings").status == @not_found
  end
end
