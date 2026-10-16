defmodule Smalt.RuntimeContracts.ResourceGraphQuery do
  @moduledoc """
  Azure Resource Graph contract binding `Smalt.EgressRouter`'s Resource Graph
  surface (backed by `Smalt.DataPlane.ResourceGraph`) to its consumers.

  Fences, in-process, the wire invariants of
  `POST /providers/Microsoft.ResourceGraph/resources`:

    * success envelope: `count` / `data` / `totalRecords` / `resultTruncated`
    * `$skipToken` pagination: token returned while pages remain, second page
      continues without overlap or gap; no token on the final page
    * `$top` page size honored
    * subscription filter respected (resource from another subscription is
      excluded)
    * KQL `where` query field filters rows
    * api-version gate: 400 `InvalidApiVersion` unless `2022-10-01`

  Template source: ash-runtime-integration-contract-pack
  `templates/api_contract.ex.tmpl`, adapted (see
  `docs/PACK_INTEGRATION/runtime-contracts.md`).
  """

  alias Smalt.RuntimeContracts.Support

  @behaviour Smalt.RuntimeContracts.Contract

  @api_version "2022-10-01"
  @sub "00000000-0000-0000-0000-000000000000"

  @impl true
  def name, do: :resource_graph_query

  @impl true
  def plane, do: :control_plane

  @impl true
  def check do
    Support.contract(:resource_graph_query, [
      {:success_envelope_shape, fn -> check_envelope() end},
      {:skip_token_pagination, fn -> check_pagination() end},
      {:top_page_size, fn -> check_top() end},
      {:subscription_filter, fn -> check_subscription_filter() end},
      {:kql_where_query_field, fn -> check_kql_where() end},
      {:api_version_gate, fn -> check_api_version_gate() end}
    ])
  end

  # ===========================================================================
  # checks
  # ===========================================================================

  defp check_envelope do
    ids = seed_resources(2)

    resp = query(%{"subscriptions" => [@sub], "query" => "", "options" => %{"$top" => 100}})

    Support.assert_equal(resp.status, 200, "query status")
    body = json(resp.body)

    Support.assert(is_integer(body["count"]) and body["count"] >= length(ids),
      "count integer >= seeded (#{inspect(body["count"])} < #{length(ids)})")
    Support.assert(is_list(body["data"]), "data array")
    Support.assert(is_integer(body["totalRecords"]) and body["totalRecords"] >= body["count"],
      "totalRecords >= count")
    Support.assert(is_boolean(body["resultTruncated"]), "resultTruncated boolean")
  end

  defp check_pagination do
    seed_resources(3)

    # Baseline the full filtered set BEFORE paging: other contract checks may
    # have seeded resources into the same Store, so the expected page coverage
    # must come from a real query, never an assumed count.
    total = full_data() |> length()

    page1 = json(query(%{"subscriptions" => [@sub], "options" => %{"$top" => 2}}).body)

    Support.assert_equal(page1["count"], 2, "page 1 size $top")
    Support.assert(is_binary(page1["$skipToken"]), "page 1 carries $skipToken while pages remain")

    page2 =
      json(
        query(%{"subscriptions" => [@sub], "options" => %{"$top" => 2, "$skipToken" => page1["$skipToken"]}}).body
      )

    Support.assert(is_list(page2["data"]), "page 2 data array")

    ids1 = page1["data"] |> Enum.map(& &1["id"]) |> MapSet.new()
    ids2 = page2["data"] |> Enum.map(& &1["id"]) |> MapSet.new()

    Support.assert(MapSet.disjoint?(ids1, ids2), "pages do not overlap")

    Support.assert_equal(page1["count"] + page2["count"], min(total, 4),
      "pages cover the baseline set (server cap aside)")
    Support.assert(is_map_key(page2, "$skipToken") == false or total > 4,
      "no token past the final page (unless other seeds remain)")
  end

  defp check_top do
    seed_resources(4)

    body = json(query(%{"subscriptions" => [@sub], "options" => %{"$top" => 3}}).body)
    Support.assert_equal(body["count"], 3, "$top page size honored")
  end

  defp check_subscription_filter do
    other_sub = "11111111-1111-1111-1111-111111111111"
    seed_resource(other_sub, "cross-sub-disk")

    body = json(query(%{"subscriptions" => [@sub], "options" => %{"$top" => 1000}}).body)

    Support.assert(
      Enum.any?(body["data"], &(&1["id"] =~ other_sub)) == false,
      "resource from another subscription excluded"
    )

    body_all = json(query(%{"options" => %{"$top" => 1000}}).body)
    Support.assert(Enum.any?(body_all["data"], &(&1["id"] =~ other_sub)),
      "unfiltered query includes the cross-subscription resource")
  end

  defp check_kql_where do
    marker = unique("kql-disk-")
    seed_resource(@sub, marker)

    body =
      json(
        query(%{"subscriptions" => [@sub], "query" => "where name == '#{marker}'", "options" => %{"$top" => 1000}}).body
      )

    Support.assert(Enum.any?(body["data"], &(&1["name"] == marker)), "KQL where finds seeded resource")
    Support.assert(length(body["data"]) == 1, "KQL where returns exactly the match")
  end

  defp check_api_version_gate do
    resp =
      Support.dispatch(
        Smalt.EgressRouter,
        "post",
        "/providers/Microsoft.ResourceGraph/resources?api-version=1999-01-01",
        body: Jason.encode!(%{"subscriptions" => [@sub]})
      )

    Support.assert_equal(resp.status, 400, "wrong api-version -> 400")
    Support.assert_equal(json(resp.body)["error"]["code"], "InvalidApiVersion", "api-version gate code")
  end

  # ===========================================================================
  # helpers
  # ===========================================================================

  defp seed_resources(n), do: for(_ <- 1..n, do: seed_resource(@sub, unique("rg-seed-")))

  defp seed_resource(sub, name) do
    id =
      if sub == @sub do
        "/subscriptions/#{@sub}/resourceGroups/rg1/providers/Microsoft.Compute/disks/#{name}"
      else
        "/subscriptions/#{sub}/resourceGroups/rg1/providers/Microsoft.Compute/disks/#{name}"
      end

    resp =
      Support.dispatch(
        Smalt.ArmGateway.Router,
        "put",
        id <> "?api-version=#{api_v("Microsoft.Compute/disks")}",
        body: ~s({"location": "eastus"})
      )

    Support.assert(resp.status in [200, 201], "seed PUT via ARM router succeeded (#{resp.status})")
    id
  end

  defp full_data do
    query(%{"subscriptions" => [@sub], "options" => %{"$top" => 1000}})
    |> Map.fetch!(:body)
    |> json()
    |> Map.fetch!("data")
  end

  defp api_v(type) do
    case Smalt.Registry.latest_version(type) do
      nil -> "2021-04-01"
      v -> to_string(v)
    end
  end

  defp query(payload) do
    Support.dispatch(
      Smalt.EgressRouter,
      "post",
      "/providers/Microsoft.ResourceGraph/resources?api-version=#{@api_version}",
      body: Jason.encode!(payload)
    )
  end

  defp json(body), do: Jason.decode!(body)

  defp unique(prefix), do: prefix <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))
end
