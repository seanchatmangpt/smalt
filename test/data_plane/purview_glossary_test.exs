defmodule Smalt.DataPlane.PurviewGlossaryTest do
  use ExUnit.Case, async: false

  alias Smalt.DataPlane.Purview

  setup do
    # Real Store collaborators (Chicago): the app self-boots on ephemeral
    # ports; terms/edges live in the real :smalt_purview_* tables. Namespaced
    # fixture names keep concurrent file runs collision-free.
    tag = :crypto.strong_rand_bytes(4) |> Base.encode16()
    %{tag: tag}
  end

  test "glossary record lists terms; create -> attach -> lineage link -> delete -> 404", %{tag: tag} do
    # 2 terms
    {:ok, 201, t1} =
      Purview.put_term(%{
        "name" => "PII #{tag}",
        "definition" => "personally identifiable information",
        "abbreviation" => "PII"
      })

    {:ok, 201, t2} =
      Purview.put_term(%{
        "name" => "Sensitive #{tag}",
        "definition" => "handle with care",
        "abbreviation" => "S"
      })

    assert is_binary(t1["guid"]) and is_binary(t2["guid"])

    {:ok, 200, glossary} = Purview.glossary()
    display = Enum.map(glossary["terms"], & &1["displayText"])
    assert "PII #{tag}" in display and "Sensitive #{tag}" in display

    {:ok, 200, terms} = Purview.list_terms()
    names = Enum.map(terms, & &1["name"])
    assert "PII #{tag}" in names and "Sensitive #{tag}" in names

    # attach t1 to a real entity
    {:ok, 201, entity} =
      Purview.create_entity(%{"typeName" => "smalt_table", "attributes" => %{"name" => "t_#{tag}"}})

    {:ok, 200, attached} = Purview.put_term(%{"guid" => t1["guid"], "name" => "PII #{tag}", "assignedEntities" => [entity["guid"]]})
    assert [%{"guid" => g}] = attached["assignedEntities"]
    assert g == entity["guid"]

    # lineage shows the term link
    {:ok, 200, lin} = Purview.lineage(entity["guid"], "both", 1)
    assert Enum.any?(lin["relations"], fn r ->
             r["fromEntityId"] == t1["guid"] and r["toEntityId"] == entity["guid"]
           end)

    assert lin["guidEntityMap"][t1["guid"]]["name"] == "PII #{tag}"

    # unknown term guid -> typed face
    {:error, 404, err} = Purview.get_term("00000000-0000-0000-0000-000000000000")
    assert err["error"]["code"] == "ATLAS-404-GLOSSARY-TERM"

    # unknown assignedEntities guid -> entity 404, no partial attach
    {:ok, 201, t3} = Purview.put_term(%{"name" => "Orphan #{tag}"})
    {:error, 404, _} = Purview.put_term(%{"guid" => t3["guid"], "name" => "Orphan #{tag}", "assignedEntities" => ["nope-#{tag}"]})
    {:ok, 200, t3b} = Purview.get_term(t3["guid"])
    assert t3b["assignedEntities"] == []

    # delete -> edges gone -> lineage clean -> 404 after
    {:ok, 204, nil} = Purview.delete_term(t1["guid"])
    {:ok, 200, lin2} = Purview.lineage(entity["guid"], "both", 1)
    refute Enum.any?(lin2["relations"], &(&1["fromEntityId"] == t1["guid"]))
    {:error, 404, err2} = Purview.get_term(t1["guid"])
    assert err2["error"]["code"] == "ATLAS-404-GLOSSARY-TERM"
  end

  test "PUT with no name is a typed 400; update keeps guid", %{tag: tag} do
    {:error, 400, err} = Purview.put_term(%{"definition" => "x"})
    assert err["error"]["code"] == "ATLAS-400-00-001"

    {:ok, 201, t} = Purview.put_term(%{"name" => "Keep #{tag}", "definition" => "v1"})
    {:ok, 200, t2} = Purview.put_term(%{"guid" => t["guid"], "name" => "Keep #{tag} v2", "definition" => "v2"})
    assert t2["guid"] == t["guid"]
    assert t2["definition"] == "v2"
  end
end
