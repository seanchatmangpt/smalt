defmodule Smalt.AWS.DynamoDBTest do
  use ExUnit.Case, async: true
  alias Smalt.AWS.DynamoDB, as: D

  setup do
    t = "tbl_#{System.unique_integer([:positive])}"
    {200, _} = D.dispatch("CreateTable", %{"TableName" => t,
      "KeySchema" => [%{"AttributeName" => "pk", "KeyType" => "HASH"}, %{"AttributeName" => "sk", "KeyType" => "RANGE"}],
      "AttributeDefinitions" => [%{"AttributeName" => "pk", "AttributeType" => "S"}, %{"AttributeName" => "sk", "AttributeType" => "N"}]})
    on_exit(fn -> D.dispatch("DeleteTable", %{"TableName" => t}) end)
    {:ok, t: t}
  end

  defp s(v), do: %{"S" => v}
  defp n(v), do: %{"N" => to_string(v)}
  defp put(t, item, extra \\ %{}), do: D.dispatch("PutItem", Map.merge(%{"TableName" => t, "Item" => item}, extra))
  defp key(pk, sk), do: %{"pk" => s(pk), "sk" => n(sk)}

  test "create twice -> ResourceInUse; missing table -> ResourceNotFound; list/describe", %{t: t} do
    {400, %{"__type" => ty}} = D.dispatch("CreateTable", %{"TableName" => t, "KeySchema" => [%{"AttributeName" => "pk", "KeyType" => "HASH"}]})
    assert ty =~ "ResourceInUseException"
    {400, %{"__type" => ty}} = D.dispatch("GetItem", %{"TableName" => "nope_nope", "Key" => %{}})
    assert ty =~ "ResourceNotFoundException"
    assert t in elem(D.dispatch("ListTables", %{}), 1)["TableNames"]
    assert {200, %{"Table" => %{"TableStatus" => "ACTIVE"}}} = D.dispatch("DescribeTable", %{"TableName" => t})
  end

  test "put/get/delete roundtrip with ALL_OLD", %{t: t} do
    item = Map.merge(key("a", 1), %{"v" => s("x")})
    assert {200, %{}} = put(t, item)
    assert {200, %{"Item" => ^item}} = D.dispatch("GetItem", %{"TableName" => t, "Key" => key("a", 1)})
    assert {200, %{"Attributes" => ^item}} = D.dispatch("DeleteItem", %{"TableName" => t, "Key" => key("a", 1), "ReturnValues" => "ALL_OLD"})
    assert {200, %{}} = D.dispatch("GetItem", %{"TableName" => t, "Key" => key("a", 1)})
  end

  test "ConditionExpression: not_exists guards create, equality guards overwrite", %{t: t} do
    cond_new = %{"ConditionExpression" => "attribute_not_exists(pk)"}
    assert {200, _} = put(t, Map.put(key("a", 1), "v", n(1)), cond_new)
    assert {400, %{"__type" => ty}} = put(t, Map.put(key("a", 1), "v", n(2)), cond_new)
    assert ty =~ "ConditionalCheckFailedException"
    ok = %{"ConditionExpression" => "v = :cur AND #k >= :lo", "ExpressionAttributeNames" => %{"#k" => "v"}, "ExpressionAttributeValues" => %{":cur" => n(1), ":lo" => n(1)}}
    assert {200, _} = put(t, Map.put(key("a", 1), "v", n(5)), ok)
    assert {400, _} = put(t, Map.put(key("a", 1), "v", n(6)), ok)
    {200, %{"Item" => %{"v" => v}}} = D.dispatch("GetItem", %{"TableName" => t, "Key" => key("a", 1)})
    assert v == n(5)
  end

  test "UpdateItem SET/ADD/REMOVE/if_not_exists with upsert and ReturnValues", %{t: t} do
    upd = fn expr, vals, rv ->
      D.dispatch("UpdateItem", %{"TableName" => t, "Key" => key("u", 1), "UpdateExpression" => expr, "ExpressionAttributeValues" => vals, "ReturnValues" => rv})
    end
    assert {200, %{"Attributes" => a}} = upd.("SET c = if_not_exists(c, :z) + :one, tag = :t", %{":z" => n(0), ":one" => n(1), ":t" => s("a")}, "ALL_NEW")
    assert a["c"] == n(1) and a["tag"] == s("a") and a["pk"] == s("u")
    assert {200, %{"Attributes" => a}} = upd.("SET c = c + :one", %{":one" => n(1)}, "UPDATED_NEW")
    assert a == %{"c" => n(2)}
    assert {200, %{"Attributes" => a}} = upd.("ADD c :five REMOVE tag", %{":five" => n(5)}, "ALL_NEW")
    assert a["c"] == n(7) and not Map.has_key?(a, "tag")
  end

  test "concurrent conditional creates yield exactly one winner", %{t: t} do
    res =
      1..24
      |> Task.async_stream(fn i -> put(t, Map.put(key("race", 1), "who", n(i)), %{"ConditionExpression" => "attribute_not_exists(pk)"}) end, max_concurrency: 24)
      |> Enum.map(fn {:ok, {st, _}} -> st end)
    assert Enum.count(res, &(&1 == 200)) == 1
    assert Enum.count(res, &(&1 == 400)) == 23
  end

  test "if_not_exists inside arithmetic resolves fallback on missing attribute", %{t: t} do
    req = %{"TableName" => t, "Key" => key("ine", 1), "UpdateExpression" => "SET c = if_not_exists(c, :z) + :one, tag = :t", "ExpressionAttributeValues" => %{":z" => n(0), ":one" => n(1), ":t" => s("x")}}
    assert {200, _} = D.dispatch("UpdateItem", req)
    assert {200, _} = D.dispatch("UpdateItem", req)
    {200, %{"Item" => %{"c" => c}}} = D.dispatch("GetItem", %{"TableName" => t, "Key" => key("ine", 1)})
    assert c == n(2)
  end

  test "concurrent atomic counter increments lose nothing", %{t: t} do
    1..20
    |> Task.async_stream(fn _ -> D.dispatch("UpdateItem", %{"TableName" => t, "Key" => key("ctr", 1), "UpdateExpression" => "ADD c :one", "ExpressionAttributeValues" => %{":one" => n(1)}}) end, max_concurrency: 20)
    |> Enum.each(fn {:ok, {st, _}} -> assert st == 200 end)
    {200, %{"Item" => %{"c" => c}}} = D.dispatch("GetItem", %{"TableName" => t, "Key" => key("ctr", 1)})
    assert c == n(20)
  end

  test "Query by hash + range condition, order, limit, pagination, filter", %{t: t} do
    for i <- 1..6, do: put(t, Map.merge(key("p", i), %{"even" => %{"BOOL" => rem(i, 2) == 0}, "nm" => s("n#{i}")}))
    put(t, key("other", 1))
    q = fn extra -> D.dispatch("Query", Map.merge(%{"TableName" => t, "ExpressionAttributeValues" => %{":p" => s("p"), ":lo" => n(2), ":hi" => n(5)}}, extra)) end
    {200, %{"Items" => items, "Count" => 6}} = q.(%{"KeyConditionExpression" => "pk = :p"})
    assert Enum.map(items, & &1["sk"]["N"]) == ~w(1 2 3 4 5 6)
    {200, %{"Items" => items}} = q.(%{"KeyConditionExpression" => "pk = :p AND sk BETWEEN :lo AND :hi", "ScanIndexForward" => false})
    assert Enum.map(items, & &1["sk"]["N"]) == ~w(5 4 3 2)
    {200, %{"Items" => [%{"sk" => %{"N" => "1"}}, %{"sk" => %{"N" => "2"}}], "LastEvaluatedKey" => lek}} = q.(%{"KeyConditionExpression" => "pk = :p", "Limit" => 2})
    {200, %{"Items" => next}} = q.(%{"KeyConditionExpression" => "pk = :p", "Limit" => 2, "ExclusiveStartKey" => lek})
    assert Enum.map(next, & &1["sk"]["N"]) == ~w(3 4)
    {200, %{"Items" => f}} = q.(%{"KeyConditionExpression" => "pk = :p", "FilterExpression" => "begins_with(nm, :pre)", "ExpressionAttributeValues" => %{":p" => s("p"), ":pre" => s("n5")}})
    assert [%{"sk" => %{"N" => "5"}}] = f
    assert {200, %{"Count" => 7}} = D.dispatch("Scan", %{"TableName" => t, "Select" => "COUNT"})
  end

  test "TransactWriteItems is all-or-nothing", %{t: t} do
    put(t, Map.put(key("t", 1), "v", n(1)))
    ops = [
      %{"Put" => %{"TableName" => t, "Item" => key("t", 2)}},
      %{"ConditionCheck" => %{"TableName" => t, "Key" => key("t", 1), "ConditionExpression" => "v = :x", "ExpressionAttributeValues" => %{":x" => n(99)}}}
    ]
    {400, %{"__type" => ty, "CancellationReasons" => [%{"Code" => "None"}, %{"Code" => "ConditionalCheckFailed"}]}} = D.dispatch("TransactWriteItems", %{"TransactItems" => ops})
    assert ty =~ "TransactionCanceledException"
    assert {200, %{}} = D.dispatch("GetItem", %{"TableName" => t, "Key" => key("t", 2)})
    good = [hd(ops), %{"Delete" => %{"TableName" => t, "Key" => key("t", 1)}}]
    assert {200, %{}} = D.dispatch("TransactWriteItems", %{"TransactItems" => good})
    assert {200, %{"Item" => _}} = D.dispatch("GetItem", %{"TableName" => t, "Key" => key("t", 2)})
    assert {200, m} = D.dispatch("GetItem", %{"TableName" => t, "Key" => key("t", 1)})
    assert m == %{}
  end

  test "bad key shape and secondary indexes are typed ValidationException", %{t: t} do
    assert {400, %{"__type" => ty}} = D.dispatch("GetItem", %{"TableName" => t, "Key" => %{"pk" => s("a")}})
    assert ty =~ "ValidationException"
    assert {400, %{"message" => m}} = D.dispatch("Query", %{"TableName" => t, "IndexName" => "gsi", "KeyConditionExpression" => "pk = :p", "ExpressionAttributeValues" => %{":p" => s("a")}})
    assert m =~ "UNSUPPORTED"
  end
end
