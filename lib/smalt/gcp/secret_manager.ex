defmodule Smalt.GCP.SecretManager do
  @moduledoc """
  GCP Secret Manager REST v1 dialect. State lives in an Agent; `handle/4`
  maps (method, path, query, body) to `{status, json_map}`.
  Versions are monotonically numbered; payload is base64 on the wire.
  """

  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> Agent.start_link(fn -> %{} end)
      name -> Agent.start_link(fn -> %{} end, name: name)
    end
  end

  def handle(pid, method, path, query \\ %{}, body \\ %{}) do
    segs = path |> String.trim("/") |> String.split("/")
    segs = if hd(segs) == "v1", do: tl(segs), else: segs

    case {method, segs} do
      {"POST", ["projects", p, "secrets"]} -> create(pid, p, query["secretId"], body)
      {"GET", ["projects", p, "secrets"]} -> list(pid, p)
      {"GET", ["projects", p, "secrets", s]} -> get(pid, p, s)
      {"DELETE", ["projects", p, "secrets", s]} -> delete(pid, p, s)
      {"GET", ["projects", p, "secrets", s, "versions"]} -> list_versions(pid, p, s)
      {"GET", ["projects", p, "secrets", s, "versions", v]} -> get_version(pid, p, s, v)
      {"POST", ["projects", p, "secrets", s_act]} -> secret_action(pid, p, s_act, body)
      {"POST", ["projects", p, "secrets", s, "versions", v_act]} -> version_action(pid, p, s, v_act)
      _ -> err(404, "NOT_FOUND", "no such route")
    end
  end

  defp create(_pid, _p, nil, _), do: err(400, "INVALID_ARGUMENT", "secretId required")

  defp create(pid, p, id, body) do
    Agent.get_and_update(pid, fn st ->
      if Map.has_key?(st, {p, id}) do
        {err(409, "ALREADY_EXISTS", "secret exists"), st}
      else
        rec = %{labels: body["labels"] || %{}, versions: [], next: 1}
        {{200, secret_json(p, id, rec)}, Map.put(st, {p, id}, rec)}
      end
    end)
  end

  defp list(pid, p) do
    secrets =
      Agent.get(pid, & &1)
      |> Enum.filter(fn {{pp, _}, _} -> pp == p end)
      |> Enum.sort()
      |> Enum.map(fn {{_, id}, rec} -> secret_json(p, id, rec) end)

    {200, %{"secrets" => secrets}}
  end

  defp get(pid, p, s) do
    case Agent.get(pid, &Map.get(&1, {p, s})) do
      nil -> not_found(p, s)
      rec -> {200, secret_json(p, s, rec)}
    end
  end

  defp delete(pid, p, s) do
    Agent.get_and_update(pid, fn st ->
      if Map.has_key?(st, {p, s}), do: {{200, %{}}, Map.delete(st, {p, s})}, else: {not_found(p, s), st}
    end)
  end

  defp secret_action(pid, p, s_act, body) do
    case String.split(s_act, ":") do
      [s, "addVersion"] -> add_version(pid, p, s, body)
      _ -> err(404, "NOT_FOUND", "unknown action")
    end
  end

  defp add_version(pid, p, s, body) do
    with %{"data" => b64} <- body["payload"] || %{},
         {:ok, data} <- Base.decode64(b64) do
      Agent.get_and_update(pid, fn st ->
        case Map.get(st, {p, s}) do
          nil ->
            {not_found(p, s), st}

          rec ->
            n = rec.next
            v = %{n: n, state: "ENABLED", data: data, crc: :erlang.crc32(data)}
            rec = %{rec | versions: rec.versions ++ [v], next: n + 1}
            {{200, version_json(p, s, v)}, Map.put(st, {p, s}, rec)}
        end
      end)
    else
      _ -> err(400, "INVALID_ARGUMENT", "payload.data must be base64")
    end
  end

  defp list_versions(pid, p, s) do
    case Agent.get(pid, &Map.get(&1, {p, s})) do
      nil -> not_found(p, s)
      rec -> {200, %{"versions" => Enum.map(rec.versions, &version_json(p, s, &1)), "totalSize" => length(rec.versions)}}
    end
  end

  defp get_version(pid, p, s, v) do
    case find(pid, p, s, v) do
      {:ok, ver} -> {200, version_json(p, s, ver)}
      e -> e
    end
  end

  defp version_action(pid, p, s, v_act) do
    case String.split(v_act, ":") do
      [v, "access"] -> access(pid, p, s, v)
      [v, "disable"] -> transition(pid, p, s, v, "disable")
      [v, "enable"] -> transition(pid, p, s, v, "enable")
      [v, "destroy"] -> transition(pid, p, s, v, "destroy")
      _ -> err(404, "NOT_FOUND", "unknown action")
    end
  end

  defp access(pid, p, s, v) do
    case find(pid, p, s, v) do
      {:ok, %{state: "ENABLED"} = ver} ->
        {200,
         %{
           "name" => vname(p, s, ver.n),
           "payload" => %{"data" => Base.encode64(ver.data), "dataCrc32c" => to_string(ver.crc)}
         }}

      {:ok, ver} ->
        err(400, "FAILED_PRECONDITION", "Secret version #{vname(p, s, ver.n)} is in #{ver.state} state.")

      e ->
        e
    end
  end

  defp transition(pid, p, s, v, act) do
    Agent.get_and_update(pid, fn st ->
      with rec when not is_nil(rec) <- Map.get(st, {p, s}),
           {:ok, ver} <- resolve(rec, v) do
        case {act, ver.state} do
          {_, "DESTROYED"} ->
            {err(400, "FAILED_PRECONDITION", "version is destroyed"), st}

          _ ->
            new =
              case act do
                "disable" -> %{ver | state: "DISABLED"}
                "enable" -> %{ver | state: "ENABLED"}
                "destroy" -> %{ver | state: "DESTROYED", data: nil}
              end

            vs = Enum.map(rec.versions, fn x -> if x.n == ver.n, do: new, else: x end)
            {{200, version_json(p, s, new)}, Map.put(st, {p, s}, %{rec | versions: vs})}
        end
      else
        nil -> {not_found(p, s), st}
        :error -> {err(404, "NOT_FOUND", "version not found"), st}
      end
    end)
  end

  defp find(pid, p, s, v) do
    case Agent.get(pid, &Map.get(&1, {p, s})) do
      nil ->
        not_found(p, s)

      rec ->
        case resolve(rec, v) do
          {:ok, ver} -> {:ok, ver}
          :error -> err(404, "NOT_FOUND", "version not found")
        end
    end
  end

  defp resolve(rec, "latest") do
    case Enum.filter(rec.versions, &(&1.state == "ENABLED")) do
      [] -> :error
      l -> {:ok, List.last(l)}
    end
  end

  defp resolve(rec, v) do
    with {n, ""} <- Integer.parse(v), ver when not is_nil(ver) <- Enum.find(rec.versions, &(&1.n == n)) do
      {:ok, ver}
    else
      _ -> :error
    end
  end

  defp vname(p, s, n), do: "projects/#{p}/secrets/#{s}/versions/#{n}"
  defp version_json(p, s, v), do: %{"name" => vname(p, s, v.n), "state" => v.state}
  defp secret_json(p, id, rec), do: %{"name" => "projects/#{p}/secrets/#{id}", "labels" => rec.labels, "replication" => %{"automatic" => %{}}}
  defp not_found(p, s), do: err(404, "NOT_FOUND", "Secret [projects/#{p}/secrets/#{s}] not found")
  defp err(code, status, msg), do: {code, %{"error" => %{"code" => code, "status" => status, "message" => msg}}}
end
