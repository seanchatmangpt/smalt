defmodule Smalt.GraphLaw.SqlShapeGenCourtTest do
  @moduledoc """
  SQLD-5 court: auto-shape generation from a projected relational
  schema, validated against the substrate's own SHACL admission gate.
  Real collaborators throughout (ShapeFile parser + Validator evaluator,
  both compiled from lib/); no doubles.
  """

  use ExUnit.Case, async: false

  alias Smalt.GraphLaw.SqlShapeGen
  alias Smalt.GraphLaw.Validator

  # 3-table projected schema (duckdb DESCRIBE shape: name/type/null; pk
  # from duckdb_constraints()).
  @schema [
    %{
      table: "customers",
      columns: [
        %{name: "customer_id", type: "INTEGER", null: "NO", pk: true},
        %{name: "email", type: "VARCHAR", null: "NO"},
        %{name: "active", type: "BOOLEAN", null: "YES"}
      ]
    },
    %{
      table: "orders",
      columns: [
        %{name: "order_id", type: "BIGINT", null: "NO", pk: true},
        %{name: "customer_id", type: "INTEGER", null: "NO"},
        %{name: "memo", type: "TEXT", null: "YES"}
      ]
    },
    %{
      table: "order_items",
      columns: [
        %{name: "item_id", type: "INTEGER", null: "NO", pk: true},
        %{name: "order_id", type: "BIGINT", null: "NO"},
        %{name: "quantity", type: "SMALLINT", null: "NO"},
        %{name: "gift", type: "BOOLEAN", null: "YES"}
      ]
    }
  ]

  @ttl SqlShapeGen.generate(@schema)
  @shapes SqlShapeGen.parse(@ttl)

  describe "generation" do
    test "emits a NodeShape per table, parsed by the substrate parser" do
      assert MapSet.new(Map.keys(@shapes)) ==
               MapSet.new(["SqlCustomersShape", "SqlOrdersShape", "SqlOrderItemsShape"])

      for {_name, shape} <- @shapes do
        assert shape.closed
        assert String.contains?(shape.target_class, "https://ggen.io/ontology/smalt#sql_")
      end
    end

    test "datatype mapping: int family -> xsd:integer, varchar -> xsd:string, bool -> xsd:boolean" do
      customers = @shapes["SqlCustomersShape"]
      props = Map.new(customers.required, &{&1.path, &1})

      assert props["customer_id"].datatype == :integer
      assert props["email"].datatype == :string
      assert props["active"].datatype == :boolean
    end

    test "NOT NULL columns carry sh:minCount 1; NULLABLE columns carry none (KD-156)" do
      orders = @shapes["SqlOrdersShape"]
      props = Map.new(orders.required, &{&1.path, &1})

      assert props["order_id"].min_count == 1
      assert props["customer_id"].min_count == 1
      # nullable memo: no minimum
      assert props["memo"].min_count == 0
    end

    test "PK columns carry the identifier-pattern message" do
      items = @shapes["SqlOrderItemsShape"]
      props = Map.new(items.required, &{&1.path, &1})

      assert props["item_id"].message =~ "primary key identifier"
      assert props["order_id"].message =~ "NOT NULL column"
      assert props["gift"].message == nil
    end

    test "deterministic: identical schema -> byte-identical Turtle" do
      assert SqlShapeGen.generate(@schema) == @ttl
    end

    test "unsupported SQL type is a typed refusal, never silent widening" do
      assert_raise ArgumentError, ~r/no substrate sh:datatype for SQL type "DOUBLE"/, fn ->
        SqlShapeGen.datatype_for("DOUBLE")
      end

      assert_raise ArgumentError, ~r/no substrate sh:datatype/, fn ->
        SqlShapeGen.generate([
          %{table: "t", columns: [%{name: "x", type: "TIMESTAMP", null: "NO"}]}
        ])
      end
    end

    test "invalid table spec is a typed refusal" do
      assert_raise ArgumentError, ~r/invalid table spec/, fn ->
        SqlShapeGen.generate([%{bogus: true}])
      end
    end
  end

  describe "governance court: the generated shapes govern ingested rows" do
    test "conforming row passes its table's shape" do
      row = %{
        "item_id" => 1,
        "order_id" => 100,
        "quantity" => 3,
        "gift" => false
      }

      assert Validator.validate_shape(@shapes["SqlOrderItemsShape"], row) == {:ok}
    end

    test "conforming row may omit nullable columns" do
      row = %{"item_id" => 2, "order_id" => 100, "quantity" => 1}
      assert Validator.validate_shape(@shapes["SqlOrderItemsShape"], row) == {:ok}
    end

    test "NULL in NOT NULL column refuses (minCount)" do
      row = %{"item_id" => 3, "quantity" => 2}

      assert {:invalid, violations} =
               Validator.validate_shape(@shapes["SqlOrderItemsShape"], row)

      assert [%{path: "order_id", constraint: "minCount"}] = violations
    end

    test "string in int column refuses (datatype)" do
      row = %{"item_id" => 4, "order_id" => 100, "quantity" => "many"}

      assert {:invalid, violations} =
               Validator.validate_shape(@shapes["SqlOrderItemsShape"], row)

      assert [%{path: "quantity", constraint: "datatype"}] = violations
    end

    test "boolean column given int refuses (datatype)" do
      row = %{"item_id" => 5, "order_id" => 100, "quantity" => 1, "gift" => 1}

      assert {:invalid, [%{path: "gift", constraint: "datatype"}]} =
               Validator.validate_shape(@shapes["SqlOrderItemsShape"], row)
    end

    test "unknown column refuses (closed shape: schema drift is admission failure)" do
      row = %{"item_id" => 6, "order_id" => 100, "quantity" => 1, "surprise" => "x"}

      assert {:invalid, violations} =
               Validator.validate_shape(@shapes["SqlOrderItemsShape"], row)

      assert Enum.any?(violations, &match?(%{path: "surprise", constraint: "closed"}, &1))
    end

    test "each table's shape governs its own rows end to end" do
      assert Validator.validate_shape(@shapes["SqlCustomersShape"], %{
               "customer_id" => 7,
               "email" => "a@b.c",
               "active" => true
             }) == {:ok}

      assert Validator.validate_shape(@shapes["SqlOrdersShape"], %{
               "order_id" => 200,
               "customer_id" => 7,
               "memo" => nil
             }) == {:ok}

      assert match?(
               {:invalid, _},
               Validator.validate_shape(@shapes["SqlCustomersShape"], %{
                 "customer_id" => "not-an-int",
                 "email" => "a@b.c"
               })
             )
    end
  end
end
