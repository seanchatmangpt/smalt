defmodule Smalt.DataPlane.KQLTest do
  use ExUnit.Case, async: true

  alias Smalt.DataPlane.KQL

  @rows [
    %{
      "ledgerId" => "L-001",
      "tenantId" => "t-a",
      "subjectSha256" => "aa11",
      "eventId" => "e-1",
      "sha256Hash" => "f00d"
    },
    %{
      "ledgerId" => "L-002",
      "tenantId" => "t-b",
      "subjectSha256" => "bb22",
      "eventId" => "e-2",
      "sha256Hash" => "beef"
    },
    %{
      "ledgerId" => "L-003",
      "tenantId" => "t-a",
      "subjectSha256" => "cc33",
      "eventId" => "e-3",
      "sha256Hash" => "cafe"
    }
  ]

  defp ids({:ok, rows}), do: Enum.map(rows, & &1["ledgerId"])
  defp ids(other), do: other

  test "empty pipeline returns rows unchanged" do
    assert KQL.run(@rows, "") == {:ok, @rows}
  end

  test "where == filters" do
    assert KQL.run(@rows, "| where tenantId == 't-a'") |> ids() == ["L-001", "L-003"]
  end

  test "where != filters" do
    assert KQL.run(@rows, "| where tenantId != 't-a'") |> ids() == ["L-002"]
  end

  test "where contains" do
    rows = [%{"sha256Hash" => "deadbeef"}, %{"sha256Hash" => "cafe"}]
    assert KQL.run(rows, "| where sha256Hash contains 'dead'") == {:ok, [%{"sha256Hash" => "deadbeef"}]}
  end

  test "where startswith" do
    rows = [%{"eventId" => "evt-9"}, %{"eventId" => "log-1"}]
    assert KQL.run(rows, "| where eventId startswith 'evt'") == {:ok, [%{"eventId" => "evt-9"}]}
  end

  test "numeric comparisons" do
    rows = [%{"n" => "5"}, %{"n" => "10"}, %{"n" => "15"}]

    col = "n"

    assert KQL.run(rows, "| where n > 5") |> col_vals(col) == ["10", "15"]
    assert KQL.run(rows, "| where n <= 10") |> col_vals(col) == ["5", "10"]
    assert KQL.run(rows, "| where n >= 15") |> col_vals(col) == ["15"]
    assert KQL.run(rows, "| where n < 5") |> col_vals(col) == []
  end

  defp col_vals({:ok, rows}, col), do: Enum.map(rows, &Map.get(&1, col))
  defp col_vals(other, _col), do: other

  test "and / or / parens" do
    assert KQL.run(@rows, "| where tenantId == 't-a' and ledgerId == 'L-002'") |> ids() == []

    assert KQL.run(@rows, "| where tenantId == 't-b' or ledgerId == 'L-003'") |> ids() == [
             "L-002",
             "L-003"
           ]

    assert KQL.run(
             @rows,
             "| where (tenantId == 't-a' or tenantId == 't-b') and (eventId startswith 'e-')"
           )
           |> ids() == ["L-001", "L-002", "L-003"]

    # and binds tighter than or
    assert KQL.run(@rows, "| where tenantId == 't-b' or tenantId == 't-a' and ledgerId == 'L-001'")
           |> ids() == ["L-001", "L-002"]
  end

  test "order by asc and desc" do
    assert KQL.run(@rows, "| order by ledgerId asc") |> ids() == ["L-001", "L-002", "L-003"]
    assert KQL.run(@rows, "| order by ledgerId desc") |> ids() == ["L-003", "L-002", "L-001"]
  end

  test "order by defaults to asc" do
    assert KQL.run(@rows, "| order by ledgerId") |> ids() == ["L-001", "L-002", "L-003"]
  end

  test "project" do
    assert KQL.run(@rows, "| project ledgerId, tenantId") ==
             {:ok,
              [
                %{"ledgerId" => "L-001", "tenantId" => "t-a"},
                %{"ledgerId" => "L-002", "tenantId" => "t-b"},
                %{"ledgerId" => "L-003", "tenantId" => "t-a"}
              ]}
  end

  test "take" do
    assert KQL.run(@rows, "| take 2") |> ids() == ["L-001", "L-002"]
  end

  test "full pipeline" do
    query = """
    | where tenantId == 't-a' and sha256Hash contains 'a'
    | order by ledgerId desc
    | project ledgerId, subjectSha256
    | take 1
    """

    assert KQL.run(@rows, query) ==
             {:ok, [%{"ledgerId" => "L-003", "subjectSha256" => "cc33"}]}
  end

  test "take cap" do
    assert KQL.run(@rows, "| take 1001") ==
             {:error, {:limit, "take 1001 exceeds cap of 1000"}}

    assert KQL.run(@rows, "| take 1000") |> ids() == ["L-001", "L-002", "L-003"]
  end

  test "query length cap" do
    junk = String.duplicate("x", 2001)
    assert KQL.run(@rows, junk) == {:error, {:limit, "query length exceeds 2000"}}
  end

  test "AST depth cap" do
    # 21 chained `and` leaves -> tree depth 21 > 20
    leaf = "ledgerId == 'L-001'"
    pred = List.duplicate(leaf, 21) |> Enum.join(" and ")
    assert {:error, {:limit, "AST depth exceeds 20"}} = KQL.run(@rows, "| where " <> pred)
    # 20 is allowed
    pred20 = List.duplicate(leaf, 20) |> Enum.join(" and ")
    assert {:ok, _} = KQL.run(@rows, "| where " <> pred20)
  end

  test "malformed queries are parse errors" do
    for q <- [
          "| where",
          "| where ledgerId ==",
          "| where ledgerId == 'unterminated",
          "| where ledgerId foo 'x'",
          "| where (ledgerId == 'L-001'",
          "| frobnicate 3",
          "| take notanumber",
          "| take -1",
          "| order ledgerId asc",
          "| order by",
          "| project",
          "garbage",
          "| where ledgerId == 12ab"
        ] do
      assert {:error, {:parse, _}} = KQL.run(@rows, q), "expected parse error for #{inspect(q)}"
    end
  end

  test "missing column is false in predicates, empty string in sort" do
    rows = [%{"a" => "1"}, %{"a" => "2", "z" => "m"}]
    assert KQL.run(rows, "| where z == 'm'") == {:ok, [%{"a" => "2", "z" => "m"}]}
    # missing "z" sorts as "", which sorts before "m"
    assert KQL.run(rows, "| order by z") == {:ok, [%{"a" => "1"}, %{"a" => "2", "z" => "m"}]}
  end

  test "determinism: same input twice gives identical bytes" do
    query = "| where tenantId == 't-a' | order by ledgerId desc | project ledgerId, eventId"

    {:ok, r1} = KQL.run(@rows, query)
    {:ok, r2} = KQL.run(@rows, query)
    assert :erlang.term_to_binary(r1) == :erlang.term_to_binary(r2)
    assert Jason.encode!(r1) == Jason.encode!(r2)
  end

  test "invalid argument types" do
    assert {:error, {:parse, _}} = KQL.run(@rows, nil)
    assert {:error, {:parse, _}} = KQL.run(:not_a_list, "| take 1")
  end
end
