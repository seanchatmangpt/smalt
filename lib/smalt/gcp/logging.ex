defmodule Smalt.GCP.Logging do
  @moduledoc """
  Cloud Logging v2 plane engine (GS6): `entries:write` / `entries:list`.
  Wire-free. Rows in `:smalt_resources` keyed
  `gcp:log:{project}/{ts_ns zero-padded}/{insertId}` (ordered => deterministic list).

  Filter subset (typed divergence, anything else => 400 INVALID_ARGUMENT):
  clauses joined by AND of `severity>=X`, `severity=X`, `logName="..."`,
  `resource.type="..."`, `textPayload:"substr"`. orderBy `timestamp asc|desc`.
  """

  alias Smalt.Store

  @table :smalt_resources
  @sev ~w(DEFAULT DEBUG INFO NOTICE WARNING ERROR CRITICAL ALERT EMERGENCY)

  def write_entries(%{"entries" => entries} = req) when is_list(entries) do
    base = Map.take(req, ["logName", "resource", "labels"])

    rows =
      Enum.map(entries, fn e ->
        e = Map.merge(base, e)
        project = project_of(e["logName"])
        sev = Map.get(e, "severity", "DEFAULT")

        cond do
          is_nil(project) -> {:error, "logName must be projects/{p}/logs/{id}"}
          sev not in @sev -> {:error, "invalid severity #{sev}"}
          true -> {:ok, project, normalize(e, sev)}
        end
      end)

    case Enum.find(rows, &match?({:error, _}, &1)) do
      {:error, m} ->
        {:error, {400, "INVALID_ARGUMENT", m}}

      nil ->
        Enum.each(rows, fn {:ok, p, e} ->
          Store.put(@table, "gcp:log:#{p}/#{pad(e["_ns"])}/#{e["insertId"]}", e)
        end)

        {:ok, %{}}
    end
  end

  def write_entries(_), do: {:error, {400, "INVALID_ARGUMENT", "entries required"}}

  def list_entries(%{"resourceNames" => names} = req) when is_list(names) do
    with {:ok, preds} <- parse_filter(Map.get(req, "filter", "")) do
      rows =
        names
        |> Enum.map(&String.replace_prefix(&1, "projects/", ""))
        |> Enum.flat_map(&Store.list_prefix(@table, "gcp:log:#{&1}/"))
        |> Enum.filter(fn e -> Enum.all?(preds, & &1.(e)) end)

      rows = if desc?(req), do: Enum.reverse(rows), else: rows
      size = Map.get(req, "pageSize", 1000)
      out = rows |> Enum.take(size) |> Enum.map(&Map.delete(&1, "_ns"))
      {:ok, %{"entries" => out}}
    end
  end

  def list_entries(_), do: {:error, {400, "INVALID_ARGUMENT", "resourceNames required"}}

  defp desc?(req), do: String.downcase(Map.get(req, "orderBy", "")) =~ "desc"

  defp normalize(e, sev) do
    ns = System.os_time(:nanosecond)
    id = e["insertId"] || "i" <> String.pad_leading(Integer.to_string(System.unique_integer([:positive, :monotonic])), 20, "0")

    e
    |> Map.put("severity", sev)
    |> Map.put("insertId", id)
    |> Map.put_new("timestamp", DateTime.utc_now() |> DateTime.to_iso8601())
    |> Map.put("receiveTimestamp", DateTime.utc_now() |> DateTime.to_iso8601())
    |> Map.put("_ns", ns)
  end

  defp project_of("projects/" <> rest) do
    case String.split(rest, "/logs/", parts: 2) do
      [p, l] when p != "" and l != "" -> p
      _ -> nil
    end
  end

  defp project_of(_), do: nil

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(20, "0")

  defp parse_filter(f) do
    f
    |> String.split(~r/\s+AND\s+/, trim: true)
    |> Enum.reduce_while({:ok, []}, fn c, {:ok, acc} ->
      case clause(String.trim(c)) do
        {:ok, p} -> {:cont, {:ok, [p | acc]}}
        :error -> {:halt, {:error, {400, "INVALID_ARGUMENT", "unsupported filter clause: #{c}"}}}
      end
    end)
  end

  defp clause(""), do: {:ok, fn _ -> true end}

  defp clause(c) do
    cond do
      m = Regex.run(~r/^severity\s*>=\s*(\w+)$/, c) ->
        sev_clause(m, fn a, b -> a >= b end)

      m = Regex.run(~r/^severity\s*=\s*(\w+)$/, c) ->
        sev_clause(m, fn a, b -> a == b end)

      m = Regex.run(~r/^logName\s*=\s*"([^"]*)"$/, c) ->
        {:ok, fn e -> e["logName"] == Enum.at(m, 1) end}

      m = Regex.run(~r/^resource\.type\s*=\s*"([^"]*)"$/, c) ->
        {:ok, fn e -> get_in(e, ["resource", "type"]) == Enum.at(m, 1) end}

      m = Regex.run(~r/^textPayload\s*:\s*"([^"]*)"$/, c) ->
        {:ok, fn e -> String.contains?(to_string(e["textPayload"]), Enum.at(m, 1)) end}

      true ->
        :error
    end
  end

  defp sev_clause([_, s], cmp) do
    case Enum.find_index(@sev, &(&1 == s)) do
      nil -> :error
      i -> {:ok, fn e -> cmp.(Enum.find_index(@sev, &(&1 == e["severity"])), i) end}
    end
  end
end
