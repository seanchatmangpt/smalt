# Integration-tier witness: ARM containerGroups control plane (T-10, wave v26.10.28 r17).
#
# Chicago discipline: real Store rows (:smalt_resources), real in-process
# dispatch through the pass-through plug
# Smalt.ArmGateway.Providers.ContainerGroupsRouter (the exact composition the
# integrator mounts before :match in Smalt.ArmGateway.Router — the court
# dispatches the plug directly since the wiring line is the integrator's),
# real LRO store (:smalt_operations). No mocks. Container EXECUTION is
# out-of-scope by design law: the court witnesses the honest faces
# (simulated Succeeded/Running lifecycle, typed logs refusal), never a fake
# runtime.
#
#   PUT valid group  -> 201 -> re-PUT 200 -> GET shape
#     (provisioningState Succeeded, instanceView Running, echoed IP/port,
#      credentials echoed WITHOUT the secret)
#   PUT unknown registry credential -> 400 InaccessibleImageRegistry (nothing
#     stored); seeded ACR row -> same body admits
#   LIST paginates (value, deterministic order, $skip window, no fabricated
#     nextLink; RG scope + subscription scope)
#   DELETE -> LRO 202 (Location + Retry-After) -> op completes Succeeded ->
#     GET 404 -> DELETE unknown 404
#   logs action -> typed NotSupportedOnSubstrate refusal (never a fabricated
#     stream); unknown container is an honest 404
#   schema refusals typed 400 (containers/image/port/probe) + api-version gate
#   non-containerGroups shapes return the conn UNCHANGED (pass-through law)
#
# Context: solo (integration tier, in-process dispatch).

defmodule Smalt.Internal.ContainerGroupsTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias Smalt.ArmGateway.Providers.ContainerGroupsRouter
  alias Smalt.DataPlane.ContainerGroups
  alias Smalt.Store

  @created 201
  @ok 200
  @bad_request 400
  @not_found 404
  @api_version "2023-05-01"

  @sub "sub-ci"
  @rg "rg-ci"
  @group "group-ci"
  @container "web"

  @base "/subscriptions/#{@sub}/resourceGroups/#{@rg}/providers/Microsoft.ContainerInstance/containerGroups"
  @group_path "#{@base}/#{@group}"
  @registry "reg-ci"
  @registry_server "#{@registry}.azurecr.io"
  @registry_key String.downcase(
                  "/subscriptions/#{@sub}/resourceGroups/#{@rg}/providers/Microsoft.ContainerRegistry/registries/#{@registry}"
                )

  setup do
    # The ACR control-plane row the court's imageRegistryCredentials resolve
    # against (T-01 seam: registries are generic admitted-type rows in
    # :smalt_resources, keyed .../providers/Microsoft.ContainerRegistry/
    # registries/<name>, downcased providers segment included).
    Store.put(:smalt_resources, @registry_key, %{
      "id" =>
        "/subscriptions/#{@sub}/resourceGroups/#{@rg}/providers/Microsoft.ContainerRegistry/registries/#{@registry}",
      "name" => @registry,
      "type" => "Microsoft.ContainerRegistry/registries",
      "location" => "eastus",
      "properties" => %{}
    })

    on_exit(fn ->
      for name <- [@group, "group-list", "group-list2"] do
        Store.delete(:smalt_resources, String.downcase("#{@base}/#{name}"))
      end

      Store.delete(:smalt_resources, @registry_key)
    end)

    :ok
  end

  # -- happy path: PUT -> idempotent re-PUT -> GET lifecycle shape ---------------

  test "PUT valid group 201 -> re-PUT 200 -> GET renders Succeeded + instanceView Running + echoed shape" do
    put_conn = ci_req(:put, @group_path, group_body())

    assert put_conn.status == @created

    created = Jason.decode!(put_conn.resp_body)

    # Key-level shape asserts (census: no whole-map equality).
    assert created["name"] == @group
    assert created["type"] == "Microsoft.ContainerInstance/containerGroups"
    assert created["id"] == @group_path
    assert created["location"] == "eastus"
    assert created["properties"]["provisioningState"] == "Succeeded"
    assert created["properties"]["instanceView"]["state"] == "Running"

    # The idempotent re-PUT is the 200 face (ARM create-or-replace law).
    assert ci_req(:put, @group_path, group_body()).status == @ok

    # Segment casing is matched case-insensitively (the mux normalizes nothing
    # for this plug — the plug carries its own case law).
    mixed =
      "/subscriptions/#{@sub}/ResourceGroups/#{@rg}/providers/MICROSOFT.CONTAINERINSTANCE/containergroups/#{@group}"

    assert ci_req(:put, mixed, group_body()).status == @ok

    get_conn = ci_req(:get, @group_path)
    assert get_conn.status == @ok

    group = Jason.decode!(get_conn.resp_body)

    assert group["properties"]["provisioningState"] == "Succeeded"
    assert group["properties"]["instanceView"]["state"] == "Running"

    # Simulated control-plane-only lifecycle: every container Running from
    # the recorded start — the honest face, never a fabricated execution.
    [status] = group["properties"]["instanceView"]["containers"]
    assert status["name"] == @container
    assert status["containerStatus"]["currentState"]["state"] == "Running"
    assert is_binary(status["containerStatus"]["currentState"]["startTime"])

    # The developer's IP/port shape echoes; the substrate IP is synthesized.
    ip = group["properties"]["ipAddress"]
    assert ip["type"] == "Public"
    assert ip["ports"] == [%{"port" => 80, "protocol" => "TCP"}]
    assert Regex.match?(~r/^10\.96\.\d+\.\d+$/, ip["ip"])

    # Container schema round-trips (image, resources, ports, probe).
    [c] = group["properties"]["containers"]
    assert c["name"] == @container
    assert c["properties"]["image"] == "nginx:latest"
    assert c["properties"]["resources"]["requests"]["cpu"] == 1.0
    assert c["properties"]["resources"]["requests"]["memoryInGB"] == 1.5
    assert c["properties"]["ports"] == [%{"port" => 80, "protocol" => "TCP"}]
    assert c["properties"]["livenessProbe"]["httpGet"]["path"] == "/healthz"

    # Credentials echo server + username, NEVER the secret.
    [cred] = group["properties"]["imageRegistryCredentials"]
    assert cred["server"] == @registry_server
    assert cred["username"] == "acr-admin"
    refute Map.has_key?(cred, "password")
  end

  # -- registry credential validation at PUT time (T-01 seam) --------------------

  test "PUT with an unknown registry credential refuses 400 InaccessibleImageRegistry; a seeded ACR row admits" do
    body =
      put_in(group_body(), ["properties", "imageRegistryCredentials"], [
        %{"server" => "nosuchreg.azurecr.io", "username" => "u", "password" => "p"}
      ])

    put_conn = ci_req(:put, @group_path, body)
    assert put_conn.status == @bad_request

    err = Jason.decode!(put_conn.resp_body)["error"]
    assert err["code"] == "InaccessibleImageRegistry"
    assert err["target"] == "properties.imageRegistryCredentials[0]"
    assert err["message"] =~ "nosuchreg"

    # Nothing stored for the refused group (fail-closed validation).
    assert ci_req(:get, @group_path).status == @not_found

    # Seed the real ACR control-plane row (T-01 seam, store-keyed
    # .../providers/Microsoft.ContainerRegistry/registries/<name>) — the SAME
    # body now admits, proving the validation reads the real store.
    Store.put(:smalt_resources, @registry_key, %{
      "id" =>
        "/subscriptions/#{@sub}/resourceGroups/#{@rg}/providers/Microsoft.ContainerRegistry/registries/#{@registry}",
      "name" => @registry,
      "type" => "Microsoft.ContainerRegistry/registries",
      "location" => "eastus",
      "properties" => %{}
    })

    assert ci_req(:put, @group_path, body).status == @created
  end

  # -- LIST pagination ------------------------------------------------------------

  test "LIST paginates: value in deterministic order, $skip window, no fabricated nextLink" do
    assert ci_req(:put, "#{@base}/group-list", group_body()).status == @created
    assert ci_req(:put, "#{@base}/group-list2", group_body()).status == @created

    list_conn = ci_req(:get, @base)
    assert list_conn.status == @ok

    %{"value" => value} = Jason.decode!(list_conn.resp_body)
    names = Enum.map(value, & &1["name"])
    assert "group-list" in names
    assert "group-list2" in names

    # A complete page carries NO nextLink (never a fabricated continuation).
    refute Map.has_key?(Jason.decode!(list_conn.resp_body), "nextLink")

    # The $skip window drops the first record (store-key order is the wire
    # order: downcased .../containergroups/group-list sorts before group-list2).
    skip_conn = ci_req(:get, "#{@base}?$skip=1")
    assert skip_conn.status == @ok

    %{"value" => skipped} = Jason.decode!(skip_conn.resp_body)
    assert Enum.map(skipped, & &1["name"]) == ["group-list2"]

    # Subscription scope (`az container list` without -g) surfaces the groups.
    sub_conn = ci_req(:get, "/subscriptions/#{@sub}/providers/Microsoft.ContainerInstance/containerGroups")
    assert sub_conn.status == @ok

    %{"value" => sub_value} = Jason.decode!(sub_conn.resp_body)
    sub_names = Enum.map(sub_value, & &1["name"])
    assert "group-list" in sub_names
    assert "group-list2" in sub_names
  end

  # -- DELETE LRO -----------------------------------------------------------------

  test "DELETE answers LRO 202 (Location + Retry-After), the op completes, GET then 404, unknown DELETE 404" do
    assert ci_req(:put, @group_path, group_body()).status == @created

    del_conn = ci_req(:delete, @group_path)
    assert del_conn.status == 202

    assert [location] = Plug.Conn.get_resp_header(del_conn, "location")
    assert location =~ "/operations/"
    assert Plug.Conn.get_resp_header(del_conn, "retry-after") == ["1"]

    # The LRO completes: the deleted group's operation reaches Succeeded on
    # the first poll (Sweeper-owned or view-only terminal — same wire state).
    op_id = location |> String.split("/") |> List.last()
    assert {:ok, op} = Smalt.ArmGateway.LRO.get_op(op_id)
    assert op["status"] == "Succeeded"
    assert op["resourceId"] == @group_path

    get_conn = ci_req(:get, @group_path)
    assert get_conn.status == @not_found

    missing = Jason.decode!(get_conn.resp_body)["error"]
    assert missing["code"] == "ResourceNotFound"

    del_again = ci_req(:delete, @group_path)
    assert del_again.status == @not_found
    assert Jason.decode!(del_again.resp_body)["error"]["code"] == "ResourceNotFound"
  end

  # -- logs: the typed, honest refusal ---------------------------------------------

  test "logs action answers the typed NotSupportedOnSubstrate refusal (never a fabricated stream)" do
    assert ci_req(:put, @group_path, group_body()).status == @created

    logs_conn = ci_req(:get, "#{@group_path}/containers/#{@container}/logs")
    assert logs_conn.status == @bad_request

    err = Jason.decode!(logs_conn.resp_body)["error"]
    assert err["code"] == "NotSupportedOnSubstrate"
    assert err["code"] == ContainerGroups.logs_refusal_code()
    assert err["target"] == "containers/#{@container}/logs"
    assert err["message"] =~ "not emulated"
    assert err["message"] =~ "never fabricated"

    # No log-content member is ever present — the refusal is the whole answer.
    refute logs_conn.resp_body =~ "\"content\""

    # An unknown container is an honest 404, not a refusal-shaped guess.
    nope = ci_req(:get, "#{@group_path}/containers/nope/logs")
    assert nope.status == @not_found
    assert Jason.decode!(nope.resp_body)["error"]["code"] == "ResourceNotFound"
  end

  # -- schema validation: typed refusals at PUT time ---------------------------------

  test "PUT validates the real schema (containers/image/port/probe) and the api-version gate" do
    # No containers.
    conn = ci_req(:put, @group_path, put_in(group_body(), ["properties", "containers"], []))
    assert conn.status == @bad_request

    err = Jason.decode!(conn.resp_body)["error"]
    assert err["code"] == "InvalidParameter"
    assert err["target"] == "properties.containers"

    # No image.
    imageless = %{
      "location" => "eastus",
      "properties" => %{
        "containers" => [
          %{
            "name" => @container,
            "properties" => %{
              "resources" => %{"requests" => %{"cpu" => 1, "memoryInGB" => 1.5}}
            }
          }
        ]
      }
    }

    conn = ci_req(:put, @group_path, imageless)
    assert conn.status == @bad_request
    assert Jason.decode!(conn.resp_body)["error"]["target"] == "properties.containers[0].properties.image"

    # Port 0 is not a port.
    bad_port = %{
      "location" => "eastus",
      "properties" => %{
        "containers" => [
          %{
            "name" => @container,
            "properties" => %{
              "image" => "nginx:latest",
              "resources" => %{"requests" => %{"cpu" => 1, "memoryInGB" => 1.5}},
              "ports" => [%{"port" => 0}]
            }
          }
        ]
      }
    }

    conn = ci_req(:put, @group_path, bad_port)
    assert conn.status == @bad_request

    assert Jason.decode!(conn.resp_body)["error"]["target"] ==
             "properties.containers[0].properties.ports[0]"

    # Probe without a handler (no exec/httpGet/tcpSocket).
    handlerless = %{
      "location" => "eastus",
      "properties" => %{
        "containers" => [
          %{
            "name" => @container,
            "properties" => %{
              "image" => "nginx:latest",
              "resources" => %{"requests" => %{"cpu" => 1, "memoryInGB" => 1.5}},
              "livenessProbe" => %{"periodSeconds" => 10}
            }
          }
        ]
      }
    }

    conn = ci_req(:put, @group_path, handlerless)
    assert conn.status == @bad_request

    assert Jason.decode!(conn.resp_body)["error"]["target"] ==
             "properties.containers[0].properties.livenessProbe"

    # api-version gate: missing -> MissingApiVersionParameter.
    raw =
      conn(:put, @group_path, Jason.encode!(group_body()))
      |> Plug.Conn.put_req_header("content-type", "application/json")

    no_av = ContainerGroupsRouter.call(Plug.Conn.fetch_query_params(raw), [])

    assert no_av.status == @bad_request
    assert Jason.decode!(no_av.resp_body)["error"]["code"] == "MissingApiVersionParameter"
  end

  # -- pass-through law ----------------------------------------------------------------

  test "non-containerGroups shapes return the conn unchanged; unsupported methods are typed 405" do
    foreign =
      "/subscriptions/sub-x/resourceGroups/rg-x/providers/Microsoft.ServiceBus/namespaces/ns-x"

    untouched = Plug.Conn.fetch_query_params(conn(:get, foreign))
    assert ContainerGroupsRouter.call(untouched, []) == untouched

    root_only =
      "/subscriptions/sub-x/resourceGroups/rg-x/providers/Microsoft.ServiceBus/namespaces"

    untouched2 = Plug.Conn.fetch_query_params(conn(:get, root_only))
    assert ContainerGroupsRouter.call(untouched2, []) == untouched2

    # Owned shapes answer unsupported methods themselves (never fall through).
    post_conn = ci_req(:post, @group_path, group_body())
    assert post_conn.status == 405
    assert Jason.decode!(post_conn.resp_body)["error"]["code"] == "MethodNotAllowed"
  end

  # -- helpers ---------------------------------------------------------------------------

  defp ci_req(method, path, body \\ nil) do
    url =
      if String.contains?(path, "?"),
        do: "#{path}&api-version=#{@api_version}",
        else: "#{path}?api-version=#{@api_version}"

    conn =
      if body do
        conn(method, url, Jason.encode!(body))
        |> Plug.Conn.put_req_header("content-type", "application/json")
      else
        conn(method, url)
      end

    ContainerGroupsRouter.call(Plug.Conn.fetch_query_params(conn), [])
  end

  defp group_body do
    %{
      "location" => "eastus",
      "tags" => %{"lane" => "t10"},
      "properties" => %{
        "osType" => "Linux",
        "restartPolicy" => "Always",
        "ipAddress" => %{
          "type" => "Public",
          "ports" => [%{"port" => 80, "protocol" => "TCP"}]
        },
        "imageRegistryCredentials" => [
          %{"server" => @registry_server, "username" => "acr-admin", "password" => "acr-key"}
        ],
        "containers" => [
          %{
            "name" => @container,
            "properties" => %{
              "image" => "nginx:latest",
              "resources" => %{"requests" => %{"cpu" => 1.0, "memoryInGB" => 1.5}},
              "ports" => [%{"port" => 80, "protocol" => "TCP"}],
              "environmentVariables" => [%{"name" => "LANE", "value" => "t10"}],
              "livenessProbe" => %{
                "httpGet" => %{"path" => "/healthz", "port" => 80, "scheme" => "http"},
                "initialDelaySeconds" => 5,
                "periodSeconds" => 10
              }
            }
          }
        ]
      }
    }
  end
end
