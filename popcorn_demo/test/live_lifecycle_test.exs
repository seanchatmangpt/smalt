# W5-K — Chicago-school live leg over the REAL smalt substrate (ARM control
# plane 9443, container-app lifecycle). No mocks: the test walks the real
# ARM face over real :httpc — STS mint, RG PUT, containerApp PUT (generic
# provider route, Registry-admitted type), GET echo, DELETE, GET-404.
#
# Context: solo (live substrate leg, host-side :httpc).

defmodule PopcornDemo.LiveLifecycleTest do
  use ExUnit.Case, async: false

  alias PopcornDemo.LiveLifecycle

  describe "run/0 full lifecycle over live substrate" do
    test "create → GET → delete → GET-404 returns OK" do
      assert {:ok, "lifecycle=OK(create:get:delete:get404:" <> _app} =
               LiveLifecycle.run()
    end
  end

  describe "real wire state" do
    test "created app echo-checks id/name/type on the wire" do
      app = unique_app()
      token = mint!()
      Process.put({LiveLifecycle, :token}, token)
      :ok = ensure_rg!()
      :ok = put_app!(app)

      {:ok, %{status: 200, body: record}} = get_raw(app)
      assert record["id"] == LiveLifecycle.ca_path(app)
      assert record["name"] == app
      assert record["type"] == LiveLifecycle.resource_type()

      # cleanup via the same wire
      {:ok, %{status: s}} = delete_raw(app)
      assert s in [200, 202]
    end

    test "deleted app answers 404 on a fresh GET (real-gone)" do
      app = unique_app()
      Process.put({LiveLifecycle, :token}, mint!())
      :ok = ensure_rg!()
      :ok = put_app!(app)
      {:ok, %{status: s}} = delete_raw(app)
      assert s in [200, 202]

      {:ok, %{status: 404}} = get_raw(app)
    end

    test "tokenless GET is refused 401 (enforce mode, KD-15 challenge shape)" do
      Process.delete({LiveLifecycle, :token})
      {:ok, %{status: 401}} = get_raw("l5k-tokenless-probe")
    end

    test "run/0 is repeatable (run-unique names, no cross-run collision)" do
      assert {:ok, _} = LiveLifecycle.run()
      assert {:ok, "lifecycle=OK(create:get:delete:get404:" <> app1} = LiveLifecycle.run()
      assert {:ok, "lifecycle=OK(create:get:delete:get404:" <> app2} = LiveLifecycle.run()
      assert app1 != app2
    end
  end

  # -- Real collaborator helpers (real :httpc against the live substrate) ----

  @base "http://127.0.0.1:9443"
  @tenant "00000000-0000-0000-0000-000000000000"
  @api "api-version=2023-05-01"
  @rg_base "/subscriptions/popcorn-rg-sub/resourceGroups/popcorn-rg"
  @ca_base "#{@rg_base}/providers/Microsoft.App/containerApps"

  defp unique_app do
    "l5kt" <>
      Integer.to_string(System.system_time(:millisecond)) <>
      "-" <> Integer.to_string(:erlang.unique_integer([:positive]))
  end

  defp mint! do
    body =
      "grant_type=client_credentials&client_id=x&client_secret=y" <>
        "&scope=https://management.azure.com/.default"

    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)
    repair_code_path()

    {:ok, {{_, 200, _}, _, body}} =
      :httpc.request(
        :post,
        {String.to_charlist("#{@base}/#{@tenant}/oauth2/v2.0/token"),
         [{'content-type', 'application/x-www-form-urlencoded'}],
         'application/x-www-form-urlencoded', body},
        [timeout: 10_000],
        body_format: :binary
      )

    %{"access_token" => tok} = Jason.decode!(body)
    tok
  end

  defp ensure_rg! do
    hdrs = auth_hdr() ++ [{'content-type', 'application/json'}]

    {:ok, {{_, s, _}, _, _}} =
      :httpc.request(
        :put,
        {String.to_charlist("#{@base}#{@rg_base}?#{@api}"), hdrs, 'application/json',
         ~s({"location":"eastus","properties":{}})},
        [timeout: 10_000],
        body_format: :binary
      )

    assert s in [200, 201]
    :ok
  end

  defp put_app!(app) do
    body =
      Jason.encode!(%{
        "location" => "eastus",
        "properties" => %{
          "environmentId" => "",
          "template" => %{"containers" => []},
          "configuration" => %{}
        }
      })

    {:ok, {{_, s, _}, _, _}} =
      :httpc.request(
        :put,
        {String.to_charlist("#{@base}#{@ca_base}/#{app}?#{@api}"),
         [
           {'authorization',
            'Bearer ' ++ String.to_charlist(Process.get({LiveLifecycle, :token}))},
           {'content-type', 'application/json'}
         ], 'application/json', body},
        [timeout: 10_000],
        body_format: :binary
      )

    assert s in [200, 201]
    :ok
  end

  defp get_raw(app) do
    tok = Process.get({LiveLifecycle, :token})
    hdrs = if tok, do: [{'authorization', 'Bearer ' ++ String.to_charlist(tok)}], else: []

    {:ok, {{_, s, _}, _, body}} =
      :httpc.request(
        :get,
        {String.to_charlist("#{@base}#{@ca_base}/#{app}?#{@api}"), hdrs},
        [timeout: 10_000],
        body_format: :binary
      )

    parsed = if body == "", do: %{}, else: Jason.decode!(body)
    {:ok, %{status: s, body: parsed}}
  end

  defp delete_raw(app) do
    tok = Process.get({LiveLifecycle, :token})

    {:ok, {{_, s, _}, _, _}} =
      :httpc.request(
        :delete,
        {String.to_charlist("#{@base}#{@ca_base}/#{app}?#{@api}"),
         [{'authorization', 'Bearer ' ++ String.to_charlist(tok)}]},
        [timeout: 10_000],
        body_format: :binary
      )

    {:ok, %{status: s}}
  end

  defp auth_hdr,
    do: [{'authorization', 'Bearer ' ++ String.to_charlist(Process.get({LiveLifecycle, :token}))}]

  defp repair_code_path do
    root = :code.root_dir() |> to_string()

    root
    |> then(&Path.wildcard(Path.join(&1, "lib/*/ebin")))
    |> Enum.each(&Code.append_path/1)
  end
end
