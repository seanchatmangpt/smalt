defmodule Smalt.GCP.CloudTasks do
  @moduledoc """
  Cloud Tasks v2 minimal engine (lane SM4). Wire-free. Queues and tasks in
  `:smalt_resources` under `gcp:tasks:`. `run_task/3` dispatches a task
  synchronously to a function entry point (`Smalt.GCP.Functions.run_handler/2`)
  named in `"functionEntryPoint"`; success deletes the task (as Cloud Tasks
  does), failure increments `dispatchCount`/`responseCount` and keeps it.

  Typed divergences: no scheduler, rate limits, or retry backoff; tasks run
  only when `run_task/3` or `drain/2` is called; HTTP targets are not sent.
  """

  alias Smalt.Store
  alias Smalt.GCP.Functions

  @table :smalt_resources

  defp qkey(p, l, q), do: "gcp:tasks:q:#{p}/#{l}/#{q}"
  defp tkey(p, l, q, t), do: "gcp:tasks:t:#{p}/#{l}/#{q}/#{t}"

  def create_queue(project, loc, id) do
    if match?({:ok, _}, Store.get(@table, qkey(project, loc, id))) do
      {:error, {409, "ALREADY_EXISTS", "queue #{id} already exists"}}
    else
      q = %{"name" => "projects/#{project}/locations/#{loc}/queues/#{id}", "state" => "RUNNING"}
      Store.put(@table, qkey(project, loc, id), q)
      {:ok, q}
    end
  end

  def get_queue(project, loc, id) do
    case Store.get(@table, qkey(project, loc, id)) do
      {:ok, q} -> {:ok, q}
      :error -> {:error, {404, "NOT_FOUND", "queue #{id} not found"}}
    end
  end

  def create_task(project, loc, queue, body) do
    with {:ok, q} <- get_queue(project, loc, queue) do
      tid = Map.get(body, "name") |> task_id()
      key = tkey(project, loc, queue, tid)

      if match?({:ok, _}, Store.get(@table, key)) do
        {:error, {409, "ALREADY_EXISTS", "task #{tid} already exists"}}
      else
        t = %{
          "name" => "#{q["name"]}/tasks/#{tid}",
          "functionEntryPoint" => body["functionEntryPoint"],
          "payload" => body["payload"],
          "dispatchCount" => 0,
          "responseCount" => 0,
          "createTime" => DateTime.to_iso8601(DateTime.utc_now())
        }

        Store.put(@table, key, t)
        {:ok, t}
      end
    end
  end

  def list_tasks(project, loc, queue),
    do: Store.list_prefix(@table, "gcp:tasks:t:#{project}/#{loc}/#{queue}/")

  def run_task(project, loc, queue, tid) do
    key = tkey(project, loc, queue, tid)

    case Store.get(@table, key) do
      :error ->
        {:error, {404, "NOT_FOUND", "task #{tid} not found"}}

      {:ok, t} ->
        res = Functions.run_handler(t["functionEntryPoint"], t["payload"])
        t = %{t | "dispatchCount" => t["dispatchCount"] + 1}

        if Map.has_key?(res, "error") do
          Store.put(@table, key, %{t | "responseCount" => t["responseCount"] + 1})
          {:ok, {:failed, res}}
        else
          Store.delete(@table, key)
          {:ok, {:done, res}}
        end
    end
  end

  def drain(project, loc, queue) do
    for tname <- task_ids(project, loc, queue), do: {tname, run_task(project, loc, queue, tname)}
  end

  defp task_ids(project, loc, queue) do
    prefix = "gcp:tasks:t:#{project}/#{loc}/#{queue}/"
    Store.keys(@table) |> Enum.filter(&String.starts_with?(&1, prefix)) |> Enum.map(&String.replace_prefix(&1, prefix, ""))
  end

  defp task_id(nil), do: "t-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
  defp task_id(n), do: n |> String.split("/") |> List.last()
end
