defmodule Smalt.RuntimeContracts.PurviewAtlas do
  @moduledoc """
  Microsoft Purview Catalog (Atlas v2) contract binding `Smalt.EgressRouter`'s
  Atlas surface (backed by `Smalt.DataPlane.Purview`) to its consumers.

  Fences, in-process, the wire invariants:

    * entity create: 201, guid assigned when absent, readable back via
      `GET /atlas/v2/entity/guid/:guid`
    * unknown guid: 404 `ATLAS-404-00-005`
    * bulk create: 201 with `guidAssignments`; over the 100-entity limit ->
      400 `ATLAS-400-00-001` with NO partial insert (atomicity)
    * relationship: 201 minting a lineage edge immediately visible to
      `GET /atlas/v2/lineage/output/:guid`
    * relationship missing end1/end2 guids: 400 `ATLAS-400-00-001`
    * lineage: `baseEntityGuid` / `guidEntityMap` / `relations` envelope;
      bad direction -> 400

  Template source: ash-runtime-integration-contract-pack
  `templates/api_contract.ex.tmpl`, adapted (see
  `docs/PACK_INTEGRATION/runtime-contracts.md`).
  """

  alias Smalt.RuntimeContracts.Support

  @behaviour Smalt.RuntimeContracts.Contract

  @impl true
  def name, do: :purview_atlas

  @impl true
  def plane, do: :data_plane

  @impl true
  def check do
    Support.contract(:purview_atlas, [
      {:entity_create_read_201, fn -> check_entity_create_read() end},
      {:entity_unknown_guid_404, fn -> check_unknown_guid() end},
      {:bulk_create_201_assignments, fn -> check_bulk() end},
      {:bulk_over_limit_atomic_400, fn -> check_bulk_atomicity() end},
      {:relationship_201_lineage_visible, fn -> check_relationship_lineage() end},
      {:relationship_missing_ends_400, fn -> check_relationship_400() end},
      {:lineage_bad_direction_400, fn -> check_bad_direction() end}
    ])
  end

  # ===========================================================================
  # checks
  # ===========================================================================

  defp check_entity_create_read do
    guid = unique_guid()
    name = unique("entity-")

    resp =
      post("/atlas/v2/entity", %{
        "entity" => %{
          "guid" => guid,
          "typeName" => "smalt_table",
          "attributes" => %{"name" => name}
        }
      })

    Support.assert_equal(resp.status, 201, "entity create 201")

    got = get("/atlas/v2/entity/guid/#{guid}")
    Support.assert_equal(got.status, 200, "entity read 200")
    Support.assert_equal(json(got.body)["typeName"], "smalt_table", "entity round-trip")
  end

  defp check_unknown_guid do
    resp = get("/atlas/v2/entity/guid/#{unique_guid()}")
    Support.assert_equal(resp.status, 404, "unknown guid 404")
    Support.assert_equal(json(resp.body)["error"]["code"], "ATLAS-404-00-005", "not-found code")
  end

  defp check_bulk do
    entities =
      for i <- 1..3,
          do: %{
            "typeName" => "smalt_table",
            "attributes" => %{"name" => "bulk-#{unique("e")}-#{i}"}
          }

    resp = post("/atlas/v2/entity/bulk", %{"entities" => entities})
    Support.assert_equal(resp.status, 201, "bulk create 201")

    body = json(resp.body)

    Support.assert(
      is_map(body["guidAssignments"]) and map_size(body["guidAssignments"]) == 3,
      "guidAssignments for every entity"
    )

    Support.assert(is_list(body["mutatedEntities"]["CREATE"]), "mutatedEntities CREATE list")
  end

  defp check_bulk_atomicity do
    guid = unique_guid()

    # 101 entities: over the limit — the whole batch must be refused.
    over =
      for i <- 1..101,
          do: %{
            "guid" => guid <> "-#{String.pad_leading(Integer.to_string(i), 3, "0")}",
            "typeName" => "smalt_table"
          }

    resp = post("/atlas/v2/entity/bulk", %{"entities" => over})
    Support.assert_equal(resp.status, 400, "over-limit bulk 400")
    Support.assert_equal(json(resp.body)["error"]["code"], "ATLAS-400-00-001", "over-limit code")

    # Atomicity: none of the over-limit batch may have landed.
    probe = get("/atlas/v2/entity/guid/#{guid}-001")

    Support.assert_equal(
      probe.status,
      404,
      "no partial insert (first entity of refused batch absent)"
    )
  end

  defp check_relationship_lineage do
    from = unique_guid()
    to = unique_guid()

    create =
      post("/atlas/v2/entity", %{"entity" => %{"guid" => from, "typeName" => "smalt_table"}})

    Support.assert_equal(create.status, 201, "lineage source entity 201")

    create = post("/atlas/v2/entity", %{"entity" => %{"guid" => to, "typeName" => "smalt_table"}})
    Support.assert_equal(create.status, 201, "lineage target entity 201")

    resp =
      post("/atlas/v2/relationship", %{
        "relationship" => %{
          "end1" => %{"guid" => from},
          "end2" => %{"guid" => to},
          "typeName" => "smalt_lineage"
        }
      })

    Support.assert_equal(resp.status, 201, "relationship 201")
    rel_guid = json(resp.body)["guid"]
    Support.assert(is_binary(rel_guid) and rel_guid != "", "relationship guid returned")

    lineage = get("/atlas/v2/lineage/output/#{from}?depth=2")
    Support.assert_equal(lineage.status, 200, "lineage 200")

    body = json(lineage.body)
    Support.assert_equal(body["baseEntityGuid"], from, "lineage baseEntityGuid")

    Support.assert(
      Map.has_key?(body["guidEntityMap"], to),
      "lineage reaches target via minted edge"
    )

    Support.assert(
      Enum.any?(body["relations"], &(&1["relationshipId"] == rel_guid)),
      "relations carries the minted relationshipId"
    )
  end

  defp check_relationship_400 do
    resp = post("/atlas/v2/relationship", %{"relationship" => %{"typeName" => "smalt_lineage"}})
    Support.assert_equal(resp.status, 400, "missing ends 400")

    Support.assert_equal(
      json(resp.body)["error"]["code"],
      "ATLAS-400-00-001",
      "missing-ends code"
    )
  end

  defp check_bad_direction do
    resp = get("/atlas/v2/lineage/sideways/#{unique_guid()}")
    Support.assert_equal(resp.status, 400, "bad direction 400")

    Support.assert_equal(
      json(resp.body)["error"]["code"],
      "ATLAS-400-00-001",
      "bad-direction code"
    )
  end

  # ===========================================================================
  # helpers
  # ===========================================================================

  defp post(path, payload),
    do: Support.dispatch(Smalt.EgressRouter, "post", path, body: Jason.encode!(payload))

  defp get(path), do: Support.dispatch(Smalt.EgressRouter, "get", path)

  defp json(body), do: Jason.decode!(body)

  defp unique_guid, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

  defp unique(prefix), do: prefix <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))
end
