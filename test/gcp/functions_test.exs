defmodule Smalt.GCP.FunctionsTest do
  use ExUnit.Case, async: false

  alias Smalt.GCP.{CloudRun, Functions}

  defmodule Handlers do
    def echo(data), do: {:ok, %{"echo" => data}}
    def fail(_), do: {:error, :nope}
    def boom(_), do: raise("kaput")
    def bare(data), do: data
  end

  @h "Elixir.Smalt.GCP.FunctionsTest.Handlers"

  defp uniq, do: "p#{System.unique_integer([:positive])}"

  test "create/get/list/delete with typed errors" do
    p = uniq()
    assert {:ok, f} = Functions.create_function(p, "l", "fn-a", %{"entryPoint" => "#{@h}.echo"})
    assert f["state"] == "ACTIVE" and f["name"] == "projects/#{p}/locations/l/functions/fn-a"
    assert {:error, {409, "ALREADY_EXISTS", _}} = Functions.create_function(p, "l", "fn-a", %{"entryPoint" => "x.y"})
    assert {:error, {400, "INVALID_ARGUMENT", _}} = Functions.create_function(p, "l", "Bad_Id", %{"entryPoint" => "x.y"})
    assert {:error, {400, "INVALID_ARGUMENT", _}} = Functions.create_function(p, "l", "fn-b", %{})
    assert {:ok, %{"entryPoint" => _}} = Functions.get_function(p, "l", "fn-a")
    assert {:error, {404, "NOT_FOUND", _}} = Functions.get_function(p, "l", "nope")
    assert length(Functions.list_functions(p, "l")) == 1
    assert {:ok, %{}} = Functions.delete_function(p, "l", "fn-a")
    assert {:error, {404, _, _}} = Functions.delete_function(p, "l", "fn-a")
    assert Functions.list_functions(p, "l") == []
  end

  test "call runs real handler: ok, error, raise, bare, unresolvable, missing fn" do
    p = uniq()

    for {id, fun} <- [{"e", "echo"}, {"f", "fail"}, {"r", "boom"}, {"b", "bare"}, {"u", "missing"}] do
      {:ok, _} = Functions.create_function(p, "l", id, %{"entryPoint" => "#{@h}.#{fun}"})
    end

    assert {:ok, %{"result" => %{"echo" => %{"a" => 1}}, "executionId" => "exec-" <> _}} =
             Functions.call(p, "l", "e", %{"a" => 1})

    assert {:ok, %{"error" => ":nope"}} = Functions.call(p, "l", "f", %{})
    assert {:ok, %{"error" => "kaput"}} = Functions.call(p, "l", "r", %{})
    assert {:ok, %{"result" => 5}} = Functions.call(p, "l", "b", 5)
    assert {:ok, %{"error" => "entry point" <> _}} = Functions.call(p, "l", "u", %{})
    assert {:error, {404, _, _}} = Functions.call(p, "l", "ghost", %{})
  end

  test "invoke_service requires an existing Run service" do
    p = uniq()
    assert {:error, {404, _, _}} = Functions.invoke_service(p, "l", "svc", "#{@h}.echo", 1)
    {:ok, _} = CloudRun.create_service(p, "l", "svc", %{})
    assert {:ok, %{"result" => %{"echo" => 1}}} = Functions.invoke_service(p, "l", "svc", "#{@h}.echo", 1)
  end
end
