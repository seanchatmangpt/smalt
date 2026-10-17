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

  # xaas wire-parity §4.7 adoption (lens-6): whole-court selection tag. Only
  # c1 carries this tag (the "full c1..c7 court set" comment was false — the
  # corpus loads via test/compliance_test.exs / just test-compliance since
  # 2026-10-17). No default behavior change: :compliance is NOT in the
  # test_helper.exs exclusion list, so untagged/default runs are unchanged.
  @moduletag :compliance

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
    {status, headers, body} = get!(port, "/subscriptions/#{@sub}/resourceGroups/rg1?api-version=2023-07-01")

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
    path = "/subscriptions/#{@sub}/resourceGroups/#{rg}?api-version=2023-07-01"

    {201, _h, _} = put!(port, path, body: Jason.encode!(%{"location" => "westus"}))
    {200, _h, _} = put!(port, path, body: Jason.encode!(%{"location" => "westus"}))

    {200, _h, body} = get!(port, path)
    assert json(body)["properties"]["provisioningState"] == "Succeeded"

    # RG delete is an ARM LRO: 202 + Location polling URL + Retry-After (row 4).
    {202, del_headers, ""} = delete!(port, path)
    assert is_binary(del_headers["location"])
    assert del_headers["location"] =~ "/subscriptions/#{@sub}/operations/"
    assert del_headers["retry-after"] == "1"

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

    # Lens-3 cross-court round 2: pin the message bytes too — the RG-gate
    # court below exercises the same seam from a second route; both courts
    # must see the identical string.
    assert json(body)["error"]["message"] == "The api-version query parameter is required."
  end

  # KD-78 (closed 2026-10-16, docs/jira/v26.10.14/KNOWN_DIVERGENCES.md +
  # docs/jira/v26.10.16/sdk-results/version-lattice-receipt.md): api-version
  # admission is MONOTONIC — version <= latest is admitted, so a stale call
  # (1999-01-01) now succeeds. The refusal seam is pinned with a FUTURE version
  # (> latest is the refused class under both the old exact-match and the new
  # monotonic law).
  test "invalid api-version on admitted type (PUT) -> 400 InvalidApiVersionParameter", %{
    port: port
  } do
    {400, _h, body} = put!(port, resource_path("stc1x", "2099-01-01"))
    assert json(body)["error"]["code"] == "InvalidApiVersionParameter"
  end

  # C1 pin (KD-78 re-pin): the admitted latest version is exact per type — a
  # newer-than-latest call must be told the literal latest string, not merely
  # rejected.
  test "newer-than-latest api-version error names the exact latest version for the type", %{
    port: port
  } do
    path =
      "/subscriptions/#{@sub}/resourceGroups/rg1/providers/Microsoft.ContainerService/managedClusters/mc1?api-version=2099-01-01"

    {400, _h, body} = put!(port, path)
    err = json(body)["error"]
    assert err["code"] == "InvalidApiVersionParameter"
    assert err["message"] =~ "2023-02-01"
  end

  # ===========================================================================
  # (6) Case-insensitivity: resourcegroups segment + provider namespace
  # ===========================================================================

  test "resourcegroups and resourceGroups spellings both resolve", %{port: port} do
    rg = "rg-c1-" <> unique()

    {201, _h, _} =
      put!(port, "/subscriptions/#{@sub}/resourceGroups/#{rg}?api-version=2023-07-01",
        body: Jason.encode!(%{"location" => "eastus"})
      )

    {200, _h, _} = get!(port, "/subscriptions/#{@sub}/resourcegroups/#{rg}?api-version=2023-07-01")

    {200, _h, list_body} = get!(port, "/subscriptions/#{@sub}/resourcegroups?api-version=2023-07-01")

    list = json(list_body)
    assert is_list(list["value"])

    # Mutant-kill: items are full RG envelopes, not bare names — pin the exact
    # shape of the created group's list entry (ARM RP contract).
    entry = Enum.find(list["value"], &(&1["name"] == rg))

    assert entry, "created rg #{rg} missing from LIST"
    assert entry["id"] == "/subscriptions/#{@sub}/resourceGroups/#{rg}"
    assert entry["type"] == "Microsoft.Resources/resourceGroups"
    assert entry["location"] == "eastus"
    assert entry["properties"]["provisioningState"] == "Succeeded"
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
    {s1, headers, _b} = get!(port, "/subscriptions/#{@sub}/resourceGroups/rg1?api-version=2023-07-01")

    assert s1 == 404

    # Server-generated request-id must be the same RFC 4122 v4 dashed GUID the
    # LA surface (c7) pins — cross-court lens-2 cycle-1 unification
    # (previously length-only here). The BLOB plane still emits 32-hex
    # (finding F1, data-plane lane owns the fix); c4 pins the honest bytes.
    assert is_binary(headers["x-ms-request-id"]) and byte_size(headers["x-ms-request-id"]) == 36

    assert Regex.match?(
             ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/,
             headers["x-ms-request-id"]
           ),
           "server-minted x-ms-request-id must be a v4 GUID, got: #{inspect(headers["x-ms-request-id"])}"

    # client-supplied request id is echoed verbatim
    {s2, headers2, _b2} =
      parse(
        req(port, :get, "/subscriptions/#{@sub}/resourceGroups/rg1?api-version=2023-07-01",
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

    # Align to the next wall-clock second so all 10 requests land in ONE
    # fixed window — this makes the window's admit count exactly assertable.
    ms = System.system_time(:millisecond)
    Process.sleep(1000 - rem(ms, 1000) + 5)

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

    # Exact window arithmetic: exactly :arm_rate_limit admits, then 429s —
    # pins the `count > limit` (never `>=`) and the per-second reset.
    assert statuses_limited == [200, 200, 200, 200, 200, 429, 429, 429, 429, 429]

    # Window expiry: after the 1s window rolls over the counter is reset —
    # the next request is admitted again (fixed window, not a permanent ban).
    Process.sleep(1100)
    {status_after, _h, _b} = put!(port, path, body: sa_body(name))
    assert status_after == 200
  end

  test "error envelopes carry innererror (present-but-empty)", %{port: port} do
    {_s, _h, body} = get!(port, "/subscriptions/#{@sub}/resourceGroups/rg1?api-version=2023-07-01")
    assert json(body)["error"]["innererror"] == %{}

    # KD-78: future version (> latest) is the refused class; stale would be
    # admitted monotonic.
    {s, _h, body2} = put!(port, resource_path("stc1x", "2099-01-01"))
    assert s == 400
    assert json(body2)["error"]["innererror"] == %{}
  end

  test "404 envelopes carry error.target naming the offending path; api-version 400s do not (row 1b)",
       %{port: port} do
    # RouteNotFound: target is the unmatched path.
    {_s, _h, body} = get!(port, "/definitely/not/a/route")
    assert json(body)["error"]["target"] == "/definitely/not/a/route"

    # ResourceGroupNotFound: target is the RG resource id (no query string).
    rg_id = "/subscriptions/#{@sub}/resourceGroups/tgt-rg"
    {_s, _h, body2} = get!(port, rg_id <> "?api-version=2021-04-01")
    err2 = json(body2)["error"]
    assert err2["code"] == "ResourceGroupNotFound"
    assert err2["target"] == rg_id

    # api-version 400s: target ABSENT (query-param failure, no path component).
    # KD-78: future version (> latest) is the refused class; stale is admitted.
    {400, _h, body3} = put!(port, resource_path("stc1t", "2099-01-01"), body: sa_body("stc1t"))
    refute Map.has_key?(json(body3)["error"], "target")
  end

  test "success envelopes carry synthetic systemData", %{port: port} do
    name = "disk-sd-" <> unique()
    path = disks_path(name)

    {201, _h, body} = put!(port, path, body: Jason.encode!(%{"location" => "eastus"}))
    sd = json(body)["systemData"]

    assert sd["createdBy"] == "smalt-dev-substrate"
    assert sd["createdByType"] == "Application"
    # Pin CURRENT wire bytes: createdAt is the synthetic @system_data constant
    # (router.ex:52-56) — a timestamp-format change must flip this fence
    # deliberately.
    assert sd["createdAt"] == "2026-01-01T00:00:00.0000000+00:00"

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
    decoded = URI.decode_query(query)
    assert %{"$skip" => "100", "maxitempages" => "1"} = decoded
    # lens-8: the emitted nextLink must PRESERVE the request's api-version
    # (absolute-link replayability: a follower needs a well-formed ARM call)
    assert decoded["api-version"] == api_v("Microsoft.Compute/disks")

    # follow the nextLink through the same listener (path + query only)
    next = URI.parse(page1["nextLink"])
    {200, _h, body2} = get!(port, "#{next.path}?#{next.query}")

    page2 = json(body2)
    assert length(page2["value"]) == 5
    refute Map.has_key?(page2, "nextLink")

    all_names = Enum.map(page1["value"] ++ page2["value"], & &1["name"])
    assert Enum.sort(all_names) == Enum.sort(names)

    # $skip arithmetic: a mid-window skip pages from the skip offset.
    {200, _h, body3} = get!(port, list_path <> "&$skip=50")
    page_mid = json(body3)
    assert length(page_mid["value"]) == 55
    refute Map.has_key?(page_mid, "nextLink")

    # Garbage $skip is treated as 0 (no 500, full first page + nextLink).
    {200, _h, body4} = get!(port, list_path <> "&$skip=abc")
    page_bad = json(body4)
    assert length(page_bad["value"]) == 100
    assert is_binary(page_bad["nextLink"])

    # maxitempages=0 (or negative) clamps to 1 page, never 0 or unbounded.
    {200, _h, body5} = get!(port, list_path <> "&maxitempages=0")
    page_clamp = json(body5)
    assert length(page_clamp["value"]) == 100
    assert is_binary(page_clamp["nextLink"])
    %{query: query5} = URI.parse(page_clamp["nextLink"])
    assert %{"maxitempages" => "1"} = URI.decode_query(query5)
  end

  test "nextLink composition fuzz: clamps hold for hostile maxitempages/$skip and stale replay",
       %{port: port} do
    names =
      for _ <- 1..105 do
        name = "disk-fz-" <> unique()
        {201, _h, _} = put!(port, disks_path(name), body: Jason.encode!(%{"location" => "eastus"}))
        name
      end

    list_path =
      "/subscriptions/#{@sub}/resourceGroups/rg1/providers/Microsoft.Compute/disks?api-version=#{api_v("Microsoft.Compute/disks")}"

    n_of = fn body -> length(json(body)["value"]) end
    nl_of = fn body -> json(body)["nextLink"] end

    # Huge maxitempages is NOT unbounded: pages = max(huge, 1) — with 105
    # items, maxitempages=9999 returns everything in one response, no nextLink.
    {200, _h, b_huge} = get!(port, list_path <> "&maxitempages=9999")
    assert n_of.(b_huge) == 105
    refute nl_of.(b_huge)

    # Negative maxitempages clamps to 1 page.
    {200, _h, b_neg} = get!(port, list_path <> "&maxitempages=-5")
    assert n_of.(b_neg) == 100
    assert is_binary(nl_of.(b_neg))

    # Float maxitempages ("1.5") fails Integer.parse-with-empty-rest -> default 1.
    {200, _h, b_float} = get!(port, list_path <> "&maxitempages=1.5")
    assert n_of.(b_float) == 100
    assert is_binary(nl_of.(b_float))
    %{query: q_float} = URI.parse(nl_of.(b_float))
    assert %{"maxitempages" => "1"} = URI.decode_query(q_float)

    # $skip exactly at the last item and one past it: 1 item / 0 items, both
    # terminal (no nextLink) — a stale nextLink cannot fabricate more pages.
    {200, _h, b_skip104} = get!(port, list_path <> "&$skip=104")
    assert n_of.(b_skip104) == 1
    refute nl_of.(b_skip104)

    {200, _h, b_skip105} = get!(port, list_path <> "&$skip=105")
    assert n_of.(b_skip105) == 0
    refute nl_of.(b_skip105)

    # Negative $skip falls back to 0 (no 500, full first page).
    {200, _h, b_negskip} = get!(port, list_path <> "&$skip=-1")
    assert n_of.(b_negskip) == 100

    # Stale/hostile nextLink REPLAY with maxitempages=0: the echo-clamp holds —
    # the response is still a clamped 100-item page and the continuation echoes
    # maxitempages=1, so replay can never unclamp the pagination arithmetic.
    {200, _h, b_replay} = get!(port, list_path <> "&%24skip=0&maxitempages=0")
    assert n_of.(b_replay) == 100
    assert is_binary(nl_of.(b_replay))
    %{query: q_replay} = URI.parse(nl_of.(b_replay))
    assert %{"maxitempages" => "1"} = URI.decode_query(q_replay)

    # Conservation: the union of the default page + the remainder is exactly
    # the created set (no item lost or duplicated by any clamp above).
    {200, _h, b_p1} = get!(port, list_path)
    page1_names = Enum.map(json(b_p1)["value"], & &1["name"])

    {200, _h, b_p2} = get!(port, nl_of.(b_p1) |> URI.parse() |> then(&"#{&1.path}?#{&1.query}"))
    page2_names = Enum.map(json(b_p2)["value"], & &1["name"])

    assert Enum.sort(page1_names ++ page2_names) == Enum.sort(names)
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

  # KD-78: GET validates like PUT — future version (> latest) refused; a stale
  # version would be admitted monotonic and 404 on the missing resource.
  test "GET validates api-version like PUT (row 6b fixed): future GET api-version -> 400", %{
    port: port
  } do
    {400, _h, body} = get!(port, resource_path("stc1x", "2099-01-01"))
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

  # ===========================================================================
  # (14) RG api-version gate (row 6b, coordinator-authorized landing)
  # ===========================================================================

  test "resource-group verbs enforce api-version on all four verbs (row 6b closed)", %{
    port: port
  } do
    base = "/subscriptions/#{@sub}/resourceGroups/rg6b"

    # Missing api-version -> 400 MissingApiVersionParameter on every verb.
    for {method, path} <- [
          {:put, base},
          {:get, base},
          {:delete, base},
          {:get, "/subscriptions/#{@sub}/resourcegroups"}
        ] do
      {status, _h, body} =
        case method do
          :put -> put!(port, path, body: Jason.encode!(%{"location" => "eastus"}))
          m -> req(port, m, path, []) |> parse()
        end

      assert status == 400, "#{method} #{path} -> #{status}"
      assert json(body)["error"]["code"] == "MissingApiVersionParameter"

      # Lens-3 cross-court round 2: byte-identical message with the
      # missing-api-version court above (same seam, second route).
      assert json(body)["error"]["message"] == "The api-version query parameter is required."
    end

    # KD-78: future api-version (> latest) -> 400 InvalidApiVersionParameter
    # naming the latest (a stale version would be admitted monotonic).
    {400, _h, body2} = put!(port, base <> "?api-version=2099-01-01", body: Jason.encode!(%{"location" => "eastus"}))
    err2 = json(body2)["error"]
    assert err2["code"] == "InvalidApiVersionParameter"

    # Lens-3: pin the full template bytes (the future court earlier pins the
    # same template for managedClusters; here it's resourceGroups's own latest).
    assert err2["message"] ==
             "The api-version '2099-01-01' is invalid. The latest supported api-version for 'Microsoft.Resources/resourceGroups' is '2023-07-01'."

    assert err2["message"] =~ "2023-07-01"

    # Valid latest api-version -> the wire behaves exactly as before the gate.
    {201, _h, _} =
      put!(port, base <> "?api-version=2021-04-01", body: Jason.encode!(%{"location" => "eastus"}))

    {200, _h, _} = get!(port, base <> "?api-version=2021-04-01")
    {200, _h, list_body} = get!(port, "/subscriptions/#{@sub}/resourcegroups?api-version=2023-07-01")
    assert is_list(json(list_body)["value"])
  end

  # ---------------------------------------------------------------------------
  # Row 5b — Failed operation status: the wire renders a terminal Failed
  # operation as 200 with `status="Failed"`, an `endTime`, and the ARM error
  # member (`error.code`/`error.message`). Producer: the lens-9 livelock fix —
  # an InProgress record missing scheduling fields flips to Failed at first
  # evaluation (test/lro_test.exs fence (13) pins the mint path at the LRO
  # seam; this fence pins the wire tier). Closes the wire half of
  # GAP(lro-no-failed-path)'s close condition.
  # ---------------------------------------------------------------------------
  test "row 5b: polling a Failed operation returns 200 with status Failed and error member", %{port: port} do
    id = "handseeded0000000000000000"

    # Seed an InProgress record with no scheduling fields; the poll flips it to
    # the persisted Failed terminal (lens-9 livelock fix producer).
    Store.put(:smalt_operations, id, %{
      "id" => "/subscriptions/#{@sub}/operations/#{id}",
      "name" => id,
      "status" => "InProgress",
      "startTime" => "2026-01-01T00:00:00Z",
      "endTime" => nil,
      "resourceId" => "/subscriptions/#{@sub}/resourceGroups/rg1/missing"
    })

    {status, _headers, body} = get!(port, "/subscriptions/#{@sub}/operations/#{id}")

    assert status == 200
    op = json(body)

    assert op["status"] == "Failed"
    assert is_binary(op["endTime"])

    assert %{"code" => "OperationRecordIncomplete", "message" => msg} = op["error"]
    assert is_binary(msg) and msg != ""
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
