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

  # ---------------------------------------------------------------------------
  # Lens-8: conjunct-isolation follow-ups — the two survivors of the gate-clause
  # matrix, each closed by pinning the distinguishing input.
  # ---------------------------------------------------------------------------

  test "lens-8: length fence is byte_size — multibyte and invalid-UTF-8 queries are typed limit/parse errors, never crashes" do
    # 1001 two-byte chars = 2002 bytes > 2000-byte cap, but String.length sees
    # 1001 chars — byte_size is the load-bound fence; String.length would let
    # this through to the lexer (and on invalid UTF-8 would RAISE
    # UnicodeConversionError instead of returning a typed error).
    multibyte = String.duplicate("é", 1001)
    assert {:error, {:limit, _}} = KQL.run(@rows, "| where a == '" <> multibyte)

    invalid_utf8 = :binary.copy(<<0xFF>>, 2500)
    assert {:error, {:limit, _}} = KQL.run(@rows, invalid_utf8)
  end

  test "lens-8: contains/startswith on a missing column excludes the row (nil arm is load-bearing)" do
    rows = [%{"a" => "1"}]

    assert KQL.run(rows, "| where z contains 'm'") == {:ok, []}
    assert KQL.run(rows, "| where z startswith 'm'") == {:ok, []}
  end

  test "lens-8: backslash escape inside a string literal (\\' terminates cleanly, backslash dropped)" do
    rows = [%{"name" => "O'Brien"}]

    assert {:ok, [%{"name" => "O'Brien"}]} =
             KQL.run(rows, "| where name == 'O\\'Brien'")

    # unknown escape keeps the escaped byte, backslash dropped (lenient Kusto):
    # \q -> q, so the literal is "OqBrien" — matched against its own row.
    assert {:ok, [%{"name" => "OqBrien"}]} =
             KQL.run([%{"name" => "OqBrien"}], "| where name == 'O\\qBrien'")
  end

  test "lens-8: hostile-shape fuzz round — every result typed, zero crash channels" do
    rows = [%{"a" => "x", "b" => "y"}]

    hand_hostile = [
      "| where ((((a == 'x'))))",
      "| where (a == 'x'",
      "| where a == 'x')",
      "| where ()",
      "| where (())",
      "| where a == == 'x'",
      "| where a >= 1.2.3",
      "| where a == 'x' and",
      "| where and a == 'x'",
      "| where a == ",
      "| where a 'lit'",
      "| where 'lit' == 'lit'",
      "| where a == 'x' == 'y'",
      "| take",
      "| take +5",
      "| take 1e3",
      "| take 0x10",
      "| take 999999999999999999999999",
      "| take 5 5",
      "| take 5, 5",
      "| order by",
      "| order",
      "| order by a b c",
      "| order by a asc desc",
      "| order by , a",
      "| project ,",
      "| project a,",
      "| project a,,b",
      "| project ,,",
      "| project a, | take 1",
      "| where a == '",
      "| where a == \"",
      "| where a == '\\''",
      "| where a == \"it's\"",
      "| where a == 'it\"s'",
      "| where a == '\0'",
      String.duplicate("| where (", 30) <> "a == 'x'" <> String.duplicate(")", 30),
      String.duplicate("| where (a == 'x') or ", 40) <> "a == 'x'",
      "\x00| where a == 'x'",
      "\x01\x02\x03",
      "|\x00where a == 'x'",
      "| where \x00\xFF a == 'x'",
      "|" <> String.duplicate("a|", 1200),
      String.duplicate("| take 1|", 260),
      "||",
      "|||",
      "|,|,|",
      ")|(",
      "(|)",
      "|()()()"
    ]

    for q <- hand_hostile do
      result = KQL.run(rows, q)
      assert match?({:ok, _}, result) or match?({:error, {_, _}}, result),
             "untyped result for #{inspect(q)}: #{inspect(result)}"
    end

    # Seeded-random round: deterministic (same seed → same corpus).
    alphabet =
      Enum.concat([
        Enum.map(?a..?z, &<<&1>>),
        Enum.map(?0..?9, &<<&1>>),
        ["|", "where", "take", "order", "by", "project", "and", "or", "==", "!=",
         ">", "<", ">=", "<=", "contains", "startswith", "(", ")", ",", "'", "\"",
         "\\", " ", "asc", "desc", "\t", "\n", "\r", <<0xFF>>, <<0x00>>, "*", "-",
         "+", ".", "1e5", "0x", "'\\''", "''", "\"\""]
      ])

    :rand.seed(:exsss, {8, 15, 2026})

    for _i <- 1..500 do
      q = Enum.map_join(1..:rand.uniform(60), fn _ -> Enum.random(alphabet) end)
      result = KQL.run(rows, q)
      assert match?({:ok, _}, result) or match?({:error, {_, _}}, result),
             "untyped result for #{inspect(q)}: #{inspect(result)}"
    end
  end
end
