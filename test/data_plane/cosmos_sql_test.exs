defmodule Smalt.CosmosSqlTest do
  @moduledoc """
  Lane 523: wire tests + seeded fuzz for the 80/20 Cosmos SQL AST
  (GAP(cosmos-sql-translator-absent) closure).

  Chicago discipline: real collaborators — the evaluator runs against the
  real scanned doc set, the wire tests run through Cosmos.query_docs/4 on a
  real Store, and the fuzz oracle is a hand-written real Elixir filter over
  the same corpus (a real interface implementation, not a mock).
  """

  use ExUnit.Case, async: false
  use Plug.Test

  alias Smalt.CosmosSql
  alias Smalt.DataPlane.Cosmos
  alias Smalt.Store

  setup do
    case GenServer.start(Store, [], name: Store) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    Store.clear()
    assert Cosmos.store_ready?()
    :ok
  end

  defp corpus do
    [
      %{"id" => "d1", "name" => "alice", "age" => 30, "tags" => ["a", "b"],
        "addr" => %{"city" => "paris"}, "active" => true},
      %{"id" => "d2", "name" => "bob", "age" => 25, "nums" => [7], "tags" => ["b"],
        "addr" => %{"city" => "rome"}, "active" => false},
      %{"id" => "d3", "name" => "carol", "age" => 35, "tags" => [],
        "addr" => %{"city" => "oslo"}, "active" => true},
      %{"id" => "d4", "name" => "dan", "age" => 20, "tags" => ["c"],
        "addr" => %{"city" => "paris"}, "active" => false}
    ]
  end

  defp ids({:ok, out}), do: Enum.map(out, & &1["id"])
  defp ids({:error, {:syntax, msg}}), do: {:syntax_err, msg}

  defp runq(q, docs, params \\ %{}) do
    CosmosSql.run(q, docs, params)
  end

  # -- Evaluator grammar tests ----------------------------------------------

  describe "evaluator grammar" do
    test "star" do
      assert ids(runq("SELECT * FROM c", corpus())) == ["d1", "d2", "d3", "d4"]
    end

    test "projection subset keys by last segment, nested paths" do
      {:ok, out} = runq("SELECT c.name, c.addr.city FROM c", corpus())
      assert %{"name" => "alice", "city" => "paris"} in out
      assert %{"name" => "dan", "city" => "paris"} in out
    end

    test "projection omits missing fields (no null emission)" do
      assert runq("SELECT c.missing FROM c WHERE c.age = 25", corpus()) == {:ok, [%{}]}
    end

    test "WHERE equality, range, AND, OR, NOT" do
      assert ids(runq("SELECT * FROM c WHERE c.age = 30", corpus())) == ["d1"]
      assert ids(runq("SELECT * FROM c WHERE c.age > 20 AND c.age <= 30", corpus())) == ["d1", "d2"]
      assert ids(runq("SELECT * FROM c WHERE c.age < 25 OR c.age > 30", corpus())) == ["d3", "d4"]
      assert ids(runq("SELECT * FROM c WHERE NOT c.age < 30", corpus())) == ["d1", "d3"]
      assert ids(runq("SELECT * FROM c WHERE c.name != null", corpus())) == ["d1", "d2", "d3", "d4"]
    end

    test "IN, CONTAINS, STARTSWITH, ARRAY_CONTAINS" do
      assert ids(runq("SELECT * FROM c WHERE c.name IN ('alice', 'dan')", corpus())) == ["d1", "d4"]
      assert ids(runq("SELECT * FROM c WHERE CONTAINS(c.name, 'li')", corpus())) == ["d1"]
      assert ids(runq("SELECT * FROM c WHERE STARTSWITH(c.name, 'b')", corpus())) == ["d2"]
      assert ids(runq("SELECT * FROM c WHERE ARRAY_CONTAINS(c.tags, 'b')", corpus())) == ["d1", "d2"]
    end

    test "ORDER BY asc and desc, LIMIT" do
      assert ids(runq("SELECT * FROM c ORDER BY c.age ASC", corpus())) == ["d4", "d2", "d1", "d3"]
      assert ids(runq("SELECT * FROM c ORDER BY c.age DESC", corpus())) == ["d3", "d1", "d2", "d4"]
      assert ids(runq("SELECT * FROM c WHERE c.age > 0 LIMIT 2", corpus())) == ["d1", "d2"]
    end

    test "typed 400s: join, udf, aggregate, offset, unbound param" do
      assert {:error, {:syntax, _}} = runq("SELECT * FROM c JOIN x", corpus())
      assert {:error, {:syntax, _}} = runq("SELECT * FROM udf.x(c)", corpus())
      assert {:error, {:syntax, _}} = runq("SELECT COUNT(1) FROM c", corpus())
      assert {:error, {:syntax, _}} = runq("SELECT * FROM c OFFSET 1 LIMIT 1", corpus())
      assert {:error, {:syntax, "Unbound parameter(s): p"}} =
               runq("SELECT * FROM c WHERE c.age > @p", corpus())
    end
  end

  # -- Wire tests through Cosmos.query_docs/4 --------------------------------

  describe "wire: query_docs with the SQL evaluator" do
    test "WHERE equality over the real feed (cross-partition, no pk header)" do
      seed("wdb", "wc", [
        %{"id" => "a", "kind" => "x", "n" => 1},
        %{"id" => "b", "kind" => "y", "n" => 2},
        %{"id" => "c", "kind" => "x", "n" => 3}
      ])

      {:ok, 200, _, body} =
        Cosmos.query_docs("wdb", "wc", %{"query" => "SELECT * FROM c WHERE c.kind = 'x'"}, %{})

      assert body["_count"] == 2
      assert Enum.map(body["Documents"], & &1["id"]) == ["a", "c"]
    end

    test "WHERE range + ORDER BY + LIMIT over the wire" do
      seed("wdb2", "wc2", [
        %{"id" => "a", "n" => 3},
        %{"id" => "b", "n" => 1},
        %{"id" => "c", "n" => 2}
      ])

      {:ok, 200, _, body} =
        Cosmos.query_docs(
          "wdb2",
          "wc2",
          %{"query" => "SELECT c.id FROM c WHERE c.n >= 2 ORDER BY c.n DESC LIMIT 2"},
          %{}
        )

      assert Enum.map(body["Documents"], & &1["id"]) == ["a", "c"]
    end

    test "parameterized query with body parameters" do
      seed("wdb3", "wc3", [
        %{"id" => "a", "city" => "paris"},
        %{"id" => "b", "city" => "rome"}
      ])

      body_doc = %{
        "query" => "SELECT * FROM c WHERE c.city = @city",
        "parameters" => [%{"name" => "@city", "value" => "rome"}]
      }

      {:ok, 200, _, body} = Cosmos.query_docs("wdb3", "wc3", body_doc, %{})
      assert Enum.map(body["Documents"], & &1["id"]) == ["b"]
    end

    test "projection subset over the wire" do
      seed("wdb4", "wc4", [%{"id" => "a", "name" => "alice", "age" => 30}])

      {:ok, 200, _, body} =
        Cosmos.query_docs("wdb4", "wc4", %{"query" => "SELECT c.name FROM c"}, %{})

      assert body["Documents"] == [%{"name" => "alice"}]
    end

    test "ARRAY_CONTAINS over the wire" do
      seed("wdb5", "wc5", [
        %{"id" => "a", "tags" => ["t1"]},
        %{"id" => "b", "tags" => ["t2"]}
      ])

      {:ok, 200, _, body} =
        Cosmos.query_docs("wdb5", "wc5", %{"query" => "SELECT * FROM c WHERE ARRAY_CONTAINS(c.tags, 't2')"}, %{})

      assert Enum.map(body["Documents"], & &1["id"]) == ["b"]
    end

    test "out-of-grammar query is a typed 400 SyntaxError on the wire" do
      seed("wdb6", "wc6", [%{"id" => "a"}])

      for q <- [
            "SELECT * FROM c JOIN d",
            "SELECT COUNT(1) FROM c",
            "SELECT * FROM udf.strip(c)",
            "SELECT TOP 1 * FROM c"
          ] do
        {:ok, 400, _, err} = Cosmos.query_docs("wdb6", "wc6", %{"query" => q}, %{})
        assert err["code"] == "SyntaxError"
      end
    end

    test "whitelist fast path still scans SELECT * FROM c" do
      seed("wdb7", "wc7", [%{"id" => "a"}, %{"id" => "b"}])

      {:ok, 200, _, body} =
        Cosmos.query_docs("wdb7", "wc7", %{"query" => "SELECT * FROM c"}, %{})

      assert body["_count"] == 2
    end
  end

  defp seed(db, coll, docs) do
    Enum.each(docs, fn doc ->
      assert {:ok, 201, _, _} = Cosmos.create_doc(db, coll, doc, %{})
    end)
  end

  # -- Seeded fuzz: 100 random predicates vs a brute-force Elixir oracle ------

  describe "seeded fuzz vs brute-force oracle" do
    test "100 random WHERE predicates match the oracle exactly" do
      :rand.seed(:exsss, {523, 10, 16})

      for _ <- 1..100 do
        {sql, oracle} = pred(3)
        sql = "SELECT * FROM c WHERE " <> sql

        assert {:ok, out} = runq(sql, corpus()) |> unwrap_ok(),
               "seeded query failed to parse: " <> sql

        expected = corpus() |> Enum.filter(oracle) |> Enum.map(& &1["id"]) |> Enum.sort()
        assert Enum.sort(ids_ok(out)) == expected,
               "query: " <> sql <> " | got: " <> inspect(Enum.sort(ids_ok(out))) <> " | want: " <> inspect(expected)
      end
    end
  end

  defp unwrap_ok({:ok, _} = ok), do: ok
  defp unwrap_ok({:error, {:syntax, msg}}), do: flunk("syntax: " <> msg)

  defp ids_ok(out), do: Enum.map(out, & &1["id"])

  # Predicate generator: returns {sql_text, oracle_fn}.
  defp pred(0), do: leaf()

  defp pred(depth) do
    if :rand.uniform(3) == 1 do
      leaf()
    else
      case :rand.uniform(3) do
        1 ->
          {l, fl} = pred(depth - 1)
          {r, fr} = pred(depth - 1)
          {"(" <> l <> ") AND (" <> r <> ")", fn d -> fl.(d) and fr.(d) end}

        2 ->
          {l, fl} = pred(depth - 1)
          {r, fr} = pred(depth - 1)
          {"(" <> l <> ") OR (" <> r <> ")", fn d -> fl.(d) or fr.(d) end}

        _ ->
          {e, fe} = pred(depth - 1)
          {"NOT (" <> e <> ")", fn d -> not fe.(d) end}
      end
    end
  end

  # Field pickers: {sql_path, oracle_value_extractor}.
  defp field do
    Enum.random([
      {"c.age", fn d -> d["age"] end},
      {"c.name", fn d -> d["name"] end},
      {"c.addr.city", fn d -> d["addr"]["city"] end},
      {"c.active", fn d -> d["active"] end}
    ])
  end


  defp cmp_op do
    Enum.random([
      {"=", fn a, b -> a == b end},
      {"!=", fn a, b -> a != b end},
      {"<", fn a, b -> a < b end},
      {">", fn a, b -> a > b end},
      {"<=", fn a, b -> a <= b end},
      {">=", fn a, b -> a >= b end}
    ])
  end

  # Mirrors module semantics: undefined never matches; defined != null true.
  defp cmpv(nil, _, _), do: false

  defp cmpv(a, b, fun) do
    if (is_number(a) and is_number(b)) or (is_binary(a) and is_binary(b)) or
         (is_boolean(a) and is_boolean(b)) do
      fun.(a, b)
    else
      false
    end
  end

  defp leaf do
    case :rand.uniform(6) do
      1 ->
        {sym, fun} = cmp_op()
        v = :rand.uniform(45) + 5
        {"c.age " <> sym <> " " <> Integer.to_string(v), fn d -> cmpv(d["age"], v, fun) end}

      2 ->
        {sym, fun} = cmp_op()
        v = Enum.random(["alice", "bob", "carol", "dan", "zed"])

        if v == "zed" do
          {"c.name = 'zed'", fn d -> cmpv(d["name"], v, fn a, b -> a == b end) end}
        else
          {"c.name " <> sym <> " '" <> v <> "'", fn d -> cmpv(d["name"], v, fun) end}
        end

      3 ->
        {sym, fun} = cmp_op()
        v = Enum.random(["paris", "rome", "oslo", "lyon"])
        sql = "c.addr.city " <> sym <> " '" <> v <> "'"
        {sql, fn d -> cmpv(d["addr"]["city"], v, fun) end}

      4 ->
        v = Enum.random([true, false])
        {"c.active = " <> (v |> to_string() |> String.capitalize()), fn d -> cmpv(d["active"], v, fn a, b -> a == b end) end}

      5 ->
        names = Enum.take_random(["alice", "bob", "carol", "dan", "zed"], 2)
        quoted = Enum.map(names, &("'" <> &1 <> "'"))
        {"c.name IN (" <> Enum.join(quoted, ", ") <> ")", fn d -> d["name"] != nil and d["name"] in names end}

      _ ->
        v = Enum.random(["a", "b", "c", "zz"])
        {"ARRAY_CONTAINS(c.tags, '" <> v <> "')", fn d ->
           is_list(d["tags"]) and Enum.any?(d["tags"], fn x -> x === v end)
         end}
    end
  end

end
