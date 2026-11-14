defmodule Smalt.AWS.DynamoDB do
  @moduledoc """
  DynamoDB (JSON 1.0, `X-Amz-Target: DynamoDB_20120810.<Op>`) engine on the Cosmos
  ETS/DETS store (AS2).

  Rows live in `:smalt_cosmos_docs` under tuple keys `{:aws_ddb, table, keyterm}` (items) and
  `{:aws_ddb_meta, table}` (table metadata); Cosmos sweeps touch binary keys only, so the
  namespaces are disjoint. Every write is one `Smalt.Store.insert_new/3` /
  `compare_and_swap/4` / `compare_and_swap_delete/3`, so ConditionExpression races yield
  exactly one winner (retry re-evaluates the condition on the fresh item).

  `dispatch/2` returns `{status, map}`. Supported: CreateTable, DeleteTable, DescribeTable,
  ListTables, PutItem, GetItem, UpdateItem (SET/REMOVE/ADD/DELETE, `if_not_exists`, `+`/`-`),
  DeleteItem, Query, Scan, TransactWriteItems, TransactGetItems. Condition/filter/key-condition
  subset: `= <> < <= > >=`, BETWEEN, IN, AND/OR/NOT, parentheses, `attribute_exists`,
  `attribute_not_exists`, `begins_with`, `contains`, `size`. UNSUPPORTED (typed
  ValidationException): secondary indexes, nested-path SET, list_append, streams, TTL.
  """
  alias Smalt.Store

  @table :smalt_cosmos_docs
  @retries 256
  @ns "com.amazonaws.dynamodb.v20120810#"

  # ---------- errors ----------
  def error(type, msg, status \\ 400), do: {status, %{"__type" => @ns <> type, "message" => msg}}

  defp validation(msg), do: throw({:ddb, "ValidationException", msg})

  # ---------- dispatch ----------
  def dispatch(op, p) when is_binary(op) and is_map(p) do
    run(op, p)
  catch
    {:ddb, type, msg} -> error(type, msg)
  end

  defp run("CreateTable", p), do: create_table(p)
  defp run("DeleteTable", p), do: delete_table(p)
  defp run("DescribeTable", p), do: describe_table(p)
  defp run("ListTables", _p), do: {200, %{"TableNames" => list_tables()}}
  defp run("PutItem", p), do: single(p, &plan_put/2, &ret_put/3)
  defp run("DeleteItem", p), do: single(p, &plan_delete/2, &ret_old/3)
  defp run("UpdateItem", p), do: single(p, &plan_update/2, &ret_update/3)
  defp run("GetItem", p), do: get_item(p)
  defp run("Query", p), do: query(p, true)
  defp run("Scan", p), do: query(p, false)
  defp run("TransactWriteItems", p), do: transact_write(p)
  defp run("TransactGetItems", p), do: transact_get(p)
  defp run(op, _), do: error("UnknownOperationException", "Unsupported operation #{op}")

  # ---------- tables ----------
  defp meta_key(t), do: {:aws_ddb_meta, t}

  defp meta(t) do
    case Store.get(@table, meta_key(t)) do
      {:ok, m} -> m
      :error -> throw({:ddb, "ResourceNotFoundException", "Requested resource not found"})
    end
  end

  defp tbl_name(p) do
    case p["TableName"] do
      n when is_binary(n) and byte_size(n) >= 3 -> n
      _ -> validation("TableName must be at least 3 characters long")
    end
  end

  defp create_table(p) do
    name = tbl_name(p)
    schema = p["KeySchema"] || validation("KeySchema is required")
    if Map.has_key?(p, "GlobalSecondaryIndexes") or Map.has_key?(p, "LocalSecondaryIndexes"),
      do: validation("UNSUPPORTED: secondary indexes")

    hash = for %{"KeyType" => "HASH", "AttributeName" => a} <- schema, do: a
    range = for %{"KeyType" => "RANGE", "AttributeName" => a} <- schema, do: a
    if length(hash) != 1 or length(range) > 1, do: validation("Invalid KeySchema")
    types = Map.new(p["AttributeDefinitions"] || [], &{&1["AttributeName"], &1["AttributeType"]})

    m = %{
      name: name,
      hash: hd(hash),
      range: List.first(range),
      attr_defs: types,
      created: System.os_time(:second)
    }

    case Store.insert_new(@table, meta_key(name), m) do
      :ok -> {200, %{"TableDescription" => describe(m)}}
      {:error, _} -> error("ResourceInUseException", "Table already exists: #{name}")
    end
  end

  defp describe(m) do
    ks = [%{"AttributeName" => m.hash, "KeyType" => "HASH"}] ++
           if(m.range, do: [%{"AttributeName" => m.range, "KeyType" => "RANGE"}], else: [])

    %{
      "TableName" => m.name,
      "TableStatus" => "ACTIVE",
      "KeySchema" => ks,
      "AttributeDefinitions" => for({a, t} <- m.attr_defs, do: %{"AttributeName" => a, "AttributeType" => t}),
      "CreationDateTime" => m.created * 1.0,
      "ItemCount" => length(items(m.name)),
      "TableArn" => "arn:aws:dynamodb:us-east-1:000000000000:table/#{m.name}"
    }
  end

  defp describe_table(p), do: {200, %{"Table" => describe(meta(tbl_name(p)))}}

  defp delete_table(p) do
    m = meta(tbl_name(p))
    d = describe(m)
    Enum.each(:ets.match_object(@table, {{:aws_ddb, m.name, :_}, :_}), fn {k, _} -> Store.delete(@table, k) end)
    Store.delete(@table, meta_key(m.name))
    {200, %{"TableDescription" => Map.put(d, "TableStatus", "DELETING")}}
  end

  defp list_tables do
    for({{:aws_ddb_meta, n}, _} <- :ets.match_object(@table, {{:aws_ddb_meta, :_}, :_}), do: n) |> Enum.sort()
  end

  defp items(t), do: for({{:aws_ddb, ^t, _}, v} <- :ets.match_object(@table, {{:aws_ddb, t, :_}, :_}), do: v)

  # ---------- keys ----------
  defp key_term(m, attrs) do
    h = attrs[m.hash] || validation("One of the required keys was not given a value")
    if m.range do
      r = attrs[m.range] || validation("One of the required keys was not given a value")
      {h, r}
    else
      h
    end
  end

  defp key_of(m, p_key) do
    expected = Enum.sort([m.hash | List.wrap(m.range)])
    if Enum.sort(Map.keys(p_key || %{})) != expected, do: validation("The provided key element does not match the schema")
    {:aws_ddb, m.name, key_term(m, p_key)}
  end

  defp key_attrs(m, item), do: Map.take(item, [m.hash | List.wrap(m.range)])

  defp fetch(k) do
    case Store.get(@table, k) do
      {:ok, i} -> i
      :error -> nil
    end
  end

  # ---------- single-item writes ----------
  # plan_*(p, ctx) -> {:ok, key, old, new | :delete | nil(noop), touched} | :cond_failed
  defp ctx(p) do
    %{names: p["ExpressionAttributeNames"] || %{}, values: p["ExpressionAttributeValues"] || %{}}
  end

  defp cond_ok?(p, old) do
    case p["ConditionExpression"] do
      nil -> true
      e -> e |> parse_expr(ctx(p)) |> ev(old || %{}) |> truthy()
    end
  end

  defp plan_put(p, _) do
    m = meta(tbl_name(p))
    item = p["Item"] || validation("Item is required")
    k = {:aws_ddb, m.name, key_term(m, item)}
    old = fetch(k)
    if cond_ok?(p, old), do: {:ok, k, old, item, nil}, else: :cond_failed
  end

  defp plan_delete(p, _) do
    m = meta(tbl_name(p))
    k = key_of(m, p["Key"])
    old = fetch(k)
    cond do
      not cond_ok?(p, old) -> :cond_failed
      old == nil -> {:ok, k, nil, nil, nil}
      true -> {:ok, k, old, :delete, nil}
    end
  end

  defp plan_update(p, _) do
    m = meta(tbl_name(p))
    k = key_of(m, p["Key"])
    old = fetch(k)

    if cond_ok?(p, old) do
      base = old || p["Key"]
      {new, touched} = apply_update(base, p["UpdateExpression"] || "", ctx(p))
      {:ok, k, old, new, touched}
    else
      :cond_failed
    end
  end

  defp plan_check(p, _) do
    m = meta(tbl_name(p))
    k = key_of(m, p["Key"])
    old = fetch(k)
    if cond_ok?(p, old), do: {:ok, k, old, old, nil}, else: :cond_failed
  end

  defp commit(_k, old, new) when old == new, do: :ok
  defp commit(k, nil, new), do: map_exists(Store.insert_new(@table, k, new))
  defp commit(k, old, :delete), do: Store.compare_and_swap_delete(@table, k, old)
  defp commit(k, old, new), do: Store.compare_and_swap(@table, k, old, new)

  defp map_exists({:error, :exists}), do: {:error, :conflict}
  defp map_exists(r), do: r

  defp single(p, planner, ret) do
    do_single(p, planner, ret, @retries)
  end

  defp do_single(_p, _planner, _ret, 0), do: error("ProvisionedThroughputExceededException", "contention")

  defp do_single(p, planner, ret, n) do
    case planner.(p, nil) do
      :cond_failed ->
        ccf(p)

      {:ok, k, old, new, touched} ->
        case commit(k, old, new) do
          :ok -> {200, ret.(p, {old, new, touched}, nil)}
          {:error, :conflict} -> do_single(p, planner, ret, n - 1)
        end
    end
  end

  defp ccf(p) do
    {st, body} = error("ConditionalCheckFailedException", "The conditional request failed")
    _ = p
    {st, body}
  end

  defp ret_put(p, {old, _new, _}, _), do: ret_old(p, {old, nil, nil}, nil)

  defp ret_old(p, {old, _, _}, _) do
    if p["ReturnValues"] == "ALL_OLD" and old, do: %{"Attributes" => old}, else: %{}
  end

  defp ret_update(p, {old, new, touched}, _) do
    case p["ReturnValues"] do
      "ALL_OLD" -> if old, do: %{"Attributes" => old}, else: %{}
      "ALL_NEW" -> %{"Attributes" => new}
      "UPDATED_NEW" -> %{"Attributes" => Map.take(new, touched)}
      "UPDATED_OLD" -> if old, do: %{"Attributes" => Map.take(old, touched)}, else: %{}
      _ -> %{}
    end
  end

  # ---------- reads ----------
  defp get_item(p) do
    m = meta(tbl_name(p))
    case fetch(key_of(m, p["Key"])) do
      nil -> {200, %{}}
      i -> {200, %{"Item" => i}}
    end
  end

  defp query(p, is_query) do
    m = meta(tbl_name(p))
    if p["IndexName"], do: validation("UNSUPPORTED: secondary indexes")
    c = ctx(p)
    kc = if is_query, do: p["KeyConditionExpression"] || validation("KeyConditionExpression is required")
    kast = kc && parse_expr(kc, c)
    fast = p["FilterExpression"] && parse_expr(p["FilterExpression"], c)
    fwd = Map.get(p, "ScanIndexForward", true)

    all =
      items(m.name)
      |> Enum.filter(fn i -> kast == nil or truthy(ev(kast, i)) end)
      |> Enum.sort_by(&sort_key(m, &1), &sort_le/2)

    all = if fwd, do: all, else: Enum.reverse(all)

    all =
      case p["ExclusiveStartKey"] do
        nil ->
          all

        esk ->
          Enum.drop_while(all, &(key_attrs(m, &1) != esk)) |> Enum.drop(1)
      end

    {page, more?} =
      case p["Limit"] do
        l when is_integer(l) and l > 0 -> {Enum.take(all, l), length(all) > l}
        _ -> {all, false}
      end

    matched = Enum.filter(page, fn i -> fast == nil or truthy(ev(fast, i)) end)
    proj = p["ProjectionExpression"]

    out =
      %{"Count" => length(matched), "ScannedCount" => length(page)}
      |> then(fn o ->
        if p["Select"] == "COUNT", do: o, else: Map.put(o, "Items", Enum.map(matched, &project(&1, proj, c)))
      end)
      |> then(fn o ->
        if more? and page != [], do: Map.put(o, "LastEvaluatedKey", key_attrs(m, List.last(page))), else: o
      end)

    {200, out}
  end

  defp project(item, nil, _), do: item

  defp project(item, expr, c) do
    names = expr |> String.split(",") |> Enum.map(&resolve_name(String.trim(&1), c))
    Map.take(item, names)
  end

  defp sort_key(m, i), do: {i[m.hash], m.range && i[m.range]}
  defp sort_le({h1, r1}, {h2, r2}), do: ord(h1, h2) == :lt or (ord(h1, h2) == :eq and ord(r1, r2) != :gt)

  # ---------- transactions ----------
  defp transact_write(p) do
    ops = p["TransactItems"] || validation("TransactItems is required")
    if ops == [] or length(ops) > 100, do: validation("TransactItems must contain 1..100 items")

    plans =
      for op <- ops do
        {kind, params} = Enum.find(op, fn {k, _} -> k in ~w(Put Update Delete ConditionCheck) end) || validation("Invalid TransactItem")
        planner = %{"Put" => &plan_put/2, "Update" => &plan_update/2, "Delete" => &plan_delete/2, "ConditionCheck" => &plan_check/2}[kind]
        planner.(params, nil)
      end

    keys = for {:ok, k, _, _, _} <- plans, do: k
    if length(keys) != length(Enum.uniq(keys)), do: validation("Transaction request cannot include multiple operations on one item")

    if Enum.any?(plans, &(&1 == :cond_failed)) do
      reasons = for pl <- plans, do: if(pl == :cond_failed, do: %{"Code" => "ConditionalCheckFailed", "Message" => "The conditional request failed"}, else: %{"Code" => "None"})
      cancelled(reasons)
    else
      case apply_all(for({:ok, k, o, n, _} <- plans, do: {k, o, n}), []) do
        :ok -> {200, %{}}
        :conflict -> cancelled(for _ <- plans, do: %{"Code" => "TransactionConflict", "Message" => "Transaction is ongoing for the item"})
      end
    end
  end

  defp cancelled(reasons) do
    codes = reasons |> Enum.map(& &1["Code"]) |> Enum.join(", ")
    {400, %{"__type" => @ns <> "TransactionCanceledException", "message" => "Transaction cancelled, please refer cancellation reasons for specific reasons [#{codes}]", "CancellationReasons" => reasons}}
  end

  defp apply_all([], _done), do: :ok

  defp apply_all([{k, o, n} = step | rest], done) do
    case commit(k, o, n) do
      :ok ->
        apply_all(rest, [step | done])

      {:error, :conflict} ->
        Enum.each(done, &undo/1)
        :conflict
    end
  end

  defp undo({_k, o, n}) when o == n, do: :ok
  defp undo({k, nil, new}), do: Store.compare_and_swap_delete(@table, k, new)
  defp undo({k, old, :delete}), do: Store.insert_new(@table, k, old)
  defp undo({k, old, new}), do: Store.compare_and_swap(@table, k, new, old)

  defp transact_get(p) do
    resp =
      for %{"Get" => g} <- p["TransactItems"] || [] do
        m = meta(tbl_name(g))
        case fetch(key_of(m, g["Key"])) do
          nil -> %{}
          i -> %{"Item" => i}
        end
      end

    {200, %{"Responses" => resp}}
  end

  # ---------- typed values ----------
  defp num(s) when is_binary(s) do
    case Integer.parse(s) do
      {i, ""} ->
        i

      _ ->
        case Float.parse(s) do
          {f, ""} -> f
          _ -> validation("Invalid number: #{s}")
        end
    end
  end

  defp fmt(n) when is_integer(n), do: Integer.to_string(n)
  defp fmt(n) when is_float(n), do: if(n == Float.round(n), do: Integer.to_string(trunc(n)), else: Float.to_string(n))

  def ord(nil, nil), do: :eq
  def ord(nil, _), do: :lt
  def ord(_, nil), do: :gt
  def ord(%{"N" => a}, %{"N" => b}), do: cmp3(num(a), num(b))
  def ord(%{"S" => a}, %{"S" => b}), do: cmp3(a, b)
  def ord(%{"B" => a}, %{"B" => b}), do: cmp3(a, b)
  def ord(_, _), do: :incomparable

  defp cmp3(a, b) when a < b, do: :lt
  defp cmp3(a, b) when a > b, do: :gt
  defp cmp3(_, _), do: :eq

  defp eq?(%{"N" => _} = a, %{"N" => _} = b), do: ord(a, b) == :eq
  defp eq?(a, b), do: a == b

  defp truthy(true), do: true
  defp truthy(_), do: false

  # ---------- expression parser ----------
  defp parse_expr(expr, c) do
    toks = Regex.scan(~r/<>|<=|>=|=|<|>|\(|\)|,|[#:]?[A-Za-z0-9_][A-Za-z0-9_.]*/, expr) |> Enum.map(&hd/1)
    {ast, rest} = p_or(toks, c)
    if rest != [], do: validation("Invalid expression near #{hd(rest)}")
    ast
  end

  defp kw?(tok, w), do: String.upcase(tok) == w

  defp p_or(t, c), do: p_and(t, c) |> or_rest(c)
  defp or_rest({l, [x | t]}, c) do
    if kw?(x, "OR") do
      {r, t2} = p_and(t, c)
      or_rest({{:or, l, r}, t2}, c)
    else
      {l, [x | t]}
    end
  end
  defp or_rest(r, _), do: r

  defp p_and(t, c), do: p_not(t, c) |> and_rest(c)
  defp and_rest({l, [x | t]}, c) do
    if kw?(x, "AND") do
      {r, t2} = p_not(t, c)
      and_rest({{:and, l, r}, t2}, c)
    else
      {l, [x | t]}
    end
  end
  defp and_rest(r, _), do: r

  defp p_not([x | t], c) do
    if kw?(x, "NOT") do
      {e, t2} = p_not(t, c)
      {{:not, e}, t2}
    else
      p_prim([x | t], c)
    end
  end
  defp p_not([], _), do: validation("Unexpected end of expression")

  defp p_prim(["(" | t], c) do
    {e, rest} = p_or(t, c)
    case rest do
      [")" | r] -> {e, r}
      _ -> validation("Missing )")
    end
  end

  defp p_prim([f, "(" | t], c) when f in ["attribute_exists", "attribute_not_exists", "begins_with", "contains"] do
    {args, rest} = p_args(t, c, [])
    {{:fn, f, args}, rest}
  end

  defp p_prim(t, c) do
    {a, rest} = p_operand(t, c)

    case rest do
      [op | r] when op in ["=", "<>", "<", "<=", ">", ">="] ->
        {b, r2} = p_operand(r, c)
        {{:cmp, op, a, b}, r2}

      [w | r] ->
        cond do
          kw?(w, "BETWEEN") ->
            {lo, [x | r2]} = p_operand(r, c)
            unless kw?(x, "AND"), do: validation("BETWEEN requires AND")
            {hi, r3} = p_operand(r2, c)
            {{:between, a, lo, hi}, r3}

          kw?(w, "IN") ->
            ["(" | r2] = r
            {args, r3} = p_args(r2, c, [])
            {{:in, a, args}, r3}

          true ->
            validation("Invalid expression near #{w}")
        end

      [] ->
        validation("Unexpected end of expression")
    end
  end

  defp p_args(t, c, acc) do
    {a, rest} = p_operand(t, c)

    case rest do
      ["," | r] -> p_args(r, c, [a | acc])
      [")" | r] -> {Enum.reverse([a | acc]), r}
      _ -> validation("Invalid function arguments")
    end
  end

  defp p_operand(["size", "(" | t], c) do
    {a, [")" | r]} = p_operand(t, c)
    {{:size, a}, r}
  end

  defp p_operand([":" <> _ = v | r], c) do
    case c.values[v] do
      nil -> validation("An expression attribute value used in expression is not defined; attribute value: #{v}")
      val -> {{:val, val}, r}
    end
  end

  defp p_operand([tok | r], c) when tok not in ["(", ")", ","], do: {{:path, tok |> String.split(".") |> Enum.map(&resolve_name(&1, c))}, r}
  defp p_operand(_, _), do: validation("Invalid operand")

  defp resolve_name("#" <> _ = n, c), do: c.names[n] || validation("An expression attribute name used in the document path is not defined; attribute name: #{n}")
  defp resolve_name(n, _), do: n

  # ---------- evaluator ----------
  defp ev({:and, a, b}, i), do: truthy(ev(a, i)) and truthy(ev(b, i))
  defp ev({:or, a, b}, i), do: truthy(ev(a, i)) or truthy(ev(b, i))
  defp ev({:not, a}, i), do: not truthy(ev(a, i))
  defp ev({:fn, "attribute_exists", [{:path, p}]}, i), do: get_path(i, p) != nil
  defp ev({:fn, "attribute_not_exists", [{:path, p}]}, i), do: get_path(i, p) == nil

  defp ev({:fn, "begins_with", [a, b]}, i) do
    case {val(a, i), val(b, i)} do
      {%{"S" => x}, %{"S" => y}} -> String.starts_with?(x, y)
      _ -> false
    end
  end

  defp ev({:fn, "contains", [a, b]}, i) do
    case {val(a, i), val(b, i)} do
      {%{"S" => x}, %{"S" => y}} -> String.contains?(x, y)
      {%{"SS" => l}, %{"S" => y}} -> y in l
      {%{"NS" => l}, %{"N" => y}} -> y in l
      {%{"L" => l}, y} -> Enum.any?(l, &eq?(&1, y))
      _ -> false
    end
  end

  defp ev({:cmp, "=", a, b}, i), do: both(val(a, i), val(b, i), &eq?/2)
  defp ev({:cmp, "<>", a, b}, i), do: not both(val(a, i), val(b, i), &eq?/2)

  defp ev({:cmp, op, a, b}, i) do
    o = ord(val(a, i), val(b, i))
    case op do
      "<" -> o == :lt
      "<=" -> o in [:lt, :eq]
      ">" -> o == :gt
      ">=" -> o in [:gt, :eq]
    end
  end

  defp ev({:between, a, lo, hi}, i) do
    x = val(a, i)
    ord(x, val(lo, i)) in [:gt, :eq] and ord(x, val(hi, i)) in [:lt, :eq]
  end

  defp ev({:in, a, args}, i), do: Enum.any?(args, &both(val(a, i), val(&1, i), fn x, y -> eq?(x, y) end))

  defp both(nil, _, _), do: false
  defp both(_, nil, _), do: false
  defp both(a, b, f), do: f.(a, b)

  defp val({:val, v}, _), do: v
  defp val({:path, p}, i), do: get_path(i, p)

  defp val({:size, a}, i) do
    case val(a, i) do
      %{"S" => s} -> %{"N" => Integer.to_string(String.length(s))}
      %{"B" => s} -> %{"N" => Integer.to_string(byte_size(s))}
      %{"L" => l} -> %{"N" => Integer.to_string(length(l))}
      %{"M" => m} -> %{"N" => Integer.to_string(map_size(m))}
      %{"SS" => l} -> %{"N" => Integer.to_string(length(l))}
      %{"NS" => l} -> %{"N" => Integer.to_string(length(l))}
      _ -> nil
    end
  end

  defp get_path(i, [n]), do: i[n]

  defp get_path(i, [n | rest]) do
    case i[n] do
      %{"M" => m} -> get_path(m, rest)
      _ -> nil
    end
  end

  # ---------- update expression ----------
  defp apply_update(item, "", _c), do: {item, []}

  defp apply_update(item, expr, c) do
    parts = Regex.split(~r/\b(SET|REMOVE|ADD|DELETE)\b/i, expr, include_captures: true, trim: true)
    if parts == [] or not (String.upcase(hd(parts)) in ~w(SET REMOVE ADD DELETE)), do: validation("Invalid UpdateExpression")

    parts
    |> Enum.chunk_every(2)
    |> Enum.reduce({item, []}, fn [clause, body], {it, touched} ->
      actions = split_top(body)

      Enum.reduce(actions, {it, touched}, fn a, {acc, t} ->
        {acc2, name} = do_action(String.upcase(clause), String.trim(a), acc, c)
        {acc2, [name | t]}
      end)
    end)
    |> then(fn {it, t} -> {it, Enum.uniq(t)} end)
  end

  defp split_top(s) do
    {cur, acc, _} =
      s
      |> String.graphemes()
      |> Enum.reduce({"", [], 0}, fn
        "(", {cur, acc, d} -> {cur <> "(", acc, d + 1}
        ")", {cur, acc, d} -> {cur <> ")", acc, d - 1}
        ",", {cur, acc, 0} -> {"", [cur | acc], 0}
        ch, {cur, acc, d} -> {cur <> ch, acc, d}
      end)

    Enum.reverse([cur | acc]) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end

  defp operand_val(tok, item, c) do
    tok = String.trim(tok)

    case tok do
      ":" <> _ -> c.values[tok] || validation("An expression attribute value used in expression is not defined; attribute value: #{tok}")
      _ -> item[resolve_name(tok, c)]
    end
  end

  defp eval_rhs(rhs, item, c) do
    rhs = String.trim(rhs)

    case split_arith(rhs) do
      {l, op, r} ->
        with %{"N" => x} <- eval_term(l, item, c), %{"N" => y} <- eval_term(r, item, c) do
          %{"N" => fmt(if(op == "+", do: num(x) + num(y), else: num(x) - num(y)))}
        else
          _ -> validation("An operand in the update expression has an incorrect data type")
        end

      nil ->
        eval_term(rhs, item, c) ||
          validation("The provided expression refers to an attribute that does not exist in the item")
    end
  end

  defp eval_term(tok, item, c) do
    tok = String.trim(tok)

    cond do
      m = Regex.run(~r/^if_not_exists\(\s*([^,\s]+)\s*,\s*([^)\s]+)\s*\)$/, tok) ->
        [_, p, d] = m
        operand_val(p, item, c) || operand_val(d, item, c)

      String.starts_with?(tok, "list_append") ->
        validation("UNSUPPORTED: list_append")

      true ->
        operand_val(tok, item, c)
    end
  end

  # Split at the first top-level (paren depth 0) " + " / " - " style operator.
  defp split_arith(s) do
    chars = String.graphemes(s)

    {_, idx} =
      Enum.reduce(Enum.with_index(chars), {0, nil}, fn
        {"(", _}, {d, i} -> {d + 1, i}
        {")", _}, {d, i} -> {d - 1, i}
        {ch, n}, {0, nil} when ch in ["+", "-"] and n > 0 -> {0, n}
        _, acc -> acc
      end)

    case idx do
      nil ->
        nil

      n ->
        {l, [op | r]} = Enum.split(chars, n)
        {Enum.join(l), op, Enum.join(r)}
    end
  end

  defp do_action("SET", a, item, c) do
    [_, target, rhs] = Regex.run(~r/^(\S+?)\s*=\s*(.+)$/s, a) || validation("Invalid UpdateExpression: bad SET action")
    if String.contains?(target, "."), do: validation("UNSUPPORTED: nested-path SET")
    name = resolve_name(target, c)
    rhs = String.trim(rhs)

    v = eval_rhs(rhs, item, c)

    {Map.put(item, name, v), name}
  end

  defp do_action("REMOVE", a, item, c) do
    name = resolve_name(a, c)
    {Map.delete(item, name), name}
  end

  defp do_action("ADD", a, item, c) do
    [p, v] = String.split(a, ~r/\s+/, parts: 2)
    name = resolve_name(p, c)
    add = operand_val(v, item, c)

    new =
      case {item[name], add} do
        {nil, x} -> x
        {%{"N" => x}, %{"N" => y}} -> %{"N" => fmt(num(x) + num(y))}
        {%{"SS" => x}, %{"SS" => y}} -> %{"SS" => Enum.uniq(x ++ y)}
        {%{"NS" => x}, %{"NS" => y}} -> %{"NS" => Enum.uniq(x ++ y)}
        _ -> validation("An operand in the update expression has an incorrect data type")
      end

    {Map.put(item, name, new), name}
  end

  defp do_action("DELETE", a, item, c) do
    [p, v] = String.split(a, ~r/\s+/, parts: 2)
    name = resolve_name(p, c)
    del = operand_val(v, item, c)

    new =
      case {item[name], del} do
        {%{"SS" => x}, %{"SS" => y}} -> %{"SS" => x -- y}
        {%{"NS" => x}, %{"NS" => y}} -> %{"NS" => x -- y}
        {nil, _} -> nil
        _ -> validation("An operand in the update expression has an incorrect data type")
      end

    {if(new, do: Map.put(item, name, new), else: item), name}
  end
end
