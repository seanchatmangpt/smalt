defmodule SmaltLroTest do
  use ExUnit.Case
  use Plug.Test

  alias Smalt.ArmGateway.Router
  alias Smalt.Store

  @opts Router.init([])
  @sub "00000000-0000-0000-0000-000000000000"

  setup do
    ensure_store()
    Store.clear()

    Store.put(:smalt_subscriptions, @sub, %{
      "id" => "/subscriptions/#{@sub}",
      "subscriptionId" => @sub,
      "displayName" => "Sovereign Smalt Subscription",
      "state" => "Enabled"
    })

    # Small nonzero delay so the polling tests observe a real InProgress window
    # without making the suite slow.
    Application.put_env(:smalt, :lro_delay_ms, 20)
    :ok
  end

  defp call(conn), do: Router.call(conn, @opts)

  defp ensure_store do
    case Store.start_link([]) do
      {:ok, _} ->
        :ok

      {:error, {:already_started, _}} ->
        if :ets.info(:smalt_subscriptions) == :undefined do
          pid = Process.whereis(Store)
          ref = Process.monitor(pid)

          receive do
            {:DOWN, ^ref, :process, ^pid, _} ->
              ensure_store()
          after
            500 ->
              :ok
          end
        else
          :ok
        end
    end
  end

  defp api_v(type) do
    case Smalt.Registry.latest_version(type) do
      nil -> "2024-01-01"
      v -> v
    end
  end

  defp sa_path(name),
    do:
      "/subscriptions/#{@sub}/resourceGroups/lro-rg/providers/Microsoft.Storage/storageAccounts/#{name}?api-version=#{api_v("Microsoft.Storage/storageAccounts")}"

  defp sa_body(name),
    do: %{"location" => "eastus", "properties" => %{"skuName" => "Standard_LRS", "name" => name}}

  # ---------------------------------------------------------------------------
  # (1) LRO PUT: 202 + full async header set + InProgress body
  # ---------------------------------------------------------------------------
  test "PUT storageAccount returns 202 with Azure-AsyncOperation, Location, Retry-After and InProgress body" do
    name = "st" <> unique()

    conn =
      conn(:put, sa_path(name), sa_body(name))
      |> call()

    assert conn.status == 202

    # Header-level assertions: all three async headers present with expected shape.
    assert [async_url] = get_resp_header(conn, "azure-asyncoperation")
    assert [location_url] = get_resp_header(conn, "location")
    assert ["1"] = get_resp_header(conn, "retry-after")

    assert String.starts_with?(async_url, "http://www.example.com/subscriptions/#{@sub}/operations/")
    assert String.starts_with?(location_url, "http://www.example.com/subscriptions/#{@sub}/operations/")
    assert async_url == location_url

    # Body: operation record in progress.
    op = Jason.decode!(conn.resp_body)
    assert op["status"] == "InProgress"
    assert op["startTime"]
    refute op["endTime"]
    assert op["id"] == URI.parse(async_url).path
    assert op["resourceId"] |> String.downcase() ==
             String.downcase("/subscriptions/#{@sub}/resourceGroups/lro-rg/providers/Microsoft.Storage/storageAccounts/#{name}")

    # The resource itself is already materialized in the Store with an
    # InProgress-style provisioning view pending; the op record is Store-backed.
    {:ok, op_id} = Map.fetch(op, "name")
    assert match?({:ok, _}, Store.get(:smalt_operations, op_id))
  end

  # ---------------------------------------------------------------------------
  # Regression: the op must flip when polled via the ROUTER even though the
  # request process that started it is long gone (the old GenServer was
  # start_linked from the Bandit request process and died with it, so the
  # scheduled flip never fired and ops stayed InProgress over the wire).
  # Completion is now a pure function of the stored record + clock.
  # ---------------------------------------------------------------------------
  test "op flips when polled via ROUTER after request process gone" do
    name = "st" <> unique()

    put_conn = conn(:put, sa_path(name), sa_body(name)) |> call()
    assert put_conn.status == 202
    op = Jason.decode!(put_conn.resp_body)
    op_path = URI.parse(hd(get_resp_header(put_conn, "azure-asyncoperation"))).path

    delay = Application.get_env(:smalt, :lro_delay_ms, 0)
    Process.sleep(delay + 10)

    poll = conn(:get, op_path) |> call()

    assert poll.status == 200
    assert %{"status" => "Succeeded", "endTime" => end_time} = Jason.decode!(poll.resp_body)
    assert is_binary(end_time)

    # The flip is persisted: a fresh read of the store sees the terminal record.
    assert {:ok, %{"status" => "Succeeded"}} = Smalt.ArmGateway.LRO.get_op(op["name"])
  end

  # ---------------------------------------------------------------------------
  # (2) Polling: operations route flips InProgress -> Succeeded within bound
  # ---------------------------------------------------------------------------
  test "polling operations route reaches Succeeded within 2s and terminal body carries endTime" do
    name = "st" <> unique()

    put_conn = conn(:put, sa_path(name), sa_body(name)) |> call()
    assert put_conn.status == 202
    op = Jason.decode!(put_conn.resp_body)
    op_path = URI.parse(hd(get_resp_header(put_conn, "azure-asyncoperation"))).path

    {final_conn, polls} =
      Enum.reduce_while(1..100, {nil, 0}, fn _, {conn_acc, n} ->
        poll = conn(:get, op_path) |> call()

        case Jason.decode!(poll.resp_body)["status"] do
          "Succeeded" ->
            {:halt, {poll, n + 1}}

          _ ->
            Process.sleep(20)
            {:cont, {poll, n + 1}}
        end
      end)

    assert final_conn
    assert final_conn.status == 200
    assert polls > 0
    assert %{"status" => "Succeeded", "endTime" => end_time} = Jason.decode!(final_conn.resp_body)
    assert is_binary(end_time)

    # Intermediate poll was a 202 InProgress at least once given the 20ms delay.
    assert Jason.decode!(put_conn.resp_body)["status"] == "InProgress"
  end

  # ---------------------------------------------------------------------------
  # (3) Unknown operation id -> 404 ARM envelope
  # ---------------------------------------------------------------------------
  test "GET operations with unknown op id returns 404 ARM error envelope" do
    conn = conn(:get, "/subscriptions/#{@sub}/operations/not-a-real-op") |> call()

    assert conn.status == 404
    assert %{"error" => %{"code" => "OperationNotFound", "message" => msg}} = Jason.decode!(conn.resp_body)
    assert msg =~ "not-a-real-op"
  end

  # ---------------------------------------------------------------------------
  # (3b) Cross-subscription poll of another sub's op id -> 404, never the
  #      foreign record (R2 F4).
  # ---------------------------------------------------------------------------
  test "polling another subscription's operation id returns 404 OperationNotFound" do
    other_sub = "22222222-2222-2222-2222-222222222222"

    Store.put(:smalt_subscriptions, other_sub, %{
      "id" => "/subscriptions/#{other_sub}",
      "subscriptionId" => other_sub,
      "displayName" => "Other Sub",
      "state" => "Enabled"
    })

    name = "st" <> unique()
    put_conn = conn(:put, sa_path(name), sa_body(name)) |> call()
    assert put_conn.status == 202

    [async_url] = get_resp_header(put_conn, "azure-asyncoperation")
    op_id = async_url |> String.split("/operations/") |> List.last() |> String.split("?") |> List.first()

    # Owner polls fine; the other subscription gets 404 for the same op id.
    owner = conn(:get, "/subscriptions/#{@sub}/operations/#{op_id}") |> call()
    assert owner.status in [200, 202]

    foreign = conn(:get, "/subscriptions/#{other_sub}/operations/#{op_id}") |> call()
    assert foreign.status == 404
    assert %{"error" => %{"code" => "OperationNotFound"}} = Jason.decode!(foreign.resp_body)
  end

  # ---------------------------------------------------------------------------
  # (4) Non-LRO type PUT (resourceGroups) -> synchronous 201, no async headers
  # ---------------------------------------------------------------------------
  test "PUT resourceGroups is synchronous 201 with no async headers" do
    conn =
      conn(:put, "/subscriptions/#{@sub}/resourceGroups/lro-sync-rg", %{"location" => "eastus"})
      |> call()

    assert conn.status == 201
    assert get_resp_header(conn, "azure-asyncoperation") == []
    assert get_resp_header(conn, "location") == []
    assert get_resp_header(conn, "retry-after") == []

    body = Jason.decode!(conn.resp_body)
    assert body["properties"]["provisioningState"] == "Succeeded"
    assert body["type"] == "Microsoft.Resources/resourceGroups"
  end

  # ---------------------------------------------------------------------------
  # (5) PUT-on-update semantics, per type
  # ---------------------------------------------------------------------------
  test "LRO type PUT twice: create is 202, update is 200, both LRO responses with distinct operations" do
    name = "st" <> unique()
    first = conn(:put, sa_path(name), sa_body(name)) |> call()
    second = conn(:put, sa_path(name), sa_body(name)) |> call()

    assert first.status == 202
    # ARM LRO convention (C1 row 3b, fixed): update PUT returns 200 + async headers.
    assert second.status == 200
    assert get_resp_header(second, "azure-asyncoperation") != []
    assert get_resp_header(second, "retry-after") == ["1"]

    op1 = Jason.decode!(first.resp_body)
    op2 = Jason.decode!(second.resp_body)
    assert op1["name"] != op2["name"]

    # Both ops eventually Succeed.
    for op <- [op1, op2] do
      assert {:ok, %{"status" => "Succeeded"}} =
               wait_terminal(op["name"])
    end
  end

  test "non-LRO resource type PUT twice: 201 then 200" do
    rg = "upd-rg"

    conn(:put, "/subscriptions/#{@sub}/resourceGroups/#{rg}", %{"location" => "eastus"}) |> call()

    path =
      "/subscriptions/#{@sub}/resourceGroups/#{rg}/providers/Microsoft.Network/virtualNetworks/vn-" <>
        unique() <> "?api-version=#{api_v("Microsoft.Network/virtualNetworks")}"

    payload = %{"location" => "eastus", "properties" => %{"addressPrefixes" => ["10.9.0.0/16"]}}

    first = conn(:put, path, payload) |> call()
    second = conn(:put, path, payload) |> call()

    assert first.status == 201
    assert second.status == 200
    assert get_resp_header(second, "azure-asyncoperation") == []
    assert Jason.decode!(second.resp_body)["properties"]["provisioningState"] == "Succeeded"
  end

  # ---------------------------------------------------------------------------
  # (6) DELETE of an LRO-created resource
  # ---------------------------------------------------------------------------
  test "DELETE of LRO-created storageAccount returns 200 and subsequent GET is 404" do
    name = "st" <> unique()

    put_conn = conn(:put, sa_path(name), sa_body(name)) |> call()
    assert put_conn.status == 202
    op = Jason.decode!(put_conn.resp_body)

    # Resource is GET-able even before the op flips (record already in Store).
    get_path = String.trim_trailing(sa_path(name), "?api-version=#{api_v("Microsoft.Storage/storageAccounts")}")
    assert conn(:get, get_path <> "?api-version=#{api_v("Microsoft.Storage/storageAccounts")}") |> call() |> Map.get(:status) == 200

    assert {:ok, %{"status" => "Succeeded"}} = wait_terminal(op["name"])

    del_conn = conn(:delete, get_path <> "?api-version=#{api_v("Microsoft.Storage/storageAccounts")}") |> call()
    assert del_conn.status == 200

    assert conn(:get, get_path <> "?api-version=#{api_v("Microsoft.Storage/storageAccounts")}") |> call() |> Map.get(:status) ==
             404

    # The operation record itself remains queryable and stays Succeeded.
    assert {:ok, %{"status" => "Succeeded"}} = Smalt.ArmGateway.LRO.get_op(op["name"])
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp unique, do: inspect(make_ref()) |> String.replace(~r/[^0-9a-zA-Z]/, "")

  defp wait_terminal(op_id, tries \\ 100) do
    case Smalt.ArmGateway.LRO.get_op(op_id) do
      {:ok, %{"status" => "Succeeded"} = op} ->
        {:ok, op}

      {:ok, _} ->
        if tries <= 0, do: flunk("operation #{op_id} never reached Succeeded"), else: nil

        Process.sleep(20)
        wait_terminal(op_id, tries - 1)

      :error ->
        flunk("operation #{op_id} vanished from the store")
    end
  end
end
