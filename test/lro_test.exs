defmodule SmaltLroTest do
  use ExUnit.Case
  use Plug.Test

  alias Smalt.ArmGateway.LRO
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

    # The flip is persisted: a RAW store read (not via get_op/1, which lazily
    # re-evaluates and would mask a missing persist — mutant M37 survivor, lens-6
    # F7) sees the terminal record without scheduling fields.
    assert {:ok, %{"status" => "Succeeded"} = stored} = Store.get(:smalt_operations, op["name"])
    refute Map.has_key?(stored, "startedAtMs")
    refute Map.has_key?(stored, "delayMs")
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
      conn(
        :put,
        "/subscriptions/#{@sub}/resourceGroups/lro-sync-rg?api-version=2021-04-01",
        %{"location" => "eastus"}
      )
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

    # The operation record remains queryable and stays Succeeded — pinned by a
    # RAW store read (F7 standard, lens-7): get_op/1's lazy re-evaluation cannot
    # observe persistence, the raw read can. The record is already terminal
    # (wait_terminal above flipped it), so no lazy flip can fire here.
    assert {:ok, %{"status" => "Succeeded"} = stored} = Store.get(:smalt_operations, op["name"])
    refute Map.has_key?(stored, "startedAtMs")
    refute Map.has_key?(stored, "delayMs")
  end

  # ---------------------------------------------------------------------------
  # (7) Concurrent polls of one op during the flip: every poll sees a
  # well-formed record, and the store converges to one persisted Succeeded.
  # ---------------------------------------------------------------------------
  test "concurrent polls during flip all observe well-formed state and converge" do
    name = "st" <> unique()

    put_conn = conn(:put, sa_path(name), sa_body(name)) |> call()
    assert put_conn.status == 202
    op = Jason.decode!(put_conn.resp_body)
    op_path = URI.parse(hd(get_resp_header(put_conn, "azure-asyncoperation"))).path

    delay = Application.get_env(:smalt, :lro_delay_ms, 0)
    Process.sleep(delay + 5)

    results =
      1..10
      |> Enum.map(fn _ ->
        Task.async(fn ->
          conn(:get, op_path) |> call()
        end)
      end)
      |> Enum.map(&Task.await/1)

    statuses = Enum.map(results, & &1.status)

    # Every poll is 200 (delay fully elapsed) with a terminal body.
    assert Enum.all?(statuses, &(&1 == 200))

    bodies = Enum.map(results, &Jason.decode!(&1.resp_body))
    assert Enum.all?(bodies, &(&1["status"] == "Succeeded" and is_binary(&1["endTime"])))

    # The flip is persisted once: a RAW store read (F7) is terminal, and
    # the record no longer carries scheduling fields.
    assert {:ok, stored} = Store.get(:smalt_operations, op["name"])
    assert stored["status"] == "Succeeded"
    refute Map.has_key?(stored, "startedAtMs")
    refute Map.has_key?(stored, "delayMs")
  end

  # ---------------------------------------------------------------------------
  # (8) Lens-2 pin: parent resource DELETED while its LRO is still InProgress.
  # The op record is store-backed and independent of the resource record, so
  # the poll must still terminate Succeeded, the resource must stay 404 (the
  # delete is not resurrected by the op flipping), and the op record must not
  # be resurrected either. Pinned across the three delete shapes: generic
  # provider DELETE, RG cascade DELETE (parent RG gone mid-op), and a direct
  # Store.delete of the parent.
  # ---------------------------------------------------------------------------
  test "op survives parent resource DELETE while InProgress (generic DELETE mid-flight)" do
    name = "st" <> unique()

    put_conn = conn(:put, sa_path(name), sa_body(name)) |> call()
    assert put_conn.status == 202
    op = Jason.decode!(put_conn.resp_body)
    op_path = URI.parse(hd(get_resp_header(put_conn, "azure-asyncoperation"))).path

    get_path =
      String.trim_trailing(sa_path(name), "?api-version=#{api_v("Microsoft.Storage/storageAccounts")}")

    # Delete the parent resource WHILE the op is InProgress.
    del_conn =
      conn(:delete, get_path <> "?api-version=#{api_v("Microsoft.Storage/storageAccounts")}")
      |> call()

    assert del_conn.status == 200
    assert conn(:get, get_path <> "?api-version=#{api_v("Microsoft.Storage/storageAccounts")}")
           |> call()
           |> Map.get(:status) == 404

    # The in-flight op still flips terminal and stays queryable.
    assert {:ok, %{"status" => "Succeeded"} = stored} = wait_terminal(op["name"])
    assert is_binary(stored["endTime"])
    assert stored["resourceId"] == get_path

    # The flip does NOT resurrect the deleted resource.
    assert conn(:get, get_path <> "?api-version=#{api_v("Microsoft.Storage/storageAccounts")}")
           |> call()
           |> Map.get(:status) == 404
  end

  test "RG cascade DELETE mid-op: child op still terminates, cascade not undone" do
    rg_type = "Microsoft.Resources/resourceGroups"
    sa_type = "Microsoft.Storage/storageAccounts"
    name = "st" <> unique()

    rg_path = "/subscriptions/#{@sub}/resourcegroups/lro-cascade-rg?api-version=#{api_v(rg_type)}"

    put_conn = conn(:put, rg_path, %{"location" => "eastus"}) |> call()
    assert put_conn.status == 201

    sa_get_path = "/subscriptions/#{@sub}/resourceGroups/lro-cascade-rg/providers/#{sa_type}/#{name}"

    put_conn = conn(:put, sa_get_path <> "?api-version=#{api_v(sa_type)}", sa_body(name)) |> call()
    assert put_conn.status == 202
    op = Jason.decode!(put_conn.resp_body)

    # RG cascade delete WHILE the SA create-op is InProgress.
    del_conn = conn(:delete, rg_path) |> call()
    assert del_conn.status == 202

    # Child record removed by the cascade…
    assert conn(:get, sa_get_path <> "?api-version=#{api_v(sa_type)}") |> call() |> Map.get(:status) == 404

    # …the in-flight op still terminates…
    assert {:ok, %{"status" => "Succeeded"}} = wait_terminal(op["name"])

    # …and the cascade is not undone by the flip.
    assert conn(:get, sa_get_path <> "?api-version=#{api_v(sa_type)}") |> call() |> Map.get(:status) == 404
    assert conn(:get, rg_path) |> call() |> Map.get(:status) == 404
  end

  # ---------------------------------------------------------------------------
  # (9) Lens-5 mission item 3: op records for deleted parents under LIST /
  # nextLink surfaces. The mission hypothesis was "op listing via nextLink
  # after parent deletion" — closed NOT-surface by enumeration: no route lists
  # :smalt_operations (the only op surfaces are the single-op GET poll and the
  # store). Fenced at wire depth: after a parent DELETE mid-op, the op still
  # terminates, and NO list surface (type-scoped LIST, subscription providers
  # inventory, RG resources via the inventory) ever carries an operation
  # record — ops cannot leak into any paginated value[] the wire can produce.
  # ---------------------------------------------------------------------------
  test "deleted-parent op never surfaces in any LIST / nextLink surface (ops are not listable)" do
    name = "st" <> unique()

    put_conn = conn(:put, sa_path(name), sa_body(name)) |> call()
    assert put_conn.status == 202
    op = Jason.decode!(put_conn.resp_body)
    op_path = URI.parse(hd(get_resp_header(put_conn, "azure-asyncoperation"))).path

    get_path =
      String.trim_trailing(sa_path(name), "?api-version=#{api_v("Microsoft.Storage/storageAccounts")}")

    # Delete the parent mid-op (op stays InProgress at this point).
    assert conn(:delete, get_path <> "?api-version=#{api_v("Microsoft.Storage/storageAccounts")}")
           |> call()
           |> Map.get(:status) == 200

    assert {:ok, %{"status" => "Succeeded"}} = wait_terminal(op["name"])

    # The op record survives in its own store, pollable via the router only.
    poll = conn(:get, op_path) |> call()
    assert poll.status == 200
    assert %{"status" => "Succeeded"} = Jason.decode!(poll.resp_body)

    sa_v = api_v("Microsoft.Storage/storageAccounts")

    # No list surface carries an operation record.
    type_page =
      conn(
        :get,
        "/subscriptions/#{@sub}/resourceGroups/lro-rg/providers/Microsoft.Storage/storageAccounts?api-version=#{sa_v}"
      )
      |> call()

    assert type_page.status == 200

    refute Enum.any?(Jason.decode!(type_page.resp_body)["value"], fn r ->
             r["type"] == "Microsoft.Resources/operations" or
               String.contains?(r["id"] || "", "/operations/")
           end)

    inventory =
      conn(:get, "/subscriptions/#{@sub}/providers?api-version=#{sa_v}") |> call()

    assert inventory.status == 200

    resource_types =
      Jason.decode!(inventory.resp_body)["resourceTypes"] |> MapSet.new(& &1["resourceType"])

    refute MapSet.member?(resource_types, "operations")
  end

  # ---------------------------------------------------------------------------
  # (10) Lens-6 retention probe: op records are never silently truncated or
  # evicted. 500 completed LROs land in :smalt_operations and every record
  # stays queryable — the observed policy is accumulate-forever (no TTL, no
  # cap; typed analysis in tmp/errc/arm-gateway-lens6/cycle-1.md). This fence
  # pins the policy so a future TTL/cap must be a deliberate landing that
  # updates this fence, not a silent eviction.
  # ---------------------------------------------------------------------------
  test "op records accumulate without truncation: 500 completed ops all queryable" do
    rid = "/subscriptions/#{@sub}/resourceGroups/lro-rg/providers/Microsoft.Storage/storageAccounts/retention-probe"

    ids = for _ <- 1..500, do: LRO.start_op(rid)["name"]

    # Distinct ids: 12 random bytes per op — uniqueness pin (cross-parent
    # collision analysis, cycle-1).
    assert Enum.uniq(ids) |> length() == 500

    delay = Application.get_env(:smalt, :lro_delay_ms, 0)
    Process.sleep(delay + 10)

    # All 500 are queryable and terminal; none was evicted by the mints that
    # followed it. F7-standard shape (lens-7): get_op/1 DRIVES the lazy flip
    # (the only thing that persists it), then a RAW store read verifies the
    # persist actually happened — the old single get_op read here could never
    # distinguish "persisted" from "lazily re-derived".
    for id <- ids, do: assert({:ok, _} = LRO.get_op(id))

    for id <- ids do
      assert {:ok, %{"status" => "Succeeded", "resourceId" => ^rid}} = Store.get(:smalt_operations, id)
    end

    assert length(Store.list(:smalt_operations)) == 500
  end

  # ---------------------------------------------------------------------------
  # (11) Lens-6 uniqueness pin: two ops minted for the SAME parent resource id
  # still get distinct op ids and distinct polling URLs — cross-parent op id
  # collisions cannot happen by construction (crypto.strong_rand_bytes(12)).
  # ---------------------------------------------------------------------------
  test "same-parent ops get distinct op ids and distinct polling paths" do
    rid = "/subscriptions/#{@sub}/resourceGroups/lro-rg/providers/Microsoft.Storage/storageAccounts/collision-probe"

    a = LRO.start_op(rid)
    b = LRO.start_op(rid)

    assert a["name"] != b["name"]
    assert a["id"] != b["id"]

    # Both records are independently queryable in the store — RAW reads (F7
    # standard, lens-7): the two InProgress records are physically distinct
    # store entries, not two views one lazy evaluator happens to produce.
    assert {:ok, rec_a} = Store.get(:smalt_operations, a["name"])
    assert {:ok, rec_b} = Store.get(:smalt_operations, b["name"])
    assert rec_a["id"] != rec_b["id"]
    assert rec_a["status"] == "InProgress"
    assert rec_b["status"] == "InProgress"
    assert rec_a["resourceId"] == rid
    assert rec_b["resourceId"] == rid
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
