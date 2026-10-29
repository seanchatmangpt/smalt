# Integration-tier witness (ACR pass-through plug dispatch, integration tier):
# Microsoft.ContainerRegistry control plane + Tasks (wave-r14, T-01 lane).
#
# Chicago discipline: real Store rows (:smalt_resources — the same downcased
# resource-id key convention sb_arm_rules_test seeds), real ACR engine
# (Smalt.DataPlane.Acr), real blob-backed store for the simulated registry
# data-plane metadata (Smalt.DataPlane.BlobStorage), real LRO seam
# (Smalt.ArmGateway.LRO). The plug is dispatched in-process with Plug.Test
# conns — no mocks, no network.
#
#   ARM PUT registry  -> 201 (create) -> re-PUT 200 (idempotent)
#   GET echo / LIST -> listKeys shape (RegistryListCredentialsResult)
#   scheduleRun FileTaskRunRequest -> 201 Queued -> Running -> Succeeded
#   logs answer the recorded synthetic step output (YamlElixir-parsed)
#   EncodedTaskRunRequest (+ values) accepted; typed 400 refusal faces
#   /v2 catalog + tags over blob containers/blobs, docker Basic auth with
#   the credentials/1 seat
#   DELETE registry -> typed 202 LRO that completes; children cascade
#
# Context: solo (integration tier, in-process dispatch).

defmodule Smalt.Internal.AcrTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias Smalt.ArmGateway.LRO
  alias Smalt.DataPlane.Acr
  alias Smalt.DataPlane.BlobStorage
  alias Smalt.Store

  @created 201
  @ok 200
  # Global ETS store persists across tests in this file; every test uses a
  # distinct registry name so first-PUT is always the 201 create face.
  @bad_request 400
  @not_found 404
  @accepted_lro 202
  @unauthorized 401

  @api_version "2023-01-01-preview"
  @rg "/subscriptions/sub-acr/resourceGroups/rg-acr"
  @base "#{@rg}/providers/Microsoft.ContainerRegistry"

  @file_task_yaml """
  version: v1.1.0
  steps:
    - id: build
      build: -t demo:latest .
  """

  @encoded_task_yaml """
  version: v1.1.0
  steps:
    - id: build
      build: -t demo:{{.Values.Tag}} .
    - id: push
      push:
        - demo:{{.Values.Tag}}
  """

  # -- harness -------------------------------------------------------------------

  defp acr_req(method, path, body \\ nil) do
    url = "#{path}?api-version=#{@api_version}"

    conn =
      if body do
        conn(method, url, Jason.encode!(body))
        |> Plug.Conn.put_req_header("content-type", "application/json")
      else
        conn(method, url)
      end

    Smalt.ArmGateway.Providers.AcrRouter.call(Plug.Conn.fetch_query_params(conn), [])
  end

  defp v2_req(method, path, basic_pair \\ nil) do
    conn = conn(method, path)

    conn =
      if basic_pair do
        Plug.Conn.put_req_header(conn, "authorization", "Basic " <> Base.encode64(basic_pair))
      else
        conn
      end

    Smalt.ArmGateway.Providers.AcrRouter.call(Plug.Conn.fetch_query_params(conn), [])
  end

  defp put_registry(reg) do
    acr_req(:put, "#{@base}/registries/#{reg}", %{
      "location" => "eastus",
      "sku" => %{"name" => "Basic"},
      "properties" => %{}
    })
  end

  defp schedule_run(reg, request) do
    acr_req(:post, "#{@base}/registries/#{reg}/scheduleRun", request)
  end

  defp run_status(run_id) do
    conn = acr_req(:get, run_id)
    assert conn.status == @ok
    Jason.decode!(conn.resp_body)["properties"]["status"]
  end

  # The simulated state machine runs on wall-clock thresholds; poll the wire
  # poll face until the run walks through the expected statuses in order.
  defp wait_for_run_status(run_id, target, deadline_ms \\ 8_000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_wait(run_id, target, deadline)
  end

  defp do_wait(run_id, target, deadline) do
    status = run_status(run_id)

    cond do
      status == target ->
        status

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("run never reached #{inspect(target)}; last status #{inspect(status)}")

      true ->
        Process.sleep(50)
        do_wait(run_id, target, deadline)
    end
  end

  defp registry_key(reg),
    do: String.downcase("#{@base}/registries/#{reg}")

  defp registry_cleanup(reg) do
    on_exit(fn ->
      Store.delete(:smalt_resources, registry_key(reg) <> "/runs")
      Store.delete(:smalt_resources, registry_key(reg))

      # Children are downcased resource-id keys under the registry prefix.
      registry_key(reg)
      |> Store.prefix_keys(:smalt_resources, )
      |> Enum.each(&Store.delete(:smalt_resources, &1))

      BlobStorage.drop_account_data(reg)
    end)
  end

  # -- happy path: registries CRUD + listKeys + credentials -----------------------

  test "PUT registry 201 -> idempotent re-PUT 200 -> GET echo -> LIST -> listKeys shape agrees with credentials/1" do
    reg = "regacr01"
    registry_cleanup(reg)

    put_conn = put_registry(reg)
    assert put_conn.status == @created

    created = Jason.decode!(put_conn.resp_body)

    # Key-level shape asserts (census: no whole-map equality).
    assert created["name"] == reg
    assert created["type"] == "Microsoft.ContainerRegistry/registries"
    assert created["id"] == "#{@base}/registries/#{reg}"
    assert created["sku"]["name"] == "Basic"
    assert created["properties"]["provisioningState"] == "Succeeded"
    # DoD: loginServer on the smalt DNS suffix (metadata "containerRegistry").
    assert created["properties"]["loginServer"] == "#{reg}.registry.smalt.local"

    re_put_conn =
      acr_req(:put, "#{@base}/registries/#{reg}", %{
        "location" => "eastus",
        "sku" => %{"name" => "Premium"},
        "properties" => %{}
      })

    assert re_put_conn.status == @ok

    updated = Jason.decode!(re_put_conn.resp_body)
    assert updated["sku"]["name"] == "Premium"
    # Re-PUT preserves the original creationDate (real ACR PUT update semantics).
    assert updated["properties"]["creationDate"] == created["properties"]["creationDate"]

    get_conn = acr_req(:get, "#{@base}/registries/#{reg}")
    assert get_conn.status == @ok

    echoed = Jason.decode!(get_conn.resp_body)
    assert echoed["name"] == reg
    assert echoed["properties"]["provisioningState"] == "Succeeded"

    list_conn = acr_req(:get, "#{@base}/registries")
    assert list_conn.status == @ok

    %{"value" => registries} = Jason.decode!(list_conn.resp_body)
    assert reg in Enum.map(registries, & &1["name"])

    # listKeys (ticket vocabulary) and the real-API listCredentials alias.
    keys_conn = acr_req(:post, "#{@base}/registries/#{reg}/listKeys")
    assert keys_conn.status == @ok

    keys = Jason.decode!(keys_conn.resp_body)
    assert keys["username"] == reg
    assert Enum.map(keys["passwords"], & &1["name"]) == ["password", "password2"]

    alias_conn = acr_req(:post, "#{@base}/registries/#{reg}/listCredentials")
    assert alias_conn.status == @ok

    # credentials/1 is the single source of truth the listed keys agree with.
    assert {:ok, creds} = Acr.credentials(registry_key(reg))
    assert creds.server == "#{reg}.registry.smalt.local"
    assert creds.username == reg
    assert creds.password == hd(keys["passwords"])["value"]
  end

  # -- run lifecycle: FileTaskRunRequest -------------------------------------------

  test "scheduleRun FileTaskRunRequest 201 Queued -> Running -> Succeeded -> logs; logLink seats credentials/1" do
    reg = "regacr02"
    registry_cleanup(reg)
    assert put_registry(reg).status == @created

    run_conn =
      schedule_run(reg, %{
        "type" => "FileTaskRunRequest",
        "taskPath" => "task.yaml",
        "encodedTaskContent" => Base.encode64(@file_task_yaml),
        "timeout" => 300,
        "platform" => %{"os" => "Linux"}
      })

    assert run_conn.status == @created

    run = Jason.decode!(run_conn.resp_body)
    run_id = run["id"]
    assert String.starts_with?(run_id, "#{@base}/registries/#{reg}/runs/")
    assert is_binary(run["properties"]["runId"])
    assert run["properties"]["runType"] == "FileTask"
    assert run["properties"]["status"] == "Queued"

    # credentials/1 seats the run: the logLink lives on the login server.
    assert {:ok, creds} = Acr.credentials(registry_key(reg))
    assert run["properties"]["logLink"] == "https://#{creds.server}/runlogs/#{run["properties"]["runId"]}"

    # The wire render strips smalt-private members (logs never ride the run).
    refute Map.has_key?(run, "logs")
    refute Map.has_key?(run, "_acr_queued_ms")

    # Poll face: the immediate sample is Queued (or already Running on a slow
    # runner); the walk then reaches Running and Succeeded in order.
    first_status = run_status(run_id)
    assert first_status in ["Queued", "Running"]
    wait_for_run_status(run_id, "Running")
    assert wait_for_run_status(run_id, "Succeeded") == "Succeeded"

    # GET run at terminal: lifecycle timestamps filled.
    terminal_conn = acr_req(:get, run_id)
    terminal = Jason.decode!(terminal_conn.resp_body)
    assert terminal["properties"]["startTime"]
    assert terminal["properties"]["finishTime"]

    # Logs answer the run's recorded synthetic output (YamlElixir-parsed step).
    logs_conn = acr_req(:get, "#{run_id}/logs")
    assert logs_conn.status == @ok

    logs = logs_conn.resp_body
    assert logs =~ "Queued run"
    assert logs =~ "Executing step ID: build. -t demo:latest ."
    assert logs =~ "Step ID: build elapsed: 00:00:00 (simulated)"
    assert logs =~ ~r/Run ID: #{run["properties"]["runId"]} was successful after \d+s/

    # LIST runs: the terminal run is listed, still log-free on the wire.
    list_conn = acr_req(:get, "#{@base}/registries/#{reg}/runs")
    assert list_conn.status == @ok

    %{"value" => runs} = Jason.decode!(list_conn.resp_body)
    listed = Enum.find(runs, &(&1["id"] == run_id))
    assert listed["properties"]["status"] == "Succeeded"
    refute Map.has_key?(listed, "logs")
  end

  # -- EncodedTaskRunRequest + typed refusal faces ----------------------------------

  test "EncodedTaskRunRequest values substitution + validation refusals (fail-closed, typed 400/404)" do
    reg = "regacr03"
    registry_cleanup(reg)
    assert put_registry(reg).status == @created

    encoded_conn =
      schedule_run(reg, %{
        "type" => "EncodedTaskRunRequest",
        "encodedTaskContent" => Base.encode64(@encoded_task_yaml),
        "values" => [%{"name" => "Tag", "value" => "1.0"}],
        "platform" => %{"os" => "Linux", "architecture" => "amd64"}
      })

    assert encoded_conn.status == @created
    encoded = Jason.decode!(encoded_conn.resp_body)
    assert encoded["properties"]["runType"] == "EncodedTask"
    assert encoded["properties"]["platform"] == %{"os" => "Linux", "architecture" => "amd64"}

    assert wait_for_run_status(encoded["id"], "Succeeded") == "Succeeded"

    # Values substituted into the recorded step output before parsing.
    logs = acr_req(:get, "#{encoded["id"]}/logs").resp_body
    assert logs =~ "Executing step ID: build. -t demo:1.0 ."
    assert logs =~ "Executing step ID: push. [\"demo:1.0\"]"

    # Unknown task-file fields map verbatim into the recorded run body
    # (smalt-private _acr_task member, readable through the engine face).
    assert {:ok, row} = Acr.get_run(encoded["id"])
    assert row["_acr_task"]["steps"]["steps"] |> is_list()
    assert Enum.map(row["_acr_task"]["steps"]["steps"], & &1["id"]) == ["build", "push"]

    # Bad base64 -> typed 400 InvalidEncodedTaskContent.
    bad_b64_conn =
      schedule_run(reg, %{
        "type" => "EncodedTaskRunRequest",
        "encodedTaskContent" => "!!!not-base64!!!"
      })

    assert bad_b64_conn.status == @bad_request
    assert Jason.decode!(bad_b64_conn.resp_body)["error"]["code"] == "InvalidEncodedTaskContent"

    # Unsupported run request type -> typed 400 (no container execution).
    unsupported_conn =
      schedule_run(reg, %{"type" => "DockerBuildRequest", "dockerFilePath" => "Dockerfile"})

    assert unsupported_conn.status == @bad_request
    assert Jason.decode!(unsupported_conn.resp_body)["error"]["code"] == "UnsupportedRunRequestType"

    # Missing required member -> typed 400 ValidationError.
    missing_conn = schedule_run(reg, %{"type" => "FileTaskRunRequest"})
    assert missing_conn.status == @bad_request
    assert Jason.decode!(missing_conn.resp_body)["error"]["code"] == "ValidationError"

    # Task YAML that YamlElixir cannot parse -> typed 400 InvalidTaskContent.
    bad_yaml_conn =
      schedule_run(reg, %{
        "type" => "EncodedTaskRunRequest",
        "encodedTaskContent" => Base.encode64("steps: [unclosed")
      })

    assert bad_yaml_conn.status == @bad_request
    assert Jason.decode!(bad_yaml_conn.resp_body)["error"]["code"] == "InvalidTaskContent"

    # Unknown registry seat -> typed 404 RegistryNotFound.
    ghost_conn = schedule_run("reg-ghost-acr", %{"type" => "EncodedTaskRunRequest", "encodedTaskContent" => Base.encode64(@encoded_task_yaml)})
    assert ghost_conn.status == @not_found
    assert Jason.decode!(ghost_conn.resp_body)["error"]["code"] == "RegistryNotFound"
  end

  # -- webhooks ---------------------------------------------------------------------

  test "webhooks: PUT 201 -> GET echo -> LIST -> DELETE -> 404; parent existence gated" do
    reg = "regacr04"
    registry_cleanup(reg)
    assert put_registry(reg).status == @created

    put_conn =
      acr_req(:put, "#{@base}/registries/#{reg}/webhooks/hook-acr", %{
        "location" => "eastus",
        "properties" => %{"actions" => ["push"], "scope" => "demo/*", "status" => "enabled"}
      })

    assert put_conn.status == @created

    hook = Jason.decode!(put_conn.resp_body)
    assert hook["name"] == "hook-acr"
    assert hook["type"] == "Microsoft.ContainerRegistry/registries/webhooks"
    assert hook["id"] == "#{@base}/registries/#{reg}/webhooks/hook-acr"
    assert hook["properties"]["actions"] == ["push"]
    assert hook["properties"]["scope"] == "demo/*"
    assert hook["properties"]["provisioningState"] == "Succeeded"

    # Idempotent re-put 200 with replaced properties.
    re_put_conn =
      acr_req(:put, "#{@base}/registries/#{reg}/webhooks/hook-acr", %{
        "location" => "eastus",
        "properties" => %{}
      })

    assert re_put_conn.status == @ok
    assert Jason.decode!(re_put_conn.resp_body)["properties"]["actions"] == ["push", "delete"]

    get_conn = acr_req(:get, "#{@base}/registries/#{reg}/webhooks/hook-acr")
    assert get_conn.status == @ok
    assert Jason.decode!(get_conn.resp_body)["name"] == "hook-acr"

    list_conn = acr_req(:get, "#{@base}/registries/#{reg}/webhooks")
    assert list_conn.status == @ok
    %{"value" => hooks} = Jason.decode!(list_conn.resp_body)
    assert Enum.map(hooks, & &1["name"]) == ["hook-acr"]

    del_conn = acr_req(:delete, "#{@base}/registries/#{reg}/webhooks/hook-acr")
    assert del_conn.status == @ok
    assert acr_req(:get, "#{@base}/registries/#{reg}/webhooks/hook-acr").status == @not_found

    # Webhook against a missing registry -> typed 404.
    ghost =
      acr_req(:put, "#{@base}/registries/reg-ghost-acr/webhooks/hook-ghost", %{"properties" => %{}})

    assert ghost.status == @not_found
  end

  # -- data-plane metadata over the blob-backed store ---------------------------------

  test "/v2 catalog + tags answer the blob-backed store under docker Basic auth with the listed keys" do
    reg = "regacr05"
    registry_cleanup(reg)
    assert put_registry(reg).status == @created

    # Real blob-backed store rows: repositories = containers of the
    # registry-named account, tags = blob names.
    assert {:ok, _} = BlobStorage.create_container(reg, "demo")
    assert {:ok, _} = BlobStorage.put_blob(reg, "demo", "1.0", "{}")
    assert {:ok, _} = BlobStorage.put_blob(reg, "demo", "latest", "{}")

    catalog_path = "/acr/#{reg}/v2/_catalog"
    tags_path = "/acr/#{reg}/v2/demo/tags/list"

    # No credentials -> docker Basic challenge (401 UNAUTHORIZED).
    anon = v2_req(:get, catalog_path)
    assert anon.status == @unauthorized
    assert Jason.decode!(anon.resp_body)["errors"] |> hd() |> Map.get("code") == "UNAUTHORIZED"
    assert Plug.Conn.get_req_header(anon, "www-authenticate") == [~s(Basic realm="#{reg}.registry.smalt.local")]

    # Wrong password -> still 401.
    assert v2_req(:get, catalog_path, "#{reg}:wrong").status == @unauthorized

    # The credentials/1 seat (what listKeys lists) is what authenticates.
    assert {:ok, creds} = Acr.credentials(registry_key(reg))

    catalog = v2_req(:get, catalog_path, "#{creds.username}:#{creds.password}")
    assert catalog.status == @ok
    assert Jason.decode!(catalog.resp_body) == %{"repositories" => ["demo"]}

    tags = v2_req(:get, tags_path, "#{creds.username}:#{creds.password}")
    assert tags.status == @ok
    assert Jason.decode!(tags.resp_body) == %{"name" => "demo", "tags" => ["1.0", "latest"]}

    # Unknown registry seat -> docker 404 NAME_UNKNOWN.
    unknown = v2_req(:get, "/acr/reg-ghost-acr/v2/_catalog")
    assert unknown.status == @not_found
    assert Jason.decode!(unknown.resp_body)["errors"] |> hd() |> Map.get("code") == "NAME_UNKNOWN"
  end

  # -- delete: typed 202 LRO that completes + cascade ---------------------------------

  test "DELETE registry -> typed 202 LRO completing Succeeded; children cascade; credentials/1 goes :error" do
    reg = "regacr06"
    registry_cleanup(reg)
    assert put_registry(reg).status == @created

    run_conn =
      schedule_run(reg, %{
        "type" => "EncodedTaskRunRequest",
        "encodedTaskContent" => Base.encode64(@encoded_task_yaml)
      })

    assert run_conn.status == @created
    run_id = Jason.decode!(run_conn.resp_body)["id"]

    del_conn = acr_req(:delete, "#{@base}/registries/#{reg}")
    assert del_conn.status == @accepted_lro

    # Typed LRO faces: Azure-AsyncOperation/Location headers + op record body.
    assert Plug.Conn.get_req_header(del_conn, "azure-asyncoperation") != []
    assert Plug.Conn.get_req_header(del_conn, "location") != []

    op = Jason.decode!(del_conn.resp_body)
    assert op["status"] == "InProgress"
    assert is_binary(op["name"])

    # The real LRO seam completes the operation (delay 0 -> terminal on poll).
    assert {:ok, terminal} = LRO.get_op(op["name"])
    assert terminal["status"] == "Succeeded"

    # The delete is applied: registry gone, credentials dry, runs cascaded.
    assert acr_req(:get, "#{@base}/registries/#{reg}").status == @not_found
    assert acr_req(:post, "#{@base}/registries/#{reg}/listKeys").status == @not_found
    assert Acr.credentials(registry_key(reg)) == :error
    assert Acr.get_run(run_id) == :error

    refute Enum.any?(Acr.list_runs(), fn row ->
             String.downcase(row["id"]) |> String.starts_with?(registry_key(reg) <> "/runs/")
           end)

    %{"value" => runs_after} = Jason.decode!(acr_req(:get, "#{@base}/registries/#{reg}/runs").resp_body)
    assert runs_after == []

    # Unknown-registry delete -> typed 404 (no async face minted).
    assert acr_req(:delete, "#{@base}/registries/reg-ghost-acr").status == @not_found
  end
end
