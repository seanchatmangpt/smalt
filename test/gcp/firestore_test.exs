defmodule Smalt.GCP.FirestoreTest do
  # Chicago: real Smalt.Store (ETS), real Plug router, no mocks, no sleeps.
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  @router Smalt.GCP.Firestore.Router

  setup do
    n = make_ref() |> :erlang.ref_to_list() |> to_string() |> String.replace(~r/[^0-9]/, "")
    {:ok, p: "proj-#{n}"}
  end

  defp call(method, path, body \\ nil) do
    conn = conn(method, path, body && Jason.encode!(body)) |> put_req_header("content-type", "application/json") |> Map.put(:host, "firestore.googleapis.com")
    conn = @router.call(conn, @router.init([]))
    {conn.status, Jason.decode!(conn.resp_body)}
  end

  defp base(p), do: "/projects/#{p}/databases/(default)/documents"
  defp s(v), do: %{"stringValue" => v}
  defp i(v), do: %{"integerValue" => to_string(v)}

  defp mk(p, coll, id, fields) do
    {200, d} = call(:post, "#{base(p)}/#{coll}?documentId=#{id}", %{"fields" => fields})
    d
  end

  test "create/get/delete lifecycle and 409/404", %{p: p} do
    d = mk(p, "users", "a", %{"n" => s("x")})
    assert d["createTime"] == d["updateTime"]
    assert {409, %{"error" => %{"status" => "ALREADY_EXISTS"}}} = call(:post, "#{base(p)}/users?documentId=a", %{"fields" => %{}})
    assert {200, %{"fields" => %{"n" => %{"stringValue" => "x"}}}} = call(:get, "#{base(p)}/users/a")
    assert {200, %{}} = call(:delete, "#{base(p)}/users/a")
    assert {404, %{"error" => %{"status" => "NOT_FOUND"}}} = call(:get, "#{base(p)}/users/a")
  end

  test "auto-id create and collection list", %{p: p} do
    {200, d} = call(:post, "#{base(p)}/things", %{"fields" => %{"k" => i(1)}})
    assert d["name"] =~ "/documents/things/"
    assert {200, %{"documents" => [_]}} = call(:get, "#{base(p)}/things")
  end

  test "patch: upsert, updateMask merge and field delete", %{p: p} do
    d = mk(p, "c", "d1", %{"a" => i(1), "b" => i(2)})
    {200, u} = call(:patch, "#{base(p)}/c/d1?updateMask.fieldPaths=a&updateMask.fieldPaths=b", %{"fields" => %{"a" => i(9)}})
    assert u["fields"] == %{"a" => i(9)}
    assert u["updateTime"] != d["updateTime"]
    assert u["createTime"] == d["createTime"]
    {200, up} = call(:patch, "#{base(p)}/c/new", %{"fields" => %{"z" => i(1)}})
    assert up["fields"] == %{"z" => i(1)}
  end

  test "preconditions: updateTime etag and exists", %{p: p} do
    d = mk(p, "c", "d", %{"v" => i(1)})
    stale = "2000-01-01T00:00:00.000000Z"
    assert {400, %{"error" => %{"status" => "FAILED_PRECONDITION"}}} =
             call(:patch, "#{base(p)}/c/d?currentDocument.updateTime=#{stale}", %{"fields" => %{}})
    assert {200, u} = call(:patch, "#{base(p)}/c/d?currentDocument.updateTime=#{d["updateTime"]}", %{"fields" => %{"v" => i(2)}})
    # old etag now dead
    assert {400, _} = call(:delete, "#{base(p)}/c/d?currentDocument.updateTime=#{d["updateTime"]}")
    assert {409, _} = call(:patch, "#{base(p)}/c/d?currentDocument.exists=false", %{"fields" => %{}})
    assert {404, _} = call(:patch, "#{base(p)}/c/ghost?currentDocument.exists=true", %{"fields" => %{}})
    assert {200, _} = call(:delete, "#{base(p)}/c/d?currentDocument.updateTime=#{u["updateTime"]}")
  end

  test "CAS race: N conditional patches on one etag yield exactly one winner", %{p: p} do
    d = mk(p, "r", "doc", %{"v" => i(0)})

    results =
      1..12
      |> Enum.map(fn n ->
        Task.async(fn ->
          call(:patch, "#{base(p)}/r/doc?currentDocument.updateTime=#{d["updateTime"]}", %{"fields" => %{"v" => i(n)}})
        end)
      end)
      |> Task.await_many(5000)

    assert Enum.count(results, &match?({200, _}, &1)) == 1
    assert Enum.count(results, &match?({400, _}, &1)) == 11
  end

  defp q(p, sq, parent \\ ""), do: call(:post, "#{base(p)}#{parent}:runQuery", %{"structuredQuery" => sq})
  defp names({200, rows}), do: for(%{"document" => %{"name" => n}} <- rows, do: n |> String.split("/") |> List.last())

  test "runQuery: filters, composite, order, offset/limit", %{p: p} do
    for {id, age, city} <- [{"a", 10, "x"}, {"b", 20, "y"}, {"c", 30, "x"}, {"d", 40, "y"}] do
      mk(p, "people", id, %{"age" => i(age), "city" => s(city)})
    end

    from = [%{"collectionId" => "people"}]
    f = fn field, op, v -> %{"fieldFilter" => %{"field" => %{"fieldPath" => field}, "op" => op, "value" => v}} end

    assert names(q(p, %{"from" => from, "where" => f.("city", "EQUAL", s("x")), "orderBy" => [%{"field" => %{"fieldPath" => "age"}, "direction" => "DESCENDING"}]})) == ["c", "a"]
    assert names(q(p, %{"from" => from, "where" => f.("age", "GREATER_THAN", i(15))})) == ["b", "c", "d"]
    assert names(q(p, %{"from" => from, "where" => %{"compositeFilter" => %{"op" => "AND", "filters" => [f.("city", "EQUAL", s("y")), f.("age", "LESS_THAN", i(40))]}}})) == ["b"]
    assert names(q(p, %{"from" => from, "where" => %{"compositeFilter" => %{"op" => "OR", "filters" => [f.("age", "EQUAL", i(10)), f.("age", "EQUAL", i(40))]}}})) == ["a", "d"]
    assert names(q(p, %{"from" => from, "orderBy" => [%{"field" => %{"fieldPath" => "age"}}], "offset" => 1, "limit" => 2})) == ["b", "c"]
    assert {200, [%{"readTime" => _}]} = q(p, %{"from" => [%{"collectionId" => "nothing"}]})
  end

  test "runQuery scopes to parent document subcollection", %{p: p} do
    mk(p, "o", "1", %{})
    {200, _} = call(:post, "#{base(p)}/o/1/items?documentId=i1", %{"fields" => %{}})
    assert names(q(p, %{"from" => [%{"collectionId" => "items"}]}, "/o/1")) == ["i1"]
    assert names(q(p, %{"from" => [%{"collectionId" => "items"}]}, "/o/2")) == []
  end

  test "commit is atomic: failing precondition applies nothing", %{p: p} do
    mk(p, "t", "keep", %{"v" => i(1)})
    n = fn id -> "projects/#{p}/databases/(default)/documents/t/#{id}" end

    bad = %{"writes" => [
      %{"update" => %{"name" => n.("new1"), "fields" => %{"v" => i(1)}}},
      %{"update" => %{"name" => n.("keep"), "fields" => %{}}, "currentDocument" => %{"exists" => false}}
    ]}

    assert {409, %{"error" => %{"status" => "ALREADY_EXISTS"}}} = call(:post, "#{base(p)}:commit", bad)
    assert {404, _} = call(:get, "#{base(p)}/t/new1")

    good = %{"writes" => [
      %{"update" => %{"name" => n.("new1"), "fields" => %{"v" => i(1)}}},
      %{"delete" => n.("keep")}
    ]}

    assert {200, %{"writeResults" => [%{"updateTime" => _}, %{}], "commitTime" => _}} = call(:post, "#{base(p)}:commit", good)
    assert {200, _} = call(:get, "#{base(p)}/t/new1")
    assert {404, _} = call(:get, "#{base(p)}/t/keep")
  end

  test "batchWrite is non-atomic with per-write status", %{p: p} do
    mk(p, "b", "exists", %{})
    n = fn id -> "projects/#{p}/databases/(default)/documents/b/#{id}" end

    {200, r} =
      call(:post, "#{base(p)}:batchWrite", %{"writes" => [
        %{"update" => %{"name" => n.("ok"), "fields" => %{}}},
        %{"update" => %{"name" => n.("exists"), "fields" => %{}}, "currentDocument" => %{"exists" => false}}
      ]})

    assert [%{}, %{"code" => 6}] = r["status"]
    assert {200, _} = call(:get, "#{base(p)}/b/ok")
  end

  test "transactions: read-set conflict aborts; clean commit succeeds; rollback", %{p: p} do
    mk(p, "x", "acct", %{"bal" => i(100)})
    n = "projects/#{p}/databases/(default)/documents/x/acct"
    db = "/projects/#{p}/databases/(default)/documents"

    {200, %{"transaction" => t1}} = call(:post, "#{db}:beginTransaction", %{})
    {200, _} = call(:get, "#{db}/x/acct?transaction=#{t1}")
    {200, _} = call(:patch, "#{db}/x/acct", %{"fields" => %{"bal" => i(5)}})

    assert {409, %{"error" => %{"status" => "ABORTED"}}} =
             call(:post, "#{db}:commit", %{"transaction" => t1, "writes" => [%{"update" => %{"name" => n, "fields" => %{"bal" => i(0)}}}]})

    {200, %{"fields" => %{"bal" => %{"integerValue" => "5"}}}} = call(:get, "#{db}/x/acct")

    {200, %{"transaction" => t2}} = call(:post, "#{db}:beginTransaction", %{})
    {200, _} = call(:get, "#{db}/x/acct?transaction=#{t2}")
    assert {200, _} = call(:post, "#{db}:commit", %{"transaction" => t2, "writes" => [%{"update" => %{"name" => n, "fields" => %{"bal" => i(6)}}}]})

    {200, %{"transaction" => t3}} = call(:post, "#{db}:beginTransaction", %{})
    assert {200, %{}} = call(:post, "#{db}:rollback", %{"transaction" => t3})
    assert {400, _} = call(:post, "#{db}:rollback", %{"transaction" => t3})
  end
end
