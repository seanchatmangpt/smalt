defmodule Smalt.GCP.Firestore do
  @moduledoc """
  Firestore (v1 REST) document engine on the Cosmos ETS/DETS store.

  Rows live in `:smalt_cosmos_docs` under tuple keys `{:gcp_firestore, project, path}`
  (Cosmos sweeps only touch binary keys, so the namespaces are disjoint). Value:
  `%{fields:, create_time:, update_time:}`. The wire `updateTime` IS the etag: preconditions
  compare it, and every write is one `Smalt.Store.compare_and_swap/4` /
  `insert_new/3` / `compare_and_swap_delete/3` so same-document races yield exactly one winner.

  Every function returns `{status, map}` (map is the JSON body). Transforms
  (`updateTransforms`) are UNSUPPORTED; query cursors (startAt/endAt) are UNSUPPORTED.
  """
  alias Smalt.Store

  @table :smalt_cosmos_docs
  @retries 8

  # ---------- keys / rendering ----------
  def key(project, path), do: {:gcp_firestore, project, path}
  defp txn_key(project, id), do: {:gcp_firestore_txn, project, id}

  def doc_name(project, path), do: "projects/#{project}/databases/(default)/documents/#{path}"

  def render(project, path, rec) do
    %{
      "name" => doc_name(project, path),
      "fields" => rec.fields,
      "createTime" => DateTime.to_iso8601(rec.create_time),
      "updateTime" => DateTime.to_iso8601(rec.update_time)
    }
  end

  def error(code, status, msg), do: {code, %{"error" => %{"code" => code, "message" => msg, "status" => status}}}

  defp fetch(project, path) do
    case Store.get(@table, key(project, path)) do
      {:ok, rec} -> rec
      :error -> nil
    end
  end

  defp next_time(nil), do: DateTime.utc_now(:microsecond)

  defp next_time(%{update_time: prev}) do
    now = DateTime.utc_now(:microsecond)
    if DateTime.compare(now, prev) == :gt, do: now, else: DateTime.add(prev, 1, :microsecond)
  end

  # ---------- reads ----------
  def get(project, path, txn \\ nil) do
    rec = fetch(project, path)
    track(project, txn, path, rec)

    case rec do
      nil -> error(404, "NOT_FOUND", "Document \"#{doc_name(project, path)}\" not found.")
      r -> {200, render(project, path, r)}
    end
  end

  def list(project, collection_path) do
    docs = children(project, collection_path) |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(fn {p, r} -> render(project, p, r) end)
    {200, if(docs == [], do: %{}, else: %{"documents" => docs})}
  end

  defp all_docs(project) do
    :ets.match_object(@table, {{:gcp_firestore, project, :_}, :_}) |> Enum.map(fn {{_, _, p}, r} -> {p, r} end)
  end

  defp children(project, coll_path) do
    prefix = coll_path <> "/"

    Enum.filter(all_docs(project), fn {p, _} ->
      String.starts_with?(p, prefix) and not String.contains?(binary_part(p, byte_size(prefix), byte_size(p) - byte_size(prefix)), "/")
    end)
  end

  # ---------- create ----------
  def create(project, collection_path, doc_id, body) do
    id = doc_id || gen_id()
    path = collection_path <> "/" <> id
    now = DateTime.utc_now(:microsecond)
    rec = %{fields: Map.get(body, "fields", %{}), create_time: now, update_time: now}

    case Store.insert_new(@table, key(project, path), rec) do
      :ok -> {200, render(project, path, rec)}
      {:error, :exists} -> error(409, "ALREADY_EXISTS", "Document already exists: #{doc_name(project, path)}")
    end
  end

  defp gen_id, do: :crypto.strong_rand_bytes(15) |> Base.url_encode64(padding: false) |> String.replace(~r/[-_]/, "a")

  # ---------- single write (patch/delete) ----------
  @doc "pre: `%{update_time: iso | nil, exists: bool | nil}`; mask: list of field paths or nil."
  def patch(project, path, body, mask, pre) do
    case apply_write(project, path, {:update, Map.get(body, "fields", %{}), mask}, pre) do
      {:ok, rec} -> {200, render(project, path, rec)}
      {:error, e} -> e
    end
  end

  def delete(project, path, pre) do
    case apply_write(project, path, :delete, pre) do
      {:ok, _} -> {200, %{}}
      {:error, e} -> e
    end
  end

  defp apply_write(project, path, op, pre, n \\ @retries) do
    old = fetch(project, path)

    with :ok <- check_pre(project, path, old, pre),
         {:ok, new} <- plan(old, op) do
      case commit_one(project, path, old, new) do
        :ok -> {:ok, new}
        {:error, :conflict} when n > 0 -> apply_write(project, path, op, pre, n - 1)
        {:error, :conflict} -> {:error, error(409, "ABORTED", "Too much contention on #{path}.")}
      end
    else
      {:error, _} = e -> e
    end
  end

  defp check_pre(project, path, old, pre) do
    cond do
      pre[:exists] == true and old == nil ->
        {:error, error(404, "NOT_FOUND", "No document to update: #{doc_name(project, path)}")}

      pre[:exists] == false and old != nil ->
        {:error, error(409, "ALREADY_EXISTS", "Document already exists: #{doc_name(project, path)}")}

      pre[:update_time] != nil and (old == nil or DateTime.to_iso8601(old.update_time) != pre[:update_time]) ->
        {:error, error(400, "FAILED_PRECONDITION", "the stored version does not match the required base version")}

      true ->
        :ok
    end
  end

  # plan -> {:ok, new_rec | :delete}
  defp plan(nil, :delete), do: {:ok, :delete}
  defp plan(_old, :delete), do: {:ok, :delete}

  defp plan(old, {:update, fields, mask}) do
    t = next_time(old)
    base = if old, do: old.fields, else: %{}

    merged =
      case mask do
        nil -> fields
        paths -> Enum.reduce(paths, base, fn p, acc -> apply_mask_path(acc, String.split(p, "."), fields) end)
      end

    {:ok, %{fields: merged, create_time: if(old, do: old.create_time, else: t), update_time: t}}
  end

  defp apply_mask_path(acc, segs, src) do
    case get_path(src, segs) do
      {:ok, v} -> put_path(acc, segs, v)
      :error -> del_path(acc, segs)
    end
  end

  defp get_path(fields, [k]), do: Map.fetch(fields, k)

  defp get_path(fields, [k | rest]) do
    case fields do
      %{^k => %{"mapValue" => mv}} -> get_path(Map.get(mv, "fields", %{}), rest)
      _ -> :error
    end
  end

  defp put_path(fields, [k], v), do: Map.put(fields, k, v)

  defp put_path(fields, [k | rest], v) do
    inner =
      case fields do
        %{^k => %{"mapValue" => mv}} -> Map.get(mv, "fields", %{})
        _ -> %{}
      end

    Map.put(fields, k, %{"mapValue" => %{"fields" => put_path(inner, rest, v)}})
  end

  defp del_path(fields, [k]), do: Map.delete(fields, k)

  defp del_path(fields, [k | rest]) do
    case fields do
      %{^k => %{"mapValue" => mv}} ->
        Map.put(fields, k, %{"mapValue" => %{"fields" => del_path(Map.get(mv, "fields", %{}), rest)}})

      _ ->
        fields
    end
  end

  defp commit_one(project, path, nil, :delete), do: (_ = {project, path}; :ok)
  defp commit_one(project, path, nil, new), do: map_exists(Store.insert_new(@table, key(project, path), new))
  defp commit_one(project, path, old, :delete), do: Store.compare_and_swap_delete(@table, key(project, path), old)
  defp commit_one(project, path, old, new), do: Store.compare_and_swap(@table, key(project, path), old, new)
  defp map_exists({:error, :exists}), do: {:error, :conflict}
  defp map_exists(other), do: other

  # ---------- transactions ----------
  def begin_transaction(project) do
    id = :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
    Store.put(@table, txn_key(project, id), %{reads: %{}})
    {200, %{"transaction" => id}}
  end

  def rollback(project, id) do
    case Store.get(@table, txn_key(project, id)) do
      {:ok, _} ->
        Store.delete(@table, txn_key(project, id))
        {200, %{}}

      :error ->
        error(400, "INVALID_ARGUMENT", "Transaction not found.")
    end
  end

  defp track(_project, nil, _path, _rec), do: :ok

  defp track(project, txn, path, rec) do
    case Store.get(@table, txn_key(project, txn)) do
      {:ok, t} ->
        Store.put(@table, txn_key(project, txn), %{t | reads: Map.put_new(t.reads, path, rec && rec.update_time)})

      :error ->
        :ok
    end
  end

  defp validate_txn(_project, nil), do: :ok

  defp validate_txn(project, id) do
    case Store.get(@table, txn_key(project, id)) do
      :error ->
        {:error, error(400, "INVALID_ARGUMENT", "Transaction not found.")}

      {:ok, t} ->
        stale =
          Enum.any?(t.reads, fn {path, seen} ->
            cur = fetch(project, path)
            (cur && cur.update_time) != seen
          end)

        if stale, do: {:error, error(409, "ABORTED", "Transaction aborted: read set changed.")}, else: :ok
    end
  end

  # ---------- commit (atomic) / batchWrite ----------
  def commit(project, body) do
    writes = Map.get(body, "writes", [])
    txn = Map.get(body, "transaction")

    result =
      :global.trans({{:gcp_firestore_commit, project}, self()}, fn ->
        with :ok <- validate_txn(project, txn),
             {:ok, plans} <- plan_all(project, writes) do
          apply_all(project, plans)
        end
      end)

    case result do
      {:ok, results} ->
        if txn, do: Store.delete(@table, txn_key(project, txn))
        ct = DateTime.to_iso8601(DateTime.utc_now(:microsecond))
        {200, %{"writeResults" => results, "commitTime" => ct}}

      {:error, e} ->
        e
    end
  end

  def batch_write(project, body) do
    out =
      Enum.map(Map.get(body, "writes", []), fn w ->
        with {:ok, path, op, pre} <- parse_write(project, w), do: apply_write(project, path, op, pre)
      end)

    ct = DateTime.to_iso8601(DateTime.utc_now(:microsecond))

    {200,
     %{
       "writeResults" => Enum.map(out, &wr/1),
       "status" =>
         Enum.map(out, fn
           {:ok, _} -> %{}
           {:error, {code, %{"error" => e}}} -> %{"code" => grpc(code), "message" => e["message"]}
           {:error, e} -> %{"code" => 3, "message" => inspect(e)}
         end),
       "commitTime" => ct
     }}
  end

  defp grpc(404), do: 5
  defp grpc(409), do: 6
  defp grpc(400), do: 9
  defp grpc(_), do: 3

  defp wr({:ok, :delete}), do: %{}
  defp wr({:ok, %{update_time: t}}), do: %{"updateTime" => DateTime.to_iso8601(t)}
  defp wr(_), do: %{}

  defp parse_write(project, w) do
    pre = parse_pre(w["currentDocument"])

    cond do
      is_map(w["update"]) ->
        name = w["update"]["name"] || ""
        path = rel_path(project, name)
        mask = get_in(w, ["updateMask", "fieldPaths"])
        {:ok, path, {:update, w["update"]["fields"] || %{}, mask}, pre}

      is_binary(w["delete"]) ->
        {:ok, rel_path(project, w["delete"]), :delete, pre}

      true ->
        {:error, error(400, "INVALID_ARGUMENT", "Unsupported write (transform/verify unsupported).")}
    end
  end

  def parse_pre(nil), do: %{}
  def parse_pre(m), do: %{update_time: m["updateTime"], exists: m["exists"]}

  defp rel_path(project, name) do
    String.replace_prefix(name, "projects/#{project}/databases/(default)/documents/", "")
  end

  defp plan_all(project, writes) do
    Enum.reduce_while(writes, {:ok, []}, fn w, {:ok, acc} ->
      with {:ok, path, op, pre} <- parse_write(project, w),
           old = fetch(project, path),
           :ok <- check_pre(project, path, old, pre),
           {:ok, new} <- plan(old, op) do
        {:cont, {:ok, [{path, old, new} | acc]}}
      else
        {:error, _} = e -> {:halt, e}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      e -> e
    end
  end

  defp apply_all(project, plans) do
    Enum.reduce_while(plans, {[], []}, fn {path, old, new} = pl, {done, res} ->
      case commit_one(project, path, old, new) do
        :ok -> {:cont, {[pl | done], [wr({:ok, new}) | res]}}
        {:error, _} -> {:halt, {:abort, done}}
      end
    end)
    |> case do
      {:abort, done} ->
        Enum.each(done, fn {path, old, new} -> revert(project, path, old, new) end)
        {:error, error(409, "ABORTED", "Commit aborted by concurrent writer; rolled back.")}

      {_done, res} ->
        {:ok, Enum.reverse(res)}
    end
  end

  defp revert(project, path, old, new) do
    k = key(project, path)

    cond do
      old == nil and new == :delete -> :ok
      old == nil -> Store.compare_and_swap_delete(@table, k, new)
      new == :delete -> Store.insert_new(@table, k, old)
      true -> Store.compare_and_swap(@table, k, new, old)
    end
  end

  # ---------- runQuery ----------
  @doc "parent_path: \"\" for the documents root, else a document path."
  def run_query(project, parent_path, body) do
    sq_from = List.first((body["structuredQuery"] || %{})["from"] || [%{}]) || %{}

    if is_nil(sq_from["collectionId"]) and sq_from["allDescendants"] != true,
      do: error(400, "INVALID_ARGUMENT", "from.collectionId required"),
      else: do_run_query(project, parent_path, body)
  end

  defp do_run_query(project, parent_path, body) do
    sq = body["structuredQuery"] || %{}
    txn = body["transaction"]
    {:ok, sq_from} = {:ok, List.first(sq["from"] || [%{}])}
    coll = sq_from["collectionId"]
    all? = sq_from["allDescendants"] == true

    base = if parent_path == "", do: "", else: parent_path <> "/"

    docs =
      if all? do
        Enum.filter(all_docs(project), fn {p, _} ->
          String.starts_with?(p, base) and parent_coll(p) == coll
        end)
      else
        children(project, base <> coll)
      end

    docs = Enum.filter(docs, fn {_p, r} -> match_filter(sq["where"], r.fields) end)
    docs = order(docs, sq["orderBy"] || [])
    docs = docs |> Enum.drop(sq["offset"] || 0)
    docs = if sq["limit"], do: Enum.take(docs, limit_n(sq["limit"])), else: docs
    Enum.each(docs, fn {p, r} -> track(project, txn, p, r) end)
    rt = DateTime.to_iso8601(DateTime.utc_now(:microsecond))

    out =
      case docs do
        [] -> [%{"readTime" => rt}]
        _ -> Enum.map(docs, fn {p, r} -> %{"document" => render(project, p, project_fields(r, sq["select"], p)), "readTime" => rt} end)
      end

    {200, out}
  end

  defp limit_n(n) when is_integer(n), do: n
  defp limit_n(%{"value" => n}), do: n

  defp parent_coll(path) do
    case path |> String.split("/") |> Enum.reverse() do
      [_id, coll | _] -> coll
      _ -> nil
    end
  end

  defp project_fields(r, nil, _), do: r

  defp project_fields(r, %{"fields" => fs}, _) do
    keep = Enum.map(fs, & &1["fieldPath"])
    %{r | fields: Map.take(r.fields, keep)}
  end

  defp project_fields(r, _, _), do: r

  defp match_filter(nil, _), do: true

  defp match_filter(%{"compositeFilter" => %{"op" => op, "filters" => fs}}, fields) do
    case op do
      "OR" -> Enum.any?(fs, &match_filter(&1, fields))
      _ -> Enum.all?(fs, &match_filter(&1, fields))
    end
  end

  defp match_filter(%{"fieldFilter" => %{"field" => %{"fieldPath" => fp}, "op" => op, "value" => v}}, fields) do
    case field_value(fields, fp) do
      :error -> false
      {:ok, fv} -> cmp_op(op, fv, v)
    end
  end

  defp match_filter(%{"unaryFilter" => %{"field" => %{"fieldPath" => fp}, "op" => op}}, fields) do
    fv = field_value(fields, fp)

    case op do
      "IS_NULL" -> fv == {:ok, %{"nullValue" => nil}} or match?({:ok, %{"nullValue" => _}}, fv)
      "IS_NOT_NULL" -> match?({:ok, _}, fv) and not match?({:ok, %{"nullValue" => _}}, fv)
      _ -> false
    end
  end

  defp match_filter(_, _), do: true

  defp field_value(fields, fp), do: get_path(fields, String.split(fp, "."))

  defp cmp_op("EQUAL", a, b), do: compare(a, b) == :eq
  defp cmp_op("NOT_EQUAL", a, b), do: compare(a, b) != :eq
  defp cmp_op("LESS_THAN", a, b), do: same_rank?(a, b) and compare(a, b) == :lt
  defp cmp_op("LESS_THAN_OR_EQUAL", a, b), do: same_rank?(a, b) and compare(a, b) in [:lt, :eq]
  defp cmp_op("GREATER_THAN", a, b), do: same_rank?(a, b) and compare(a, b) == :gt
  defp cmp_op("GREATER_THAN_OR_EQUAL", a, b), do: same_rank?(a, b) and compare(a, b) in [:gt, :eq]

  defp cmp_op("ARRAY_CONTAINS", %{"arrayValue" => av}, b),
    do: Enum.any?(Map.get(av, "values", []), &(compare(&1, b) == :eq))

  defp cmp_op("IN", a, %{"arrayValue" => av}), do: Enum.any?(Map.get(av, "values", []), &(compare(a, &1) == :eq))
  defp cmp_op("NOT_IN", a, %{"arrayValue" => av}), do: not Enum.any?(Map.get(av, "values", []), &(compare(a, &1) == :eq))

  defp cmp_op("ARRAY_CONTAINS_ANY", %{"arrayValue" => av}, %{"arrayValue" => bv}) do
    bs = Map.get(bv, "values", [])
    Enum.any?(Map.get(av, "values", []), fn x -> Enum.any?(bs, &(compare(x, &1) == :eq)) end)
  end

  defp cmp_op(_, _, _), do: false

  defp same_rank?(a, b), do: rank(a) == rank(b)

  defp rank(%{"nullValue" => _}), do: 0
  defp rank(%{"booleanValue" => _}), do: 1
  defp rank(%{"integerValue" => _}), do: 2
  defp rank(%{"doubleValue" => _}), do: 2
  defp rank(%{"timestampValue" => _}), do: 3
  defp rank(%{"stringValue" => _}), do: 4
  defp rank(%{"bytesValue" => _}), do: 5
  defp rank(%{"referenceValue" => _}), do: 6
  defp rank(%{"geoPointValue" => _}), do: 7
  defp rank(%{"arrayValue" => _}), do: 8
  defp rank(%{"mapValue" => _}), do: 9
  defp rank(_), do: 10

  defp scalar(%{"integerValue" => i}), do: String.to_integer(to_string(i))
  defp scalar(%{"doubleValue" => d}), do: d
  defp scalar(%{"booleanValue" => b}), do: b
  defp scalar(%{"nullValue" => _}), do: 0
  defp scalar(%{"arrayValue" => av}), do: Enum.map(Map.get(av, "values", []), &scalar/1)
  defp scalar(%{"mapValue" => mv}), do: mv |> Map.get("fields", %{}) |> Enum.sort() |> Enum.map(fn {k, v} -> {k, scalar(v)} end)
  defp scalar(m), do: m |> Map.values() |> List.first()

  defp compare(a, b) do
    {ra, rb} = {rank(a), rank(b)}

    cond do
      ra < rb -> :lt
      ra > rb -> :gt
      true ->
        {x, y} = {scalar(a), scalar(b)}
        cond do
          x == y -> :eq
          x < y -> :lt
          true -> :gt
        end
    end
  end

  defp order(docs, []), do: Enum.sort_by(docs, &elem(&1, 0))

  defp order(docs, specs) do
    Enum.sort(docs, fn {pa, ra}, {pb, rb} ->
      Enum.reduce_while(specs, :eq, fn s, _ ->
        fp = s["field"]["fieldPath"]
        dir = s["direction"] || "ASCENDING"

        c =
          case {field_value(ra.fields, fp), field_value(rb.fields, fp)} do
            {{:ok, a}, {:ok, b}} -> compare(a, b)
            {:error, {:ok, _}} -> :lt
            {{:ok, _}, :error} -> :gt
            _ -> :eq
          end

        c = if dir == "DESCENDING", do: flip(c), else: c
        if c == :eq, do: {:cont, :eq}, else: {:halt, c}
      end)
      |> case do
        :lt -> true
        :gt -> false
        :eq -> pa <= pb
      end
    end)
  end

  defp flip(:lt), do: :gt
  defp flip(:gt), do: :lt
  defp flip(:eq), do: :eq
end
