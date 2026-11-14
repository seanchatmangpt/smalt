defmodule Smalt.GCP.CloudTasksTest do
  use ExUnit.Case, async: false

  alias Smalt.GCP.CloudTasks

  defmodule Handlers do
    def ok(data), do: {:ok, data}
    def fail(_), do: {:error, :bad}
  end

  @h "Elixir.Smalt.GCP.CloudTasksTest.Handlers"

  defp uniq, do: "p#{System.unique_integer([:positive])}"

  test "queue create/get with typed errors" do
    p = uniq()
    assert {:ok, %{"state" => "RUNNING", "name" => n}} = CloudTasks.create_queue(p, "l", "q")
    assert n == "projects/#{p}/locations/l/queues/q"
    assert {:error, {409, "ALREADY_EXISTS", _}} = CloudTasks.create_queue(p, "l", "q")
    assert {:ok, %{"name" => ^n}} = CloudTasks.get_queue(p, "l", "q")
    assert {:error, {404, "NOT_FOUND", _}} = CloudTasks.get_queue(p, "l", "none")
  end

  test "create_task, list_tasks, duplicate, missing queue" do
    p = uniq()
    assert {:error, {404, _, _}} = CloudTasks.create_task(p, "l", "q", %{})
    {:ok, _} = CloudTasks.create_queue(p, "l", "q")
    body = %{"name" => "projects/x/locations/l/queues/q/tasks/t1", "functionEntryPoint" => "#{@h}.ok", "payload" => 1}
    assert {:ok, t} = CloudTasks.create_task(p, "l", "q", body)
    assert t["dispatchCount"] == 0 and String.ends_with?(t["name"], "/tasks/t1")
    assert {:error, {409, _, _}} = CloudTasks.create_task(p, "l", "q", body)
    assert {:ok, anon} = CloudTasks.create_task(p, "l", "q", %{"functionEntryPoint" => "#{@h}.ok"})
    assert anon["name"] =~ "/tasks/t-"
    assert length(CloudTasks.list_tasks(p, "l", "q")) == 2
  end

  test "run_task success deletes, failure keeps and counts, missing is 404" do
    p = uniq()
    {:ok, _} = CloudTasks.create_queue(p, "l", "q")
    {:ok, _} = CloudTasks.create_task(p, "l", "q", %{"name" => "good", "functionEntryPoint" => "#{@h}.ok", "payload" => 7})
    {:ok, _} = CloudTasks.create_task(p, "l", "q", %{"name" => "bad", "functionEntryPoint" => "#{@h}.fail"})
    assert {:ok, {:done, %{"result" => 7}}} = CloudTasks.run_task(p, "l", "q", "good")
    assert {:error, {404, _, _}} = CloudTasks.run_task(p, "l", "q", "good")
    assert {:ok, {:failed, %{"error" => ":bad"}}} = CloudTasks.run_task(p, "l", "q", "bad")
    [t] = CloudTasks.list_tasks(p, "l", "q")
    assert t["dispatchCount"] == 1 and t["responseCount"] == 1
  end

  test "drain runs every task in the queue" do
    p = uniq()
    {:ok, _} = CloudTasks.create_queue(p, "l", "q")
    {:ok, _} = CloudTasks.create_task(p, "l", "q", %{"name" => "a", "functionEntryPoint" => "#{@h}.ok"})
    {:ok, _} = CloudTasks.create_task(p, "l", "q", %{"name" => "b", "functionEntryPoint" => "#{@h}.fail"})
    res = CloudTasks.drain(p, "l", "q") |> Map.new()
    assert match?({:ok, {:done, _}}, res["a"]) and match?({:ok, {:failed, _}}, res["b"])
    assert [%{"name" => n}] = CloudTasks.list_tasks(p, "l", "q")
    assert String.ends_with?(n, "/tasks/b")
  end
end
