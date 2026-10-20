# C16 ERRC-RAISE lane (v26.10.19 window): Cosmos SQL subset raise — OFFSET/LIMIT
# pagination, TOP N, scalar function projections (UPPER/LOWER/LENGTH/CONTAINS)
# with mandatory AS alias, typed SYN errors, typed UNSUPPORTED for cross-array
# iteration. Chicago-style: real docs, assert on final state; no mocks.
defmodule DataPlane.CosmosSqlRaiseTest do
  use ExUnit.Case, async: false

  alias Smalt.CosmosSql

  defp docs do
    for i <- 1..6 do
      %{
        "id" => "d#{i}",
        "n" => i,
        "level" => if(rem(i, 2) == 0, do: "warn", else: "info"),
        "tags" => ["a", "b"]
      }
    end
  end

  # -- pagination ---------------------------------------------------------------

  test "witness: ORDER BY n OFFSET 2 LIMIT 2 returns the correct window" do
    assert {:ok, [%{"n" => 3}, %{"n" => 4}]} =
             CosmosSql.run("SELECT * FROM c ORDER BY c.n OFFSET 2 LIMIT 2", docs())
  end

  test "OFFSET 0 LIMIT n returns the head" do
    assert {:ok, [%{"n" => 1}, %{"n" => 2}]} =
             CosmosSql.run("SELECT * FROM c ORDER BY c.n OFFSET 0 LIMIT 2", docs())
  end

  test "OFFSET past the end returns an empty page" do
    assert {:ok, []} = CosmosSql.run("SELECT * FROM c ORDER BY c.n OFFSET 9 LIMIT 2", docs())
  end

  test "OFFSET without LIMIT is a typed syntax error" do
    assert {:error, {:syntax, "OFFSET requires a paired non-negative OFFSET <n> LIMIT <m>"}} =
             CosmosSql.run("SELECT * FROM c OFFSET 2", docs())
  end

  # -- TOP N --------------------------------------------------------------------

  test "witness: TOP 3 returns exactly the first three (post-sort) docs" do
    # DESC puts 6 first — TOP applies after the sort
    assert {:ok, [%{"n" => 6}, %{"n" => 5}, %{"n" => 4}]} =
             CosmosSql.run("SELECT TOP 3 * FROM c ORDER BY c.n DESC", docs())
  end

  test "TOP with a non-integer is a typed syntax error" do
    assert {:error, {:syntax, "TOP expects a positive integer"}} =
             CosmosSql.run("SELECT TOP x * FROM c", docs())
  end

  # -- scalar function projections ---------------------------------------------

  test "witness: UPPER projection with AS alias" do
    assert {:ok, rows} = CosmosSql.run("SELECT c.id, UPPER(c.level) AS lvl FROM c", docs())
    assert [%{"id" => "d1", "lvl" => "INFO"}] = Enum.filter(rows, &(&1["id"] == "d1"))
    assert [%{"id" => "d2", "lvl" => "WARN"}] = Enum.filter(rows, &(&1["id"] == "d2"))
    assert length(rows) == 6
  end

  test "LOWER + LENGTH projections" do
    assert {:ok, [%{"lo" => "info", "len" => 4}]} =
             CosmosSql.run(
               "SELECT LOWER(c.level) AS lo, LENGTH(c.level) AS len FROM c WHERE c.n = 5",
               docs()
             )
  end

  test "LENGTH over a list returns the element count" do
    assert {:ok, [%{"n" => 2}]} =
             CosmosSql.run("SELECT LENGTH(c.tags) AS n FROM c WHERE c.id = 'd2'", docs())
  end

  test "CONTAINS projection evaluates per document" do
    assert {:ok, [%{"has_inf" => true}]} =
             CosmosSql.run(
               "SELECT CONTAINS(c.level, 'inf') AS has_inf FROM c WHERE c.n = 1",
               docs()
             )
  end

  test "scalar fn over a non-applicable type omits the field (undefined)" do
    assert {:ok, [%{"id" => "d1"}]} =
             CosmosSql.run("SELECT c.id, UPPER(c.n) AS x FROM c WHERE c.n = 1", docs())
  end

  test "fn projection without AS is a typed syntax error" do
    assert {:error, {:syntax, "AS alias required after UPPER() projection" <> _}} =
             CosmosSql.run("SELECT UPPER(c.level) FROM c", docs())
  end

  test "unknown fn in projection is a typed syntax error" do
    assert {:error, {:syntax, "Unknown function in projection: FROBNICATE"}} =
             CosmosSql.run("SELECT FROBNICATE(c.level) AS x FROM c", docs())
  end

  # -- cross-array iteration: typed UNSUPPORTED ---------------------------------

  test "FROM t IN c.tags is typed-UNSUPPORTED, never a silent wrong answer" do
    assert {:error, {:unsupported, "FROM t IN ... (cross-array iteration) is not supported" <> _}} =
             CosmosSql.run("SELECT * FROM t IN c.tags", docs())
  end

  # -- regression: pre-raise grammar still parses -------------------------------

  test "pre-raise forms are unchanged (WHERE / IN / params / bare LIMIT)" do
    assert {:ok, rows} =
             CosmosSql.run("SELECT * FROM c WHERE c.n IN (1, 3) ORDER BY c.n LIMIT 2", docs())

    assert [%{"n" => 1}, %{"n" => 3}] = rows

    assert {:ok, [%{"n" => 5}, %{"n" => 6}]} =
             CosmosSql.run(
               "SELECT * FROM c WHERE c.n > @floor",
               docs(),
               %{"floor" => 4}
             )

    assert {:ok, [%{"n" => 6}]} =
             CosmosSql.run("SELECT * FROM c ORDER BY c.n DESC LIMIT 1", docs())
  end
end
