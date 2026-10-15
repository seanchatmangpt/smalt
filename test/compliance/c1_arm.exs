defmodule Smalt.Compliance.C1ArmTest do
  @moduledoc """
  C1 — Azure ARM protocol compliance fence (live wire tier).

  Boots `Smalt.ArmGateway.Router` under Bandit on an ephemeral port per test
  and makes real HTTP requests (inets `:httpc`). Fences the CONFORMANT rows of
  `docs/compliance/C1_ARM_REST.md`; known GAP rows are pinned as currently
  absent so a silent fill without an md update also fails.

  Spec basis: ARM REST API contract (azure/azure-rest-api-specs guidance:
  async operations, error response, api-version semantics, list envelopes,
  status-code semantics).
  """

  use ExUnit.Case, async: false

  alias Smalt.Store

  @sub "00000000-0000-0000-0000-000000000000"

  setup context do
    ensure_store()
    Store.clear()

    Store.put(:smalt_subscriptions, @sub, %{
      "id" => "/subscriptions/#{@sub}",
      "subscriptionId" => @sub,
      "displayName" => "Sovereign Smalt Subscription",
      "state" => "Enabled"
    })

    prev_auth = Application.get_env(:smalt, :auth_mode)
    Application.put_env(:smalt, :auth_mode, :anonymous)
    Application.put_env(:smalt, :lro_delay_ms, 0)

    port = free_port()
    {:ok, server} = Bandit.start_link(plug: Smalt.ArmGateway.Router, port: port)

    on_exit(fn ->
      Process.exit(server, :shutdown)
      Application.put_env(:smalt, :auth_mode, prev_auth || :anonymous)
    end)

    {:ok, port: port, test_name: context.test}
  end

  # -- probe helpers: real socket via inets :httpc -----------------------------

  defp req(port, method, path, opts) do
    url = to_charlist("http://127.0.0.1:#{port}#{path}")

    headers =
      opts
      |> Keyword.get(:headers, [])
      |> Enum.map(fn {k, v} -> {to_charlist(k), to_charlist(v)} end)

    body_opt = Keyword.get(opts, :body)

    request =
      if body_opt do
        {url, headers, ~c"application/json", body_opt}
      else
        {url, headers}
      end

    http_options = [timeout: 5_000, connect_timeout: 5_000, autoredirect: false]
    :httpc.request(method, request, http_options, body_format: :binary)
  end

  defp parse({:ok, {{_http_version, status, _reason}, resp_headers, body}}) do
    headers =
      Map.new(resp_headers, fn {k, v} -> {String.downcase(to_string(k)), to_string(v)} end)

    {status, headers, to_string(body)}
  end

  defp json(body), do: Jason.decode!(body)

  defp get!(port, path, opts \\ []), do: parse(req(port, :get, path, opts))

  defp put!(port, path, opts \\ []) do
    opts2 = Keyword.put_new(opts, :body, "{}")
    parse(req(port, :put, path, opts2))
  end

  # ===========================================================================
  # (1) ARM error model — error.code / error.message / target / details
  # ===========================================================================

  test "error envelope carries error.code and error.message with json; charset=utf-8", %{
    port: port
  } do
    {status, headers, body} = get!(port, "/subscriptions/#{@sub}/resourceGroups/rg1")

    assert status == 404
    assert headers["content-type"] == "application/json; charset=utf-8"

    err = json(body)["error"]
    assert err["code"] == "ResourceGroupNotFound"
    assert is_binary(err["message"]) and err["message"] != ""
  end

  test "GraphLaw refusal error envelope carries code, message and target", %{port: port} do
    path =
      "/subscriptions/#{@sub}/resourceGroups/rg1/providers/Microsoft.Nonsense/nonAdmitted/res1" <>
        "?api-version=2021-04-01"

    {status, _h, resp} = put!(port, path, body: Jason.encode!(%{"location" => "eastus"}))

    assert status == 400
    err = json(resp)["error"]
    assert err["code"] == "InvalidResourceShape"
    assert is_binary(err["message"])
    assert err["target"] == "AshGraphLaw.Enforcement"
  end

  test "catch-all route returns ARM RouteNotFound envelope", %{port: port} do
    {404, _h, body} = get!(port, "/definitely/not/a/route?api-version=2021-04-01")
    assert json(body)["error"]["code"] == "RouteNotFound"
  end

  # ===========================================================================
  # (2) Success envelope: id/name/type/location/properties.provisioningState
  # ===========================================================================

  test "resource envelope has id, name, type, location, properties.provisioningState", %{
    port: port
  } do
    name = "stc1" <> unique()
    {status, _h, _body} = put!(port, resource_path(name), body: sa_body(name))
    # storageAccounts is an LRO type on this gateway: the PUT is admitted with
    # 202 and the record is still persisted for GET.
    assert status == 202

    {200, _h, body} = get!(port, resource_path(name))

    res = json(body)

    assert res["id"] ==
             "/subscriptions/#{@sub}/resourceGroups/rg1/providers/Microsoft.Storage/storageAccounts/#{name}"

    assert res["name"] == name
    assert res["type"] == "Microsoft.Storage/storageAccounts"
    assert res["location"] == "eastus"
    assert res["properties"]["provisioningState"] == "Succeeded"

    {200, _h, body2} = get!(port, resource_path(name))
    assert json(body2)["id"] == res["id"]
  end

  defp disks_path(name) do
    "/subscriptions/#{@sub}/resourceGroups/rg1/providers/Microsoft.Compute/disks/#{name}" <>
      "?api-version=#{api_v("Microsoft.Compute/disks")}"
  end

  # ===========================================================================
  # (3) 201/200 semantics on PUT
  # ===========================================================================

  test "PUT create returns 201, PUT update returns 200 (non-LRO type: Microsoft.Compute/disks)",
       %{port: port} do
    path = disks_path("diskc1" <> unique())
    body = Jason.encode!(%{"location" => "eastus"})

    {201, _h, _} = put!(port, path, body: body)
    {200, _h, resp} = put!(port, path, body: body)

    assert json(resp)["type"] == "Microsoft.Compute/disks"
  end

  test "resource group PUT create 201 / update 200, GET 200, DELETE 200, GET 404", %{port: port} do
    rg = "rg-c1-" <> unique()
    path = "/subscriptions/#{@sub}/resourceGroups/#{rg}"

    {201, _h, _} = put!(port, path, body: Jason.encode!(%{"location" => "westus"}))
    {200, _h, _} = put!(port, path, body: Jason.encode!(%{"location" => "westus"}))

    {200, _h, body} = get!(port, path)
    assert json(body)["properties"]["provisioningState"] == "Succeeded"

    {200, _h, _} = delete!(port, path)
    {404, _h, del_body} = get!(port, path)
    assert json(del_body)["error"]["code"] == "ResourceGroupNotFound"
  end

  # ===========================================================================
  # (4) LRO: 202 + Azure-AsyncOperation + Location + Retry-After, poll to 200
  # ===========================================================================

  test "LRO PUT returns 202 with async headers and InProgress body", %{port: port} do
    name = "stc1" <> unique()

    {202, headers, body} = put!(port, resource_path(name), body: sa_body(name))

    assert is_binary(headers["azure-asyncoperation"])
    assert is_binary(headers["location"])
    assert headers["retry-after"] == "1"

    assert json(body)["status"] == "InProgress"
    assert String.contains?(headers["azure-asyncoperation"], "/operations/")
  end

  test "LRO polling: 202 InProgress then terminal 200 {status: Succeeded}", %{port: port} do
    name = "stc1" <> unique()

    {202, headers, _body} = put!(port, resource_path(name), body: sa_body(name))

    {final_status, final_body} = poll_until_terminal(port, headers["azure-asyncoperation"])
    assert final_status == 200
    assert final_body["status"] == "Succeeded"
    assert is_binary(final_body["id"])
  end

  # ===========================================================================
  # (5) api-version handling
  # ===========================================================================

  test "missing api-version -> 400 MissingApiVersionParameter", %{port: port} do
    {400, _h, body} =
      get!(
        port,
        "/subscriptions/#{@sub}/resourceGroups/rg1/providers/Microsoft.Storage/storageAccounts/stc1x"
      )

    assert json(body)["error"]["code"] == "MissingApiVersionParameter"
  end

  test "invalid api-version on admitted type (PUT) -> 400 InvalidApiVersionParameter", %{
    port: port
  } do
    {400, _h, body} = put!(port, resource_path("stc1x", "1999-01-01"))
    assert json(body)["error"]["code"] == "InvalidApiVersionParameter"
  end

  # ===========================================================================
  # (6) Case-insensitivity: resourcegroups segment + provider namespace
  # ===========================================================================

  test "resourcegroups and resourceGroups spellings both resolve", %{port: port} do
    rg = "rg-c1-" <> unique()

    {201, _h, _} =
      put!(port, "/subscriptions/#{@sub}/resourceGroups/#{rg}",
        body: Jason.encode!(%{"location" => "eastus"})
      )

    {200, _h, _} = get!(port, "/subscriptions/#{@sub}/resourcegroups/#{rg}")

    {200, _h, list_body} = get!(port, "/subscriptions/#{@sub}/resourcegroups")
    assert is_list(json(list_body)["value"])
  end

  test "lowercase provider namespace resolves to the same record", %{port: port} do
    name = "stc1" <> unique()

    {202, _h, _} = put!(port, resource_path(name), body: sa_body(name))

    lower =
      "/subscriptions/#{@sub}/resourceGroups/rg1/providers/microsoft.storage/storageAccounts/#{name}" <>
        "?api-version=#{api_v("Microsoft.Storage/storageAccounts")}"

    {200, _h, body} = get!(port, lower)
    assert json(body)["type"] == "Microsoft.Storage/storageAccounts"
  end

  # ===========================================================================
  # (7) LIST envelope {"value": [...]}
  # ===========================================================================

  test "provider-type LIST returns the value envelope containing created resources", %{port: port} do
    name = "stc1" <> unique()

    {202, _h, _} = put!(port, resource_path(name), body: sa_body(name))

    {200, _h, body} =
      get!(
        port,
        "/subscriptions/#{@sub}/resourceGroups/rg1/providers/Microsoft.Storage/storageAccounts?api-version=#{api_v("Microsoft.Storage/storageAccounts")}"
      )

    list = json(body)
    assert Map.has_key?(list, "value") and is_list(list["value"])
    assert Enum.any?(list["value"], fn r -> r["name"] == name end)
  end

  # ===========================================================================
  # (8) Fixed GAP rows — CONFORMANT assertions (rows 1c, 2b, 9, 11, 12)
  # ===========================================================================

  test "every response echoes x-ms-request-id (echoes client-supplied value)", %{port: port} do
    {s1, headers, _b} = get!(port, "/subscriptions/#{@sub}/resourceGroups/rg1")

    assert s1 == 404
    assert is_binary(headers["x-ms-request-id"]) and byte_size(headers["x-ms-request-id"]) == 36

    # client-supplied request id is echoed verbatim
    {s2, headers2, _b2} =
      parse(
        req(port, :get, "/subscriptions/#{@sub}/resourceGroups/rg1",
          headers: [{"x-ms-request-id", "my-client-request-id-123"}]
        )
      )

    assert s2 == 404
    assert headers2["x-ms-request-id"] == "my-client-request-id-123"
  end

  test "429 + Retry-After when :smalt, :arm_rate_limit is configured; default emits none", %{
    port: port
  } do
    name = "stc1" <> unique()
    path = resource_path(name)

    # Default: :infinity — byte-identical, zero 429s over 60 rapid PUTs.
    statuses =
      for _ <- 1..60 do
        {status, _h, _b} = put!(port, path, body: sa_body(name))
        status
      end

    refute 429 in statuses

    # Configured: fixed-window 429 + Retry-After once the limit is exceeded.
    Application.put_env(:smalt, :arm_rate_limit, 5)

    on_exit(fn -> Application.put_env(:smalt, :arm_rate_limit, nil) end)

    if :ets.info(:smalt_arm_rate) != :undefined do
      :ets.delete_all_objects(:smalt_arm_rate)
    end

    statuses_limited =
      for _ <- 1..10 do
        {status, headers, body} = put!(port, path, body: sa_body(name))

        if status == 429 do
          assert headers["retry-after"] == "1"

          err = json(body)["error"]
          assert err["code"] == "TooManyRequests"
          assert Map.has_key?(err, "innererror")
        end

        status
      end

    assert 429 in statuses_limited
    assert 200 in statuses_limited
  end

  test "error envelopes carry innererror (present-but-empty)", %{port: port} do
    {_s, _h, body} = get!(port, "/subscriptions/#{@sub}/resourceGroups/rg1")
    assert json(body)["error"]["innererror"] == %{}

    {s, _h, body2} = put!(port, resource_path("stc1x", "1999-01-01"))
    assert s == 400
    assert json(body2)["error"]["innererror"] == %{}
  end

  test "success envelopes carry synthetic systemData", %{port: port} do
    name = "disk-sd-" <> unique()
    path = disks_path(name)

    {201, _h, body} = put!(port, path, body: Jason.encode!(%{"location" => "eastus"}))
    sd = json(body)["systemData"]

    assert sd["createdBy"] == "smalt-dev-substrate"
    assert sd["createdByType"] == "Application"
    assert is_binary(sd["createdAt"]) and sd["createdAt"] != ""

    # same systemData on the stored record (GET)
    {200, _h, body2} = get!(port, path)
    assert json(body2)["systemData"]["createdBy"] == "smalt-dev-substrate"
  end

  test "LIST paginates: 100 per page, nextLink absolute, follow yields remainder", %{port: port} do
    names =
      for _ <- 1..105 do
        name = "disk-pg-" <> unique()
        {201, _h, _} = put!(port, disks_path(name), body: Jason.encode!(%{"location" => "eastus"}))
        name
      end

    list_path =
      "/subscriptions/#{@sub}/resourceGroups/rg1/providers/Microsoft.Compute/disks?api-version=#{api_v("Microsoft.Compute/disks")}"

    {200, _h, body} = get!(port, list_path)
    page1 = json(body)

    assert length(page1["value"]) == 100
    assert is_binary(page1["nextLink"])

    # absolute nextLink pointing at this listener, carrying $skip
    assert String.starts_with?(page1["nextLink"], "http://127.0.0.1:#{port}")
    %{query: query} = URI.parse(page1["nextLink"])
    assert %{"$skip" => "100", "maxitempages" => "1"} = URI.decode_query(query)

    # follow the nextLink through the same listener (path + query only)
    next = URI.parse(page1["nextLink"])
    {200, _h, body2} = get!(port, "#{next.path}?#{next.query}")

    page2 = json(body2)
    assert length(page2["value"]) == 5
    refute Map.has_key?(page2, "nextLink")

    all_names = Enum.map(page1["value"] ++ page2["value"], & &1["name"])
    assert Enum.sort(all_names) == Enum.sort(names)
  end

  test "async headers use the request authority, not management.smalt.local (row 10 fixed)", %{
    port: port
  } do
    name = "stc1" <> unique()
    {202, headers, _b} = put!(port, resource_path(name), body: sa_body(name))

    assert String.contains?(headers["azure-asyncoperation"], "http://127.0.0.1:#{port}")
    assert String.contains?(headers["location"], "http://127.0.0.1:#{port}")
    refute String.contains?(headers["azure-asyncoperation"], "management.smalt.local")
  end

  test "GET validates api-version like PUT (row 6b fixed): bogus GET api-version -> 400", %{
    port: port
  } do
    {400, _h, body} = get!(port, resource_path("stc1x", "1999-01-01"))
    assert json(body)["error"]["code"] == "InvalidApiVersionParameter"
  end

  test "LRO types: create 202 + async headers, update 200 + async headers (row 3b fixed)", %{
    port: port
  } do
    name = "stc1" <> unique()
    path = resource_path(name)
    body = sa_body(name)

    {202, create_headers, _} = put!(port, path, body: body)
    assert create_headers["azure-asyncoperation"]

    {200, update_headers, _} = put!(port, path, body: body)
    assert update_headers["azure-asyncoperation"]
    assert update_headers["retry-after"] == "1"
  end

  # ===========================================================================
  # helpers
  # ===========================================================================

  defp resource_path(name, av \\ nil) do
    "/subscriptions/#{@sub}/resourceGroups/rg1/providers/Microsoft.Storage/storageAccounts/#{name}" <>
      "?api-version=#{av || api_v("Microsoft.Storage/storageAccounts")}"
  end

  defp sa_body(name) do
    Jason.encode!(%{
      "location" => "eastus",
      "properties" => %{"skuName" => "Standard_LRS", "name" => name}
    })
  end

  defp api_v(type) do
    case Smalt.Registry.latest_version(type) do
      nil -> "2021-04-01"
      v -> to_string(v)
    end
  end

  defp poll_until_terminal(port, async_url, attempts \\ 100)

  defp poll_until_terminal(_port, _url, 0), do: flunk("LRO never reached terminal status")

  defp poll_until_terminal(port, async_url, attempts) do
    Process.sleep(20)

    # The gateway advertises the authority the client actually used (row 10,
    # fixed): strip to the path and probe through the same listener.
    %URI{host: _host, path: path} = URI.parse(async_url)

    url = path

    {status, _headers, body} = get!(port, url)

    cond do
      status == 200 -> {200, json(body)}
      status == 202 -> poll_until_terminal(port, async_url, attempts - 1)
      true -> flunk("unexpected poll status #{status}: #{body}")
    end
  end

  defp delete!(port, path, opts \\ []) do
    parse(req(port, :delete, path, opts))
  end

  defp unique, do: :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

  defp free_port do
    {:ok, sock} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(sock)
    :gen_tcp.close(sock)
    port
  end

  defp ensure_store do
    case Store.start_link([]) do
      {:ok, _} ->
        :ok

      {:error, {:already_started, _}} ->
        if :ets.info(:smalt_subscriptions) == :undefined do
          pid = Process.whereis(Store)
          ref = Process.monitor(pid)

          receive do
            {:DOWN, ^ref, :process, ^pid, _} -> ensure_store()
          after
            500 -> :ok
          end
        else
          :ok
        end
    end
  end
end
