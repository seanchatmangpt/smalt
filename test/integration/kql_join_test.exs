# Integration-tier witness (T-05 increment 2, v26.10.28): KQL join —
# `| join [kind=inner|left] <Table> on <Col>[ == <Col>]` over run/3's
# named-table map. Courts the DoD shape from the ticket:
# `AppRequests | join kind=inner AppDependencies on OperationId`.

defmodule Smalt.Internal.KqlJoinTest do
  use ExUnit.Case, async: true

  alias Smalt.DataPlane.KQL

  @requests [
    %{"OperationId" => "op-1", "ReqCol" => "r1", "Dur" => 10},
    %{"OperationId" => "op-2", "ReqCol" => "r2", "Dur" => 20},
    %{"OperationId" => "op-3", "ReqCol" => "r3", "Dur" => 30}
  ]

  @dependencies [
    %{"OperationId" => "op-1", "DepCol" => "d1", "Dur" => 1},
    %{"OperationId" => "op-1", "DepCol" => "d1b", "Dur" => 2},
    %{"OperationId" => "op-2", "DepCol" => "d2", "Dur" => 3}
  ]

  @tables %{"AppDependencies" => @dependencies}

  test "kind=inner on <Col>: merged rows, right wins collisions, _left survives" do
    assert {:ok, rows} =
             KQL.run(@requests, "| join kind=inner AppDependencies on OperationId", @tables)

    # 3 left rows: op-1 matches 2 right rows, op-2 matches 1, op-3 none -> 3 joined.
    assert length(rows) == 3

    by_dep =
      Map.new(rows, fn row -> {row["DepCol"], row} end)

    d1 = by_dep["d1"]
    # Collision on Dur: right value wins, left survives under Dur_left.
    assert d1["Dur"] == 1
    assert d1["Dur_left"] == 10
    assert d1["ReqCol"] == "r1"

    assert Map.has_key?(by_dep, "d1b")
    assert Map.has_key?(by_dep, "d2")
  end

  test "kind=left keeps unmatched left rows" do
    assert {:ok, rows} =
             KQL.run(@requests, "| join kind=left AppDependencies on OperationId", @tables)

    # 3 joined + op-3 unmatched = 4.
    assert length(rows) == 4
    assert Enum.any?(rows, fn row -> row["ReqCol"] == "r3" and row["DepCol"] == nil end)
  end

  test "explicit == column form: on LeftCol == RightCol" do
    right = [
      %{"OpKey" => "op-1", "DepCol" => "d1"},
      %{"OpKey" => "op-9", "DepCol" => "d9"}
    ]

    tables = %{"Deps" => right}

    assert {:ok, rows} =
             KQL.run([hd(@requests)], "| join kind=inner Deps on OperationId == OpKey", tables)

    assert length(rows) == 1
    assert hd(rows)["DepCol"] == "d1"
  end

  test "datetime keys join across ISO-string and DateTime storage shapes" do
    left = [%{"TimeGenerated" => "2026-10-28T12:00:00Z", "Name" => "iso-row"}]

    right = [
      %{
        "TimeGenerated" => DateTime.from_unix!(1_793_188_800_000, :millisecond),
        "Right" => "dt-row"
      }
    ]

    assert {:ok, rows} = KQL.run(left, "| join kind=inner T on TimeGenerated", %{"T" => right})
    assert [%{"Right" => "dt-row"}] = rows
  end

  test "join composes downstream: summarize over joined rows" do
    assert {:ok, rows} =
             KQL.run(
               @requests,
               "| join kind=inner AppDependencies on OperationId | summarize count() by OperationId",
               @tables
             )

    counts = Map.new(rows, fn row -> {row["OperationId"], row["count_"]} end)
    assert counts == %{"op-1" => 2, "op-2" => 1}
  end

  test "default kind (no kind= word) is inner" do
    assert {:ok, rows} = KQL.run(@requests, "| join AppDependencies on OperationId", @tables)
    assert length(rows) == 3
  end

  # -- fail-closed ---------------------------------------------------------------

  test "missing table in run/3 is a typed eval error" do
    assert {:error, {:eval, msg}} = KQL.run(@requests, "| join NoTable on OperationId", @tables)
    assert msg =~ "NoTable"
  end

  test "malformed join refuses SYN0002" do
    assert {:error, {:parse, msg}} = KQL.run(@requests, "| join on OperationId", @tables)
    assert msg =~ "SYN0002"

    assert {:error, {:parse, msg2}} =
             KQL.run(@requests, "| join kind=inner AppDependencies", @tables)

    assert msg2 =~ "SYN0002"
  end
end
