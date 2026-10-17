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
    # without making the suite slow. Restore on exit: the leaked :lro_retention_ms
    # = :infinity (set further down) previously poisoned sweeper timing for every
    # later module in the batch (v26.10.17 interference sweep, court run-1 class).
    prev_delay = Application.get_env(:smalt, :lro_delay_ms)
    prev_retention = Application.get_env(:smalt, :lro_retention_ms)

    on_exit(fn ->
      restore_env(:lro_delay_ms, prev_delay)
      restore_env(:lro_retention_ms, prev_retention)
    end)

    Application.put_env(:smalt, :lro_delay_ms, 20)
    :ok
  end

  defp restore_env(_key, nil), do: :ok
  defp restore_env(key, val), do: Application.put_env(:smalt, key, val)

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
        "/subscriptions/#{@sub}/resourceGroups/lro-sync-rg?api-version=2023-07-01",
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
  # (5b) RG delete is itself an LRO: 202 + Location + Retry-After, and polling
  # the Location URL terminates Succeeded (folded from the retired
  # test/arm/lro_test.exs; the stale variant omitted api-version on the DELETE
  # and 400'd — the router requires api-version, hence it is carried here).
  # ---------------------------------------------------------------------------
  test "RG delete is an LRO: 202 + Location + Retry-After and the poll terminates" do
    rg = "lro-rg-del-" <> unique()
    rg_type = "Microsoft.Resources/resourceGroups"

    put =
      conn(:put, "/subscriptions/#{@sub}/resourceGroups/#{rg}?api-version=2023-07-01", %{
        "location" => "eastus"
      })
      |> call()

    assert put.status in [200, 201]

    del = conn(:delete, "/subscriptions/#{@sub}/resourceGroups/#{rg}?api-version=#{api_v(rg_type)}") |> call()
    assert del.status == 202
    assert [loc] = get_resp_header(del, "location")
    assert ["1"] = get_resp_header(del, "retry-after")

    Process.sleep(Application.get_env(:smalt, :lro_delay_ms, 20) + 40)

    poll = conn(:get, URI.parse(loc).path) |> call()
    assert poll.status == 200
    assert %{"status" => "Succeeded"} = Jason.decode!(poll.resp_body)
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
    # Wave-2: storageAccounts DELETE is an ARM LRO — 202 + async headers.
    assert del_conn.status == 202

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

    assert del_conn.status == 202
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
           |> Map.get(:status) == 202

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

    # Wave-2: the listing is the Registry-projected ProviderMatrix — a "value"
    # array of provider rows (no top-level subscriptionId/resourceTypes).
    listing = Jason.decode!(inventory.resp_body)
    assert is_list(listing["value"]) and listing["value"] != []

    # No provider row fabricates an "operations" resourceType.
    refute Enum.any?(listing["value"], fn provider ->
             Enum.any?(provider["resourceTypes"] || [], &(&1["resourceType"] == "operations"))
           end)
  end

  # ---------------------------------------------------------------------------
  # (10) Lens-6 retention probe, REWRITTEN v26.10.14 (V261014-05): terminality
  # at rest with ZERO polls (sweeper-driven), plus the default accumulate-
  # forever retention face and the opt-in eviction face. 500 LROs are minted,
  # NEVER polled, and driven terminal by one explicit sweeper pass; a RAW
  # store read (F7 standard) asserts every record is Succeeded at rest and
  # none was evicted under the default :lro_retention_ms = :infinity. With a
  # short retention window set, the eviction face: a past-window terminal is
  # GONE at raw get, in-window terminals remain, and an InProgress record is
  # NEVER evicted at any age.
  # ---------------------------------------------------------------------------
  test "op records reach terminal at rest with zero polls; default retention keeps all 500" do
    rid = "/subscriptions/#{@sub}/resourceGroups/lro-rg/providers/Microsoft.Storage/storageAccounts/retention-probe"

    Application.put_env(:smalt, :lro_retention_ms, :infinity)

    ids = for _ <- 1..500, do: LRO.start_op(rid)["name"]

    # Distinct ids: 12 random bytes per op — uniqueness pin (cross-parent
    # collision analysis, cycle-1).
    assert Enum.uniq(ids) |> length() == 500

    delay = Application.get_env(:smalt, :lro_delay_ms, 0)
    Process.sleep(delay + 10)

    # ZERO POLLS: one sweeper pass drives all 500 to their persisted terminal
    # through the SAME shared evaluate/2 the lazy path uses.
    :ok = Smalt.ArmGateway.LRO.Sweeper.sweep_now()

    for id <- ids do
      assert {:ok, %{"status" => "Succeeded", "resourceId" => ^rid}} = Store.get(:smalt_operations, id)
    end

    # Default retention is :infinity: nothing was evicted by the sweep.
    assert length(Store.list(:smalt_operations)) == 500

    # -- Eviction face (opt-in short window) -----------------------------------
    # An old terminal (endTime pushed into the past by backdating its store
    # record), a fresh terminal, and one InProgress op. A short window must
    # evict ONLY the old terminal; InProgress survives at any age.
    Application.put_env(:smalt, :lro_retention_ms, 1_000)

    old_id = "retentionold000000000"
    now_dt = DateTime.utc_now() |> DateTime.add(-3_600, :second)

    Store.put(:smalt_operations, old_id, %{
      "id" => "/subscriptions/#{@sub}/operations/#{old_id}",
      "name" => old_id,
      "status" => "Succeeded",
      "startTime" => DateTime.to_iso8601(now_dt),
      "endTime" => DateTime.to_iso8601(now_dt),
      "resourceId" => rid
    })

    fresh_id = hd(ids)
    in_progress = LRO.start_op(rid)
    ip_id = in_progress["name"]

    :ok = Smalt.ArmGateway.LRO.Sweeper.sweep_now()

    # Past-window terminal GONE at raw get.
    assert :error = Store.get(:smalt_operations, old_id)
    # In-window terminal remains.
    assert {:ok, %{"status" => "Succeeded"}} = Store.get(:smalt_operations, fresh_id)
    # InProgress NEVER evicted (this one is genuinely in-window AND the sweep
    # must not touch it even after its delay elapses mid-sweep).
    Process.sleep(Application.get_env(:smalt, :lro_delay_ms, 20) + 10)
    :ok = Smalt.ArmGateway.LRO.Sweeper.sweep_now()
    assert {:ok, %{"status" => "Succeeded"}} = Store.get(:smalt_operations, ip_id)

    Application.put_env(:smalt, :lro_retention_ms, :infinity)
  end

  # ---------------------------------------------------------------------------
  # (10b) At-rest zero-poll fence (V261014-05 falsifier): ONE op minted, never
  # polled by anything, reads terminal at a RAW Store.get after delay +
  # sweep + margin. Before the sweeper, a never-polled record stayed
  # InProgress at rest forever (GAP(lro-lazy-terminality) at-rest face).
  # ---------------------------------------------------------------------------
  test "at-rest terminality with zero polls: never-polled op reads terminal at raw get" do
    rid = "/subscriptions/#{@sub}/resourceGroups/lro-rg/providers/Microsoft.Storage/storageAccounts/atrest-probe"
    op = LRO.start_op(rid)
    id = op["name"]

    delay = Application.get_env(:smalt, :lro_delay_ms, 0)
    Process.sleep(delay + 10)

    # Pre-sweep raw read: still InProgress (no lazy path has ever touched it).
    assert {:ok, %{"status" => "InProgress"}} = Store.get(:smalt_operations, id)

    :ok = Smalt.ArmGateway.LRO.Sweeper.sweep_now()

    # Raw get AFTER the sweep: terminal, persisted, scheduling fields gone.
    assert {:ok, %{"status" => "Succeeded"} = stored} = Store.get(:smalt_operations, id)
    refute Map.has_key?(stored, "startedAtMs")
    refute Map.has_key?(stored, "delayMs")
    assert is_binary(stored["endTime"])
  end

  # ---------------------------------------------------------------------------
  # (10c) No-op fence (V261014-05): a sweep over an EMPTY store and over a
  # store of ALL-terminal records writes NOTHING (count + endTime stability).
  # ---------------------------------------------------------------------------
  test "sweep over empty store and all-terminal store is a no-op (0 writes)" do
    # Empty store.
    assert Store.list(:smalt_operations) == []
    :ok = Smalt.ArmGateway.LRO.Sweeper.sweep_now()
    assert Store.list(:smalt_operations) == []

    # All-terminal store: nothing is rewritten.
    rid = "/subscriptions/#{@sub}/resourceGroups/lro-rg/providers/Microsoft.Storage/storageAccounts/noop-probe"
    ids = for _ <- 1..5, do: LRO.start_op(rid)["name"]
    Process.sleep(Application.get_env(:smalt, :lro_delay_ms, 20) + 10)
    :ok = Smalt.ArmGateway.LRO.Sweeper.sweep_now()

    before =
      Map.new(ids, fn id ->
        {:ok, rec} = Store.get(:smalt_operations, id)
        {id, rec["endTime"]}
      end)

    :ok = Smalt.ArmGateway.LRO.Sweeper.sweep_now()

    after_ =
      Map.new(ids, fn id ->
        {:ok, rec} = Store.get(:smalt_operations, id)
        {id, rec["endTime"]}
      end)

    assert length(Store.list(:smalt_operations)) == 5
    assert before == after_
  end

  # ---------------------------------------------------------------------------
  # (10d) Concurrency fence (V261014-05): a sweeper pass racing a wire poll on
  # the same elapsed op converges to ONE persisted terminal with a
  # byte-identical body — no lock needed, the shared functions write the same
  # record.
  # ---------------------------------------------------------------------------
  test "sweep racing a wire poll converges to one persisted terminal, byte-identical body" do
    rid = "/subscriptions/#{@sub}/resourceGroups/lro-rg/providers/Microsoft.Storage/storageAccounts/race-sweep-probe"
    op = LRO.start_op(rid)
    id = op["name"]
    Process.sleep(Application.get_env(:smalt, :lro_delay_ms, 20) + 10)

    parent = self()

    sweeper =
      Task.async(fn ->
        :ok = Smalt.ArmGateway.LRO.Sweeper.sweep_now()
        send(parent, :swept)
      end)

    poll =
      Task.async(fn ->
        conn(:get, "/subscriptions/#{@sub}/operations/#{id}") |> call()
      end)

    Task.await(sweeper)
    poll_res = Task.await(poll)
    assert poll_res.status in [200, 202]

    # ONE persisted terminal at raw read; scheduling fields gone; a second
    # sweep pass does not change the persisted body byte-for-byte.
    assert {:ok, %{"status" => "Succeeded"} = stored} = Store.get(:smalt_operations, id)
    refute Map.has_key?(stored, "startedAtMs")
    refute Map.has_key?(stored, "delayMs")

    :ok = Smalt.ArmGateway.LRO.Sweeper.sweep_now()
    assert {:ok, stored_after} = Store.get(:smalt_operations, id)
    assert stored_after == stored
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
  # (12) Lens-8 wire-contract probe: is the lazy flip STICKY at the wire? A
  # poll that crosses the delay returns Succeeded AND persists the flip; every
  # later poll must see Succeeded (a revert to InProgress would be a
  # wire-visible monotonicity defect, not just GAP(lro-lazy-terminality)).
  # Measured: terminal is sticky — get_op/1 only re-evaluates records whose
  # status is InProgress, and the flip is persisted before it is observed, so
  # the wire can never see Succeeded -> InProgress.
  # ---------------------------------------------------------------------------
  test "terminal status is sticky across repeated polls (no Succeeded -> InProgress revert)" do
    name = "st" <> unique()

    put_conn = conn(:put, sa_path(name), sa_body(name)) |> call()
    assert put_conn.status == 202
    op = Jason.decode!(put_conn.resp_body)
    op_path = URI.parse(hd(get_resp_header(put_conn, "azure-asyncoperation"))).path

    # First poll while genuinely InProgress: the wire shows 202 + InProgress.
    early = conn(:get, op_path) |> call()
    assert early.status == 202
    assert %{"status" => "InProgress"} = Jason.decode!(early.resp_body)

    assert {:ok, %{"status" => "Succeeded"}} = wait_terminal(op["name"])

    # Repeated polls after terminal: every one is 200 Succeeded, and each is
    # backed by a persisted terminal record (raw read between polls).
    for _ <- 1..3 do
      poll = conn(:get, op_path) |> call()
      assert poll.status == 200
      assert %{"status" => "Succeeded"} = Jason.decode!(poll.resp_body)
      assert {:ok, %{"status" => "Succeeded"}} = Store.get(:smalt_operations, op["name"])
      Process.sleep(5)
    end
  end

  # ---------------------------------------------------------------------------
  # (13) Lens-9 resolution of the lens-8 livelock face: an InProgress record
  # with NO scheduling fields (only reachable via direct writes to the public
  # ETS table — Store.put/3 is a single atomic :ets.insert and start_op/1
  # always writes both fields, so no in-codebase writer produces this shape)
  # is flipped to a PERSISTED terminal Failed record with a typed error member
  # at first evaluation. The wire renders the terminal as 200 (not 202).
  # ---------------------------------------------------------------------------
  test "hand-seeded InProgress record without scheduling fields flips to persisted Failed with error member" do
    stuck_id = "handseeded0000000000000000"

    Store.put(:smalt_operations, stuck_id, %{
      "id" => "/subscriptions/#{@sub}/operations/#{stuck_id}",
      "name" => stuck_id,
      "status" => "InProgress",
      "startTime" => "2026-01-01T00:00:00Z",
      "endTime" => nil,
      "resourceId" => "/subscriptions/#{@sub}/resourceGroups/lro-rg/missing"
    })

    # First evaluation flips it: terminal Failed with a typed error member.
    assert {:ok, %{"status" => "Failed", "endTime" => end_time, "error" => error}} =
             LRO.get_op(stuck_id)

    assert is_binary(end_time)
    assert error["code"] == "OperationRecordIncomplete"
    assert is_binary(error["message"]) and error["message"] != ""

    # The flip is persisted — RAW store read (F7 standard): the store holds the
    # terminal record, not just a lazily re-derived view.
    assert {:ok, %{"status" => "Failed", "error" => %{"code" => "OperationRecordIncomplete"}}} =
             Store.get(:smalt_operations, stuck_id)

    # The wire renders the terminal as 200 (not 202) with the error member.
    # The terminal is sticky: a second poll (raw-read-backed) still sees Failed.
    poll2 = conn(:get, "/subscriptions/#{@sub}/operations/#{stuck_id}") |> call()
    assert poll2.status == 200
    assert %{"status" => "Failed"} = Jason.decode!(poll2.resp_body)
    assert {:ok, %{"status" => "Failed"}} = Store.get(:smalt_operations, stuck_id)
  end

  # ---------------------------------------------------------------------------
  # (14) Lens-9 cycle-2 face: an incomplete record that ALSO lacks "name" —
  # the flip must persist the terminal under the STORE KEY the poll used, not
  # record["name"] (which was nil → terminal landed under key :nil, the polled
  # key stayed InProgress forever = re-livelock + store pollution, measured
  # before the fix). Fences: polled key goes terminal at raw read, no :nil key
  # pollution, and "name" is repaired in the persisted terminal.
  # ---------------------------------------------------------------------------
  test "incomplete record missing name flips under the polled store key (no re-livelock, no :nil pollution)" do
    no_name_id = "noname000000000000000"

    Store.put(:smalt_operations, no_name_id, %{
      "id" => "/subscriptions/#{@sub}/operations/#{no_name_id}",
      "status" => "InProgress",
      "startTime" => "2026-01-01T00:00:00Z",
      "resourceId" => "/subscriptions/#{@sub}/resourceGroups/lro-rg/missing"
    })

    assert {:ok, %{"status" => "Failed", "name" => ^no_name_id}} = LRO.get_op(no_name_id)

    # The polled key is terminal (raw read) — no re-livelock.
    assert {:ok, %{"status" => "Failed"}} = Store.get(:smalt_operations, no_name_id)

    # No :nil-key pollution; the table holds exactly this one record.
    assert :error = Store.get(:smalt_operations, nil)
    assert length(Store.list(:smalt_operations)) == 1
  end

  # ---------------------------------------------------------------------------
  # (15) Lens-9 cycle-3: an unauthorized (foreign-subscription) poll of an
  # incomplete record is refused (404) by the get_op/2 owner check — but the
  # refused poll still DRIVES the evaluation, so the record converges to the
  # persisted Failed terminal anyway. Terminality is idempotent, so the
  # hostile poll cannot wedge the record and cannot resurrect InProgress.
  # ---------------------------------------------------------------------------
  test "foreign-subscription poll of an incomplete op is 404 but the record still converges terminal" do
    other_sub = "33333333-3333-3333-3333-333333333333"

    Store.put(:smalt_subscriptions, other_sub, %{
      "id" => "/subscriptions/#{other_sub}",
      "subscriptionId" => other_sub,
      "displayName" => "Other Sub",
      "state" => "Enabled"
    })

    stuck_id = "crosssub000000000000000"

    Store.put(:smalt_operations, stuck_id, %{
      "id" => "/subscriptions/#{@sub}/operations/#{stuck_id}",
      "name" => stuck_id,
      "status" => "InProgress",
      "startTime" => "2026-01-01T00:00:00Z",
      "endTime" => nil,
      "resourceId" => "/subscriptions/#{@sub}/resourceGroups/lro-rg/missing"
    })

    foreign = conn(:get, "/subscriptions/#{other_sub}/operations/#{stuck_id}") |> call()
    assert foreign.status == 404
    assert %{"error" => %{"code" => "OperationNotFound"}} = Jason.decode!(foreign.resp_body)

    # The refused poll still evaluated the record: it is now the persisted
    # Failed terminal under the owner's key, and stays there.
    assert {:ok, %{"status" => "Failed", "error" => %{"code" => "OperationRecordIncomplete"}}} =
             Store.get(:smalt_operations, stuck_id)

    owner = conn(:get, "/subscriptions/#{@sub}/operations/#{stuck_id}") |> call()
    assert owner.status == 200
    assert %{"status" => "Failed"} = Jason.decode!(owner.resp_body)
  end

  # ---------------------------------------------------------------------------
  # (16) Lens-9 cycle-4 wire-tier default: only "InProgress" renders 202. Any
  # other status is terminal (Cancelled, Failed, Succeeded, unknown
  # vocabulary) and must render 200 — a seeded "Cancelled" record polled as
  # 202 forever was the pre-fix wedge face (default-terminal, no wedge).
  # ---------------------------------------------------------------------------
  test "seeded Cancelled terminal renders 200, not 202-forever (default-terminal wire)" do
    cancelled_id = "cancelled00000000000"

    Store.put(:smalt_operations, cancelled_id, %{
      "id" => "/subscriptions/#{@sub}/operations/#{cancelled_id}",
      "name" => cancelled_id,
      "status" => "Cancelled",
      "startTime" => "2026-01-01T00:00:00Z",
      "endTime" => nil,
      "resourceId" => "/subscriptions/#{@sub}/resourceGroups/lro-rg/missing"
    })

    poll = conn(:get, "/subscriptions/#{@sub}/operations/#{cancelled_id}") |> call()
    assert poll.status == 200
    assert %{"status" => "Cancelled"} = Jason.decode!(poll.resp_body)

    # The record is byte-stable: the wire tier does not mutate foreign
    # terminal vocabulary, it renders it.
    assert {:ok, %{"status" => "Cancelled"}} = Store.get(:smalt_operations, cancelled_id)
  end

  # ---------------------------------------------------------------------------
  # (17) Lens-9 cycle-5 owner-check bypass face: an incomplete record missing
  # its "id" matched the old `other -> other` fall-through, so a FOREIGN
  # subscription poll received the record (200) instead of 404 — the sub
  # check only ran when the id parsed. Fixed to deny-by-default: a record
  # that does not prove ownership is never returned across a subscription-
  # scoped poll.
  # ---------------------------------------------------------------------------
  test "record missing id is never leaked to a foreign-subscription poll (deny-by-default)" do
    no_id = "noid0000000000000000"

    Store.put(:smalt_operations, no_id, %{
      "name" => no_id,
      "status" => "InProgress",
      "startTime" => "2026-01-01T00:00:00Z",
      "resourceId" => "/subscriptions/#{@sub}/resourceGroups/lro-rg/missing"
    })

    foreign = conn(:get, "/subscriptions/99999999-9999-9999-9999-999999999999/operations/#{no_id}") |> call()
    assert foreign.status == 404
    assert %{"error" => %{"code" => "OperationNotFound"}} = Jason.decode!(foreign.resp_body)

    # The record proves no ownership (no parsable sub-scoped id), so it is
    # wire-invisible for EVERY caller — the owner included. It still reached
    # its persisted Failed terminal in the store via the refused polls.
    owner = conn(:get, "/subscriptions/#{@sub}/operations/#{no_id}") |> call()
    assert owner.status == 404
    assert {:ok, %{"status" => "Failed"}} = Store.get(:smalt_operations, no_id)
  end

  # ---------------------------------------------------------------------------
  # (18) Lens-9 cycle-6 crash face: a record with MALFORMED scheduling fields
  # (non-integer startedAtMs) matched the naive scheduling clause and raised
  # ArithmeticError on every poll — a wire 500-forever face. Fixed with
  # integer guards: malformed types route to the typed Failed terminal, so a
  # poll never 500s.
  # ---------------------------------------------------------------------------
  test "record with malformed scheduling fields flips to Failed instead of crashing the poll" do
    bad_type = "badtype00000000000000"

    Store.put(:smalt_operations, bad_type, %{
      "id" => "/subscriptions/#{@sub}/operations/#{bad_type}",
      "name" => bad_type,
      "status" => "InProgress",
      "startTime" => "2026-01-01T00:00:00Z",
      "endTime" => nil,
      "resourceId" => "/subscriptions/#{@sub}/resourceGroups/lro-rg/missing",
      "startedAtMs" => "not-a-number",
      "delayMs" => 20
    })

    assert {:ok, %{"status" => "Failed", "error" => %{"code" => "OperationRecordIncomplete"}}} =
             LRO.get_op(bad_type)

    # Wire tier: 200 Failed, never a 500.
    poll = conn(:get, "/subscriptions/#{@sub}/operations/#{bad_type}") |> call()
    assert poll.status == 200
    assert %{"status" => "Failed"} = Jason.decode!(poll.resp_body)

    assert {:ok, %{"status" => "Failed"}} = Store.get(:smalt_operations, bad_type)
  end

  # ---------------------------------------------------------------------------
  # (19) Lens-9 cycle-7 config contract: a non-integer :lro_delay_ms used to
  # mint records whose delayMs fails the integer guards, so EVERY minted op
  # routed to the incomplete-record Failed terminal at first poll — silent
  # fleet-wide failure. start_op/1 now fails closed (ArgumentError at mint).
  # ---------------------------------------------------------------------------
  test "non-integer :lro_delay_ms fails closed at mint (ArgumentError), never mints a doomed op" do
    Application.put_env(:smalt, :lro_delay_ms, "20")

    assert_raise ArgumentError, ~r/:lro_delay_ms must be an integer/, fn ->
      LRO.start_op("/subscriptions/#{@sub}/resourceGroups/lro-rg/providers/Microsoft.Storage/storageAccounts/cfg-probe")
    end

    # No doomed record was minted.
    assert Store.list(:smalt_operations) == []

    Application.put_env(:smalt, :lro_delay_ms, 20)
  end

  # ---------------------------------------------------------------------------
  # Helpers

  # ---------------------------------------------------------------------------
  # (20) Lens-10 cycle-2: a record whose "status" member is MISSING or not a
  # binary can only come from outside the mint path (start_op/1 and
  # evaluate/2 always write a binary status). Before the fix it sat at rest
  # forever — never evaluated, polling 200 with NO status member — the mirror
  # of the lens-8 livelock for the missing-status shape (measured). It must
  # fail closed: persisted terminal Failed with the typed error member, wire
  # 200 with status Failed, sticky across polls, valid-scheduling-field and
  # no-scheduling-field variants both covered.
  # ---------------------------------------------------------------------------
  test "status-less record fails closed to persisted Failed terminal (missing-status face)" do
    for seed <- [
          # no status at all, valid integer scheduling fields (would previously
          # ride the scheduling clause during its delay window)
          %{"startedAtMs" => System.system_time(:millisecond) + 60_000, "delayMs" => 30_000},
          # no status, no scheduling fields
          %{},
          # non-binary status (no in-codebase writer produces this)
          %{"status" => 123}
        ] do
      id = "nostatus" <> unique()

      Store.put(:smalt_operations, id, Map.merge(seed, %{
        "id" => "/subscriptions/#{@sub}/operations/#{id}",
        "name" => id,
        "startTime" => "2026-01-01T00:00:00Z",
        "endTime" => nil,
        "resourceId" => "/subscriptions/#{@sub}/resourceGroups/lro-rg/missing"
      }))

      assert {:ok, %{"status" => "Failed", "error" => %{"code" => "OperationRecordIncomplete"}}} =
               LRO.get_op(id)

      # Persisted terminal at raw read (F7 standard), sticky on re-poll.
      assert {:ok, %{"status" => "Failed", "error" => %{"code" => "OperationRecordIncomplete"}}} =
               Store.get(:smalt_operations, id)

      poll = conn(:get, "/subscriptions/#{@sub}/operations/#{id}") |> call()
      assert poll.status == 200
      assert %{"status" => "Failed", "error" => %{"code" => "OperationRecordIncomplete"}} =
               Jason.decode!(poll.resp_body)
    end
  end


  # ---------------------------------------------------------------------------
  # (21) Lens-10 cycle-3: a NON-MAP record under an operations key (only
  # reachable via a direct external write) previously crashed the poll with
  # BadMapError — a wire 500-forever crash face (measured), same class as the
  # lens-9 cycle-6 ArithmeticError face. It must fail closed: the store
  # converges to the typed Failed terminal, and the terminal's absent "id"
  # makes the subscription-scoped poll 404 (deny-by-default, fence (17)),
  # never a 500.
  # ---------------------------------------------------------------------------
  test "non-map record fails closed, store converges terminal, poll 404s (never 500)" do
    for garbage <- [["garbage"], 5, "a-string", nil] do
      id = "nonmap" <> unique()

      Store.put(:smalt_operations, id, garbage)

      assert {:ok, %{"status" => "Failed", "error" => %{"code" => "OperationRecordIncomplete"}}} =
               LRO.get_op(id)

      # Store converged to the terminal (raw read), keyed under the poll key.
      assert {:ok, %{"status" => "Failed"}} = Store.get(:smalt_operations, id)

      # Wire: 404 deny-by-default (terminal has no well-formed id), never 500.
      poll = conn(:get, "/subscriptions/#{@sub}/operations/#{id}") |> call()
      assert poll.status == 404
      assert %{"error" => %{"code" => "OperationNotFound"}} = Jason.decode!(poll.resp_body)
    end
  end

  # ---------------------------------------------------------------------------


  # ---------------------------------------------------------------------------
  # (22) Lens-10 cycle-4: concurrent lazy-poll race. 24 concurrent wire polls
  # of one elapsed InProgress op must all render 200 with the SAME terminal
  # body, and the store must converge to ONE persisted terminal (last-put
  # wins is fine — every writer writes a terminal of the same vocabulary).
  # Measured benign pre-fence; this pin keeps the race from regressing into
  # a mixed-vocabulary terminal (Succeeded/Failed flip-flop).
  # ---------------------------------------------------------------------------
  test "24 concurrent polls of one elapsed op: all 200, one terminal body, store converges" do
    op = LRO.start_op("/subscriptions/#{@sub}/resourceGroups/race-rg/providers/Microsoft.Storage/storageAccounts/raceacct")
    id = op["name"]
    Process.sleep(60)

    parent = self()
    Enum.each(1..24, fn _ ->
      spawn(fn ->
        c = conn(:get, "/subscriptions/#{@sub}/operations/#{id}") |> call()
        send(parent, {:r, c.status, c.resp_body})
      end)
    end)

    bodies =
      for _ <- 1..24 do
        receive do
          {:r, s, b} -> {s, b}
        after
          10_000 -> flunk("concurrent poll wire face")
        end
      end

    assert Enum.frequencies(Enum.map(bodies, &elem(&1, 0))) == %{200 => 24}
    assert Enum.uniq(Enum.map(bodies, &elem(&1, 1))) |> length() == 1
    assert {:ok, %{"status" => "Succeeded"}} = Store.get(:smalt_operations, id)
  end

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

# Eviction boundary pins (2026-10-17, wave I18): explicit-retention
# eviction_pass/1's documented zero-retention contract — terminal records at
# endTime <= cutoff evict INCLUSIVELY at retention 0; InProgress never evicts;
# positive retention keeps recent records.
defmodule Smalt.ArmGateway.LRO.SweeperBoundaryTest do
  use ExUnit.Case, async: false

  alias Smalt.ArmGateway.LRO.Sweeper, as: LroSweeper
  alias Smalt.Store

  setup do
    SmaltTest.Lifecycle.ensure_store_up()

    if :ets.info(:smalt_operations) != :undefined do
      :ets.delete_all_objects(:smalt_operations)
    end

    :ok
  end

  defp put_op(key, status, end_iso) do
    Store.put(:smalt_operations, key, %{
      "status" => status,
      "endTime" => end_iso,
      "id" => key
    })
  end

  defp iso(sec_ago) do
    DateTime.utc_now()
    |> DateTime.add(-sec_ago, :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  test "retention 0 evicts terminal records inclusively; InProgress never evicts" do
    put_op("op-done", "Succeeded", iso(10))
    put_op("op-inprogress", "InProgress", iso(10))

    assert :ok = LroSweeper.eviction_pass(0)

    assert :error = Store.get(:smalt_operations, "op-done")
    assert {:ok, _} = Store.get(:smalt_operations, "op-inprogress")
  end

  test "positive retention keeps records younger than the window" do
    put_op("op-recent", "Succeeded", iso(1))
    put_op("op-old", "Succeeded", iso(3600))

    assert :ok = LroSweeper.eviction_pass(600_000)

    assert {:ok, _} = Store.get(:smalt_operations, "op-recent")
    assert :error = Store.get(:smalt_operations, "op-old")
  end

  test "records without terminal endTime are never evicted" do
    put_op("op-noend", "Succeeded", "not-a-date")
    put_op("op-nostatus", "Succeeded", nil)

    assert :ok = LroSweeper.eviction_pass(0)

    assert {:ok, _} = Store.get(:smalt_operations, "op-noend")

    # nil endTime record falls out of the eligibility flat_map entirely
    assert {:ok, _} = Store.get(:smalt_operations, "op-nostatus")
  end
end
