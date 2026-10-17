defmodule Smalt.RuntimeContracts.ArmEnvelope do
  @moduledoc """
  ARM envelope contract binding `Smalt.ArmGateway.Router` to its consumers.

  Fences, in-process, the CONFORMANT envelope invariants pinned by
  `test/compliance courts c1_arm.exs` and `docs/compliance/C1_ARM_REST.md`:

    * error envelope: `error.code` / `error.message` with
      `application/json; charset=utf-8`
    * GraphLaw refusal envelope: 400 `InvalidResourceGroup...` — precisely:
      400 `InvalidResourceShape`, target `AshGraphLaw.Enforcement`
    * catch-all: 404 `RouteNotFound`
    * success envelope: id / name / type / location /
      properties.provisioningState
    * status semantics: 201 create, 200 update, 404 after delete
    * LRO: 202 + Azure-AsyncOperation / Location / Retry-After,
      `status: InProgress` body
    * api-version gate: 400 `MissingApiVersionParameter` /
      `InvalidApiVersionParameter`
    * LIST envelope `{"value": [...]}`

  Template source: ash-runtime-integration-contract-pack
  `templates/api_contract.ex.tmpl`, adapted (see
  `docs/PACK_INTEGRATION/runtime-contracts.md`).
  """

  alias Smalt.RuntimeContracts.Support

  @behaviour Smalt.RuntimeContracts.Contract

  @sub "00000000-0000-0000-0000-000000000000"

  @impl true
  def name, do: :arm_envelope

  @impl true
  def plane, do: :control_plane

  @impl true
  def check do
    Support.contract(:arm_envelope, [
      {:error_envelope_json_charset, fn -> check_error_envelope() end},
      {:graphlaw_refusal_envelope, fn -> check_graphlaw_refusal() end},
      {:catch_all_route_not_found, fn -> check_catch_all() end},
      {:success_envelope_shape, fn -> check_success_envelope() end},
      {:put_create_201_update_200, fn -> check_status_semantics() end},
      {:lro_202_async_headers, fn -> check_lro() end},
      {:missing_api_version_400, fn -> check_missing_api_version() end},
      {:invalid_api_version_400, fn -> check_invalid_api_version() end},
      {:list_value_envelope, fn -> check_list_envelope() end}
    ])
  end

  # ===========================================================================
  # checks
  # ===========================================================================

  defp check_error_envelope do
    # The api-version gate is validated before RG existence (coordinator-
    # authorized landing 2026-10-15), so the probe carries api-version like
    # the compliance court does — the pinned invariant is the 404 envelope.
    resp = get("/subscriptions/#{@sub}/resourceGroups/rg-does-not-exist?api-version=2021-04-01")

    Support.assert_equal(resp.status, 404, "unknown resource group must 404")
    Support.assert_equal(
      resp.headers["content-type"],
      "application/json; charset=utf-8",
      "error envelope content-type"
    )

    err = json(resp.body)["error"]
    Support.assert(err, "error envelope must carry an error object")
    Support.assert(is_binary(err["code"]) and err["code"] != "", "error.code present")
    Support.assert(is_binary(err["message"]) and err["message"] != "", "error.message present")
  end

  defp check_graphlaw_refusal do
    path =
      "/subscriptions/#{@sub}/resourceGroups/rg1/providers/Microsoft.Nonsense/nonAdmitted/res1" <>
        "?api-version=2021-04-01"

    resp = put(path, ~s({"location": "eastus"}))

    Support.assert_equal(resp.status, 400, "GraphLaw refusal status")
    err = json(resp.body)["error"]

    Support.assert_equal(err["code"], "InvalidResourceShape", "GraphLaw refusal code")
    Support.assert_equal(err["target"], "AshGraphLaw.Enforcement", "GraphLaw refusal target")
  end

  defp check_catch_all do
    resp = get("/definitely/not/a/route?api-version=2021-04-01")

    Support.assert_equal(resp.status, 404, "catch-all status")
    Support.assert_equal(json(resp.body)["error"]["code"], "RouteNotFound", "catch-all code")
  end

  defp check_success_envelope do
    name = unique("disk-")
    path = disks_path(name)

    resp = put(path, ~s({"location": "eastus"}))
    Support.assert_equal(resp.status, 201, "PUT create must 201 (non-LRO type)")

    resp = get(disks_path(name))
    Support.assert_equal(resp.status, 200, "GET after create")

    res = json(resp.body)

    Support.assert_equal(
      res["id"],
      "/subscriptions/#{@sub}/resourceGroups/rg1/providers/Microsoft.Compute/disks/#{name}",
      "envelope id"
    )

    Support.assert_equal(res["name"], name, "envelope name")
    Support.assert_equal(res["type"], "Microsoft.Compute/disks", "envelope type")
    Support.assert_equal(res["location"], "eastus", "envelope location")
    Support.assert_equal(res["properties"]["provisioningState"], "Succeeded", "provisioningState")
  end

  defp check_status_semantics do
    name = unique("disk-")
    path = disks_path(name)
    body = ~s({"location": "eastus"})

    Support.assert_equal(put(path, body).status, 201, "PUT create -> 201")
    Support.assert_equal(put(path, body).status, 200, "PUT update -> 200")

    resp = delete(disks_path(name))
    Support.assert_equal(resp.status, 200, "DELETE -> 200")

    resp = get(disks_path(name))
    Support.assert_equal(resp.status, 404, "GET after delete -> 404")
  end

  defp check_lro do
    name = unique("stc-")
    resp = put(resource_path(name), sa_body(name))

    Support.assert_equal(resp.status, 202, "LRO PUT -> 202")
    Support.assert(is_binary(resp.headers["azure-asyncoperation"]), "Azure-AsyncOperation present")
    Support.assert(is_binary(resp.headers["location"]), "Location present")
    Support.assert_equal(resp.headers["retry-after"], "1", "Retry-After: 1")
    Support.assert_equal(json(resp.body)["status"], "InProgress", "LRO body status InProgress")

    # Poll in-process to terminal state so the contract also pins that the
    # async operation record converges to Succeeded.
    op_path = URI.parse(resp.headers["azure-asyncoperation"]).path
    {final, _body} = poll_to_terminal(op_path, 100)

    Support.assert_equal(final, 200, "LRO poll terminal 200")
  end

  defp check_missing_api_version do
    path =
      "/subscriptions/#{@sub}/resourceGroups/rg1/providers/Microsoft.Storage/storageAccounts/stcx"

    resp = get(path)
    Support.assert_equal(resp.status, 400, "missing api-version -> 400")

    Support.assert_equal(
      json(resp.body)["error"]["code"],
      "MissingApiVersionParameter",
      "missing api-version code"
    )
  end

  defp check_invalid_api_version do
    # KD-78 monotonic gate: beyond-latest is the invalid face (disclosed
    # cross-lane unblock: 1999-01-01 is now <= latest, hence accepted).
    resp = put(resource_path("stcx", "2999-01-01"), sa_body("stcx"))
    Support.assert_equal(resp.status, 400, "invalid api-version PUT -> 400")
    Support.assert_equal(
      json(resp.body)["error"]["code"],
      "InvalidApiVersionParameter",
      "invalid api-version code"
    )
  end

  defp check_list_envelope do
    name = unique("stc-")
    put(resource_path(name), sa_body(name))

    resp = get("/subscriptions/#{@sub}/resourceGroups/rg1/providers/Microsoft.Storage/storageAccounts" <>
      "?api-version=#{api_v("Microsoft.Storage/storageAccounts")}")

    Support.assert_equal(resp.status, 200, "LIST status")
    list = json(resp.body)
    Support.assert(is_list(list["value"]), "LIST carries value array")
    Support.assert(
      Enum.any?(list["value"], &(&1["name"] == name)),
      "LIST includes the created resource"
    )
  end

  # ===========================================================================
  # helpers
  # ===========================================================================

  defp poll_to_terminal(_path, 0), do: {500, nil}

  defp poll_to_terminal(path, attempts) do
    resp = get(path)

    cond do
      resp.status == 200 -> {200, resp.body}
      resp.status == 202 -> poll_to_terminal(path, attempts - 1)
      true -> {resp.status, resp.body}
    end
  end

  defp resource_path(name, av \\ nil) do
    "/subscriptions/#{@sub}/resourceGroups/rg1/providers/Microsoft.Storage/storageAccounts/#{name}" <>
      "?api-version=#{av || api_v("Microsoft.Storage/storageAccounts")}"
  end

  defp disks_path(name) do
    "/subscriptions/#{@sub}/resourceGroups/rg1/providers/Microsoft.Compute/disks/#{name}" <>
      "?api-version=#{api_v("Microsoft.Compute/disks")}"
  end

  defp sa_body(name) do
    Jason.encode!(%{"location" => "eastus", "properties" => %{"skuName" => "Standard_LRS", "name" => name}})
  end

  defp api_v(type) do
    case Smalt.Registry.latest_version(type) do
      nil -> "2021-04-01"
      v -> to_string(v)
    end
  end

  defp get(path), do: Support.dispatch(Smalt.ArmGateway.Router, "get", path)

  defp put(path, body), do: Support.dispatch(Smalt.ArmGateway.Router, "put", path, body: body)

  defp delete(path), do: Support.dispatch(Smalt.ArmGateway.Router, "delete", path)

  defp json(body), do: Jason.decode!(body)

  defp unique(prefix), do: prefix <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))
end
