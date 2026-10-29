defmodule Smalt.SqlIngest.MappingCourtTest do
  @moduledoc """
  SQLD-4 court: the `sql:TableMapping` Turtle DSL projects 100 synthetic
  relational rows (25 customers + 40 orders + 35 order_items) into the
  COLD-1 OCEL v2 schema. Real collaborators throughout: the stdlib-only
  Turtle parser, the fail-closed `shacl_gate/1`, and the substrate's own
  `Smalt.Ocel` envelope encode/validate. No doubles.
  """

  use ExUnit.Case, async: false

  alias Smalt.Ocel
  alias Smalt.SqlIngest.Mapping

  @fixture "test/integration/fixtures/sql_ingest/sql_mapping.ttl"

  # 100 synthetic rows, deterministic (no RNG): 25 customers, 40 orders,
  # 35 order_items.
  defp customers do
    for i <- 1..25 do
      %{
        "customer_id" => "C#{i}",
        "name" => "cust-#{i}",
        "region" => Enum.at(~w(eu us apac), rem(i, 3)),
        "active" => Enum.at(["true", "false"], rem(i, 2))
      }
    end
  end

  defp orders do
    for i <- 1..40 do
      %{
        "order_id" => "O#{i}",
        "customer_id" => "C#{rem(i - 1, 25) + 1}",
        "status" => Enum.at(~w(placed packed shipped), rem(i, 3)),
        "created_at" => "2026-10-21T10:#{:io_lib.format("~2..0B", [rem(i, 60)])}Z",
        # COLD-1 event attribute columns
        "temp_celsius" => to_string(-20 + rem(i, 6)),
        "duration_seconds" => to_string(50 * i),
        # deliberately NOT declared anywhere in the mapping — the
        # "unmapped columns typed, not dropped" leg
        "memo" => "memo-#{i}"
      }
    end
  end

  defp order_items do
    for i <- 1..35 do
      %{
        "order_id" => "O#{i}",
        "item_id" => "I#{i}",
        "role" => Enum.at(~w(contains_product sensor_heartbeat), rem(i, 2)),
        "quantity" => to_string(rem(i, 5) + 1),
        "gift" => "false"
      }
    end
  end

  defp rows do
    %{
      "customers" => customers(),
      "orders" => orders(),
      "order_items" => order_items()
    }
  end

  defp court_setup do
    ttl = File.read!(@fixture)
    {:ok, mappings} = Mapping.parse(ttl)
    assert length(mappings) == 3
    :ok = Mapping.shacl_gate(mappings)
    {:ok, spec} = Mapping.compile(mappings)
    {mappings, spec}
  end

  describe "mapping DSL gate (fail-closed)" do
    test "parses the fixture and passes its own SHACL gate" do
      {mappings, spec} = court_setup()
      assert length(mappings) == 3
      assert map_size(spec.tables) == 3
    end

    test "missing eventTypeColumn refuses" do
      {:ok, mappings} =
        Mapping.parse("""
        @prefix sql: <http://example.org/sql#> .
        @prefix ex: <http://example.org/> .
        ex:M a sql:TableMapping ;
          sql:sourceTable "t" ;
          sql:role "event" ;
          sql:eventKeyColumn "id" ;
          sql:timestampColumn "ts" .
        """)

      assert {:error, [{"t", :eventTypeColumn, "role=event requires sql:eventTypeColumn"}]} =
               Mapping.shacl_gate(mappings)
    end

    test "missing timestampColumn refuses" do
      {:ok, mappings} =
        Mapping.parse("""
        @prefix sql: <http://example.org/sql#> .
        @prefix ex: <http://example.org/> .
        ex:M a sql:TableMapping ;
          sql:sourceTable "t" ;
          sql:role "event" ;
          sql:eventKeyColumn "id" ;
          sql:eventTypeColumn "st" .
        """)

      assert {:error, [{"t", :timestampColumn, "role=event requires sql:timestampColumn"}]} =
               Mapping.shacl_gate(mappings)
    end

    test "rel mapping without objectKeyColumn refuses; unknown role refuses" do
      {:ok, mappings} =
        Mapping.parse("""
        @prefix sql: <http://example.org/sql#> .
        @prefix ex: <http://example.org/> .
        ex:M a sql:TableMapping ;
          sql:sourceTable "r" ;
          sql:role "rel" ;
          sql:eventKeyColumn "e" ;
          sql:objectType "Thing" .
        ex:N a sql:TableMapping ;
          sql:sourceTable "s" ;
          sql:role "banana" .
        """)

      {:error, violations} = Mapping.shacl_gate(mappings)

      assert {"r", :objectKeyColumn, "role=rel requires sql:objectKeyColumn"} in violations
      assert {"s", :role, "unknown role \"banana\" (expected one of [\"event\", \"object\", \"rel\"])"} in violations
    end

    test "duplicate sourceTable refuses" do
      {:ok, mappings} =
        Mapping.parse("""
        @prefix sql: <http://example.org/sql#> .
        @prefix ex: <http://example.org/> .
        ex:A a sql:TableMapping ;
          sql:sourceTable "same" ;
          sql:role "event" ;
          sql:eventKeyColumn "id" ;
          sql:eventTypeColumn "t1" ;
          sql:timestampColumn "ts" .
        ex:B a sql:TableMapping ;
          sql:sourceTable "same" ;
          sql:role "event" ;
          sql:eventKeyColumn "id" ;
          sql:eventTypeColumn "t1" ;
          sql:timestampColumn "ts" .
        """)

      assert {:error, [{"same", :sourceTable, "duplicate sql:sourceTable in mapping document"}]} =
               Mapping.shacl_gate(mappings)
    end

    test "compile refuses a mapping that fails the gate (fail-closed)" do
      {:ok, mappings} =
        Mapping.parse("""
        @prefix sql: <http://example.org/sql#> .
        @prefix ex: <http://example.org/> .
        ex:M a sql:TableMapping ;
          sql:sourceTable "t" ;
          sql:role "event" .
        """)

      assert {:error, _} = Mapping.compile(mappings)
    end

    test "unknown predicate is a typed parse refusal, never a silent skip" do
      assert {:error, {:parse_failed, _}} =
               Mapping.parse("""
               @prefix sql: <http://example.org/sql#> .
               @prefix ex: <http://example.org/> .
               ex:M a sql:TableMapping ;
                 sql:sourceTable "t" ;
                 sql:role "event" ;
                 sql:eventKeyColumn "id" ;
                 sql:eventTypeColumn "st" ;
                 sql:timestampColumn "ts" ;
                 sql:frobnicate "yes" .
               """)
    end
  end

  describe "100-row projection into the COLD-1 schema" do
    test "projects 100 rows into 40 events / 60 objects / 35 rels, envelope-closed" do
      {_mappings, spec} = court_setup()

      assert {:ok, %{events: events, objects: objects}} = Mapping.project(spec, rows())
      assert length(events) == 40
      assert length(objects) == 60

      # customers: 25 objects of type Customer; items: 35 of type OrderItem
      assert Enum.count(objects, &(&1["type"] == "Customer")) == 25
      assert Enum.count(objects, &(&1["type"] == "OrderItem")) == 35

      # referential integrity via the substrate's own gate
      assert :ok == Ocel.validate_envelope(events, objects)

      # event shape: COLD-1 core fields + relationship to its customer
      o1 = Enum.find(events, &(&1["id"] == "O1"))
      assert o1["type"] in ~w(placed packed shipped)
      assert Regex.match?(~r/^2026-10-21T/, o1["time"])

      assert %{"objectId" => "C1", "qualifier" => "placed_by"} in o1["relationships"]

      # rel leg: O1 gains a contains_product relationship to its item object
      assert %{"objectId" => "I1", "qualifier" => "contains_product"} in o1["relationships"]

      # envelope encodes via the substrate (the COLD-1 envelope shape:
      # ocel:eventTypes / ocel:objectTypes / ocel:events / ocel:objects)
      assert {:ok, json} = Ocel.encode(events: events, objects: objects)
      doc = Jason.decode!(json)
      assert MapSet.new(Map.keys(doc)) == MapSet.new(["ocel:eventTypes", "ocel:objectTypes", "ocel:events", "ocel:objects"])
      assert "placed" in Enum.map(doc["ocel:eventTypes"], & &1["name"])
      assert "Customer" in Enum.map(doc["ocel:objectTypes"], & &1["name"])

      # round-trip: decode matches what went in
      assert {:ok, %{events: ev2, objects: ob2}} = Ocel.decode(json)
      assert length(ev2) == 40 and length(ob2) == 60
    end

    test "unmapped columns are typed, not dropped" do
      {_mappings, spec} = court_setup()
      {:ok, %{events: events}} = Mapping.project(spec, rows())

      memo = Enum.find(events, &(&1["id"] == "O2"))["attributes"]["memo"]
      assert %{value: "memo-2", type: "xsd:string"} = memo

      temp = Enum.find(events, &(&1["id"] == "O2"))["attributes"]["temp_celsius"]
      assert %{value: -18, type: "xsd:integer"} = temp

      dur = Enum.find(events, &(&1["id"] == "O2"))["attributes"]["duration_seconds"]
      assert %{value: 100, type: "xsd:integer"} = dur

      # declared columns are NOT attributes: they are identity/type/time/rels
      refute Map.has_key?(Enum.find(events, &(&1["id"] == "O2"))["attributes"], "customer_id")

      # object attributes typed too
      {_mappings, spec} = court_setup()
      {:ok, %{objects: objects}} = Mapping.project(spec, rows())
      cust = Enum.find(objects, &(&1["id"] == "C2"))
      assert %{value: "apac", type: "xsd:string"} = cust["attributes"]["region"]
      assert %{value: true, type: "xsd:boolean"} = cust["attributes"]["active"]
    end

    test "determinism: identical rows project to a byte-identical envelope" do
      {_mappings, spec} = court_setup()
      {:ok, %{events: e1, objects: o1}} = Mapping.project(spec, rows())
      {:ok, %{events: e2, objects: o2}} = Mapping.project(spec, rows())
      assert {:ok, j1} = Ocel.encode(events: e1, objects: o1)
      assert {:ok, j2} = Ocel.encode(events: e2, objects: o2)
      assert j1 == j2
    end

    test "COLD-1 CSV face: core columns lead all three CSVs" do
      {_mappings, spec} = court_setup()
      {:ok, env} = Mapping.project(spec, rows())
      csvs = Mapping.to_cold1_csvs(env)

      header = fn name -> csvs[name] |> String.split("\n") |> Enum.at(0) |> String.split(",") end

      # COLD-1 core columns lead; attribute tail order is first-seen
      assert Enum.take(header.("ocel_events.csv"), 3) == ~w(event_id event_type timestamp)
      assert MapSet.subset?(
               MapSet.new(~w(temp_celsius duration_seconds memo)),
               MapSet.new(header.("ocel_events.csv"))
             )

      assert header.("ocel_event_object_rel.csv") == ~w(event_id object_id qualifier)

      assert Enum.take(header.("ocel_objects.csv"), 2) == ~w(object_id object_type)
      assert MapSet.subset?(
               MapSet.new(~w(name region active)),
               MapSet.new(header.("ocel_objects.csv"))
             )

      # row counts: header + 40 / 75 / 60
      assert 41 == csvs["ocel_events.csv"] |> String.split("\n", trim: true) |> length()
      assert 76 == csvs["ocel_event_object_rel.csv"] |> String.split("\n", trim: true) |> length()
      assert 61 == csvs["ocel_objects.csv"] |> String.split("\n", trim: true) |> length()
    end

    test "dangling relationship refuses (fail-closed referential integrity)" do
      {_mappings, spec} = court_setup()

      rows = %{
        "orders" => [%{"order_id" => "OX", "customer_id" => "C999", "status" => "placed",
                       "created_at" => "2026-10-21T10:00:00Z", "temp_celsius" => "-18",
                       "duration_seconds" => "10", "memo" => "x"}],
        "customers" => [],
        "order_items" => []
      }

      assert {:error, {:dangling_relationships, [{"OX", "C999"}]}} = Mapping.project(spec, rows)
    end
  end
end
