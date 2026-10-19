defmodule Smalt.EtsBaselineIdentityTest do
  @moduledoc """
  ETS baseline-identity fence (Phase 3b item 18, lane 346, 2026-10-16).

  A fresh `Smalt.Store` (no DetsMirror / atom_bridge / sweeper — same
  fresh-Store pattern as `ApiVersionMatrixTest`) is snapshotted with
  `:ets.tab2list/1` across ALL tables (`Smalt.Store.table_names/0`). A real
  resource is then created and deleted over the REAL
  `Smalt.ArmGateway.Router` (Plug.Test), and every table must return to
  strict identity with the seed-row baseline — no residue, no drift.

  `:smalt_sb_locks` is excluded: the lock sweeper mutates it out from under
  the snapshot on its own schedule (environment-dependent, not part of the
  resource lifecycle being fenced).
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Smalt.ArmGateway.Router
  alias Smalt.Registry
  alias Smalt.Store

  @rg_api Registry.latest_version("Microsoft.Resources/resourceGroups") || "2021-04-01"
  @topic_api Registry.latest_version("Microsoft.EventGrid/topics") || "2021-04-01"

  @moduletag timeout: 240_000
  @moduletag :stress

  @opts Router.init([])

  # The sweeper mutates :smalt_sb_locks on its own schedule (peeks/steals
  # expired locks), so it is environment-dependent noise, not lifecycle
  # residue — excluded per the approved design.
  @excluded [:smalt_sb_locks]

  test "resource create+delete via HTTP restores strict ETS identity" do
    ensure_store()
    baseline = snapshot()

    # --- real lifecycle over the real router ---
    sub = "00000000-0000-0000-0000-000000000000"
    rg_path = "/subscriptions/#{sub}/resourceGroups/ets-baseline-rg"

    conn = put_json(rg_path, @rg_api, %{"location" => "eastus"})
    assert conn.status in [200, 201], "RG PUT returned #{conn.status}: #{inspect(conn.resp_body)}"

    res_path = rg_path <> "/providers/Microsoft.EventGrid/topics/ets-baseline-topic"
    conn = put_json(res_path, @topic_api, %{"location" => "eastus"})

    assert conn.status in [200, 201],
           "resource PUT returned #{conn.status}: #{inspect(conn.resp_body)}"

    conn =
      :get
      |> conn(res_path <> "?api-version=#{@topic_api}")
      |> Router.call(@opts)

    assert conn.status == 200, "resource GET returned #{conn.status}"

    conn =
      :delete
      |> conn(res_path <> "?api-version=#{@topic_api}")
      |> Router.call(@opts)

    assert conn.status in [200, 202, 204], "resource DELETE returned #{conn.status}"

    conn =
      :get
      |> conn(res_path <> "?api-version=#{@topic_api}")
      |> Router.call(@opts)

    assert conn.status == 404, "post-delete GET returned #{conn.status}, expected 404"

    # The RG must also go — an empty parent RG left behind IS residue.
    conn =
      :delete
      |> conn(rg_path <> "?api-version=#{@rg_api}")
      |> Router.call(@opts)

    assert conn.status in [200, 202, 204], "RG DELETE returned #{conn.status}"

    conn =
      :get
      |> conn(rg_path <> "?api-version=#{@rg_api}")
      |> Router.call(@opts)

    assert conn.status == 404, "post-delete RG GET returned #{conn.status}, expected 404"

    # RG delete is an LRO: poll the operation over the real wire path until it
    # reaches terminality (Lro.evaluate flips InProgress -> Succeeded on poll),
    # then drive the real retention-eviction pass so the terminal op row is
    # reaped exactly as the at-rest sweeper would. This is the genuine route
    # to :smalt_operations identity — not a hand-delete of the row.
    op_id = op_key()
    poll_to_terminal(op_id)

    prev_lro = Application.get_env(:smalt, :lro_retention_ms, :__unset__)
    Application.put_env(:smalt, :lro_retention_ms, 0)

    on_exit(fn ->
      if prev_lro == :__unset__,
        do: Application.delete_env(:smalt, :lro_retention_ms),
        else: Application.put_env(:smalt, :lro_retention_ms, prev_lro)
    end)

    # Poll-replaceable sync-wait (sleeps.md §A2): drive eviction passes until
    # the snapshot converges to baseline instead of a fixed settle sleep.
    SmaltTest.AssertEventually.eventually(
      fn ->
        :ok = Smalt.ArmGateway.LRO.Sweeper.eviction_pass()

        if snapshot() == baseline do
          {:ok, :converged}
        else
          {:retry, :diverged}
        end
      end,
      deadline_ms: 5_000,
      observable: "post-eviction store snapshot converged to baseline"
    )

    :ok = Smalt.ArmGateway.LRO.Sweeper.eviction_pass()

    # --- strict identity fence ---
    after_state = snapshot()

    assert after_state == baseline, """
    ETS baseline-identity FAILURE: the create+delete lifecycle left residue.

    Differing tables (after vs baseline):
    #{Enum.map_join(diffs(baseline, after_state), "\n", fn {t, b, a} -> "  #{t}\n    baseline: #{inspect(b)}\n    after:    #{inspect(a)}" end)}
    """
  end

  # -- helpers ---------------------------------------------------------------

  defp snapshot do
    Store.table_names()
    |> Kernel.--(@excluded)
    |> Map.new(fn table -> {table, Enum.sort(:ets.tab2list(table))} end)
  end

  defp diffs(baseline, after_state) do
    for {t, b} <- baseline, a = Map.get(after_state, t), a != b do
      {t, b, a}
    end
  end

  defp op_key do
    case :ets.tab2list(:smalt_operations) do
      [{key, _}] -> key
      rows -> flunk("expected exactly one LRO op row, got #{inspect(rows)}")
    end
  end

  # Real wire poll: GET the operation id until it reports a terminal status.
  defp poll_to_terminal(op_id) do
    path = "/subscriptions/00000000-0000-0000-0000-000000000000/operations/#{op_id}"

    deadline = System.monotonic_time(:millisecond) + 5_000

    do_poll(path, deadline)
  end

  defp do_poll(path, deadline) do
    conn =
      :get
      |> conn(path <> "?api-version=#{@topic_api}")
      |> Router.call(@opts)

    body = Jason.decode!(conn.resp_body)

    case body["status"] do
      "InProgress" ->
        if System.monotonic_time(:millisecond) > deadline,
          do: flunk("LRO op #{path} never reached terminality: #{inspect(body)}")

        Process.sleep(20)
        do_poll(path, deadline)

      status when is_binary(status) ->
        :ok

      nil ->
        flunk("operation poll returned no status member: #{inspect(body)}")
    end
  end

  defp put_json(path, api, payload) do
    :put
    |> conn(path <> "?api-version=#{api}", Jason.encode!(payload))
    |> put_req_header("content-type", "application/json")
    |> Router.call(@opts)
  end

  # Same fresh-Store race handling as ApiVersionMatrixTest.ensure_store/0,
  # plus Store.clear/0 so THIS test's baseline is the true seed-row baseline
  # (the global Store is shared across tests on the node; clear/0 wipes all
  # tables and reseeds the default subscription).
  defp ensure_store do
    case Store.start_link([]) do
      {:ok, _} ->
        Store.clear()
        :ok

      {:error, {:already_started, _}} ->
        if :ets.info(:smalt_subscriptions) == :undefined do
          pid = Process.whereis(Store)
          ref = Process.monitor(pid)

          receive do
            {:DOWN, ^ref, :process, ^pid, _} -> ensure_store()
          after
            500 -> ensure_store()
          end
        end

        Store.clear()
        :ok
    end
  end
end
