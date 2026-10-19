defmodule SmaltTest.Azsim.DetsRecoveryTest do
  @moduledoc """
  AZB-14 — SIGKILL storm + DETS needs_repair + typed vocabulary (court).

  Spec surface (docs/jira/v26.10.18/azsim-burn/TICKETS.md, AZB-14):

    * DETS opened with `repair: true` after an un-clean shutdown: the
      `needs_repair` path is exercised and witnessed by telemetry
      `[:smalt, :store, :dets_repaired]`; every acknowledged write is
      present after reboot and zero never-submitted control keys appear
      (zero unacknowledged phantom writes).
    * Forced-corruption variants (truncate tail / flip header byte) yield a
      TYPED boot outcome — repair succeeds (telemetry-witnessed) disjunct
      typed refusal — never an untyped crash loop.
    * Anti-vacuity: opening a torn file with `repair: false` refuses typed
      (the DETS_UNREPAIRED condition) — the fence is load-bearing.
    * Graphlaw/WasmEngine killed mid-request ⇒ caller receives
      `:engine_unavailable` as an HTTP 503 typed body; nothing admitted.

  The full 50-cycle seeded SIGKILL storm against real release VMs lives in
  `docker/burn/chaos-kill.sh` (`just burn-chaos-kill --cycles 50 --seed S`).
  """

  use ExUnit.Case, async: false
  use Plug.Test
  import Bitwise

  alias Smalt.ArmGateway.Router
  alias Smalt.Store
  alias Smalt.Store.DetsMirror

  @tables [:dm_t_resources, :dm_t_docs]
  @sub "00000000-0000-0000-0000-000000000000"

  setup do
    dir = Path.join(System.tmp_dir!(), "smalt_azb14_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_exit(fn -> File.rm_rf!(dir) end)

    ensure_store()

    Enum.each(@tables, fn table ->
      if :ets.info(table) == :undefined do
        :ets.new(table, [:ordered_set, :public, :named_table])
      end

      :ets.delete_all_objects(table)
    end)

    %{dir: dir}
  end

  defp ensure_store do
    case Store.start_link([]) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end

  defp attach_dets_repaired(tag) do
    :telemetry.attach(tag, [:smalt, :store, :dets_repaired], fn _e, _m, meta, pid ->
      send(pid, {:dets_repaired, meta[:table]})
    end, self())
  end

  # kill -9 shape: open, write, fsync, NEVER close — the file stays flagged
  # dirty exactly as after SIGKILL of the BEAM.
  defp write_unclean(path, rows) do
    name = String.to_atom("azb14_writer_#{System.unique_integer()}")
    {:ok, dets} = :dets.open_file(name, file: to_charlist(path))
    :dets.insert(dets, rows)
    :ok = :dets.sync(dets)
    # deliberately left open (unclean shutdown shape)
    :ok
  end

  test "needs_repair path: repair:true boot repairs the un-clean file, dets_repaired telemetry fires, all acked writes present, zero phantoms" do
    dir = Path.join(System.tmp_dir!(), "smalt_azb14_kill_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    table = :dm_t_resources
    path = Path.join(dir, "#{table}.dets")

    acked = for i <- 1..10, do: {"azb14-ack-#{i}", %{"n" => i}}
    :ok = write_unclean(path, acked)

    # Control keys NEVER submitted anywhere: must be absent after reboot
    # (zero unacknowledged phantom writes).
    control = ["azb14-phantom-1", "azb14-phantom-2"]

    attach_dets_repaired(:azb14_kill)
    {:ok, pid} = DetsMirror.start_link(dir: dir, tables: [table], interval: 3_600_000, repair: true)

    assert_receive {:dets_repaired, ^table}, 5_000

    rows = probe_rows(path)

    Enum.each(1..10, fn i ->
      assert Enum.any?(rows, fn {k, v} -> k == "azb14-ack-#{i}" and v == %{"n" => i} end)
    end)

    Enum.each(control, fn k ->
      refute Enum.any?(rows, fn {key, _} -> key == k end)
    end)

    GenServer.stop(pid)
    :telemetry.detach(:azb14_kill)
  end

  test "corruption variant truncate-tail: typed outcome — repair succeeds with telemetry disjunct typed refusal; store keeps serving" do
    table = :dm_t_resources
    dir = ctx_dir()
    path = Path.join(dir, "#{table}.dets")

    {:ok, pid} = DetsMirror.start_link(dir: dir, tables: [table], interval: 3_600_000, repair: true)
    :ets.insert(table, {"trunc-key", %{"v" => 1}})
    DetsMirror.sync(pid)
    GenServer.stop(pid)

    # Corruption variant (a): truncate the tail.
    size = File.stat!(path).size
    File.truncate!(path, max(div(size, 2), 1))

    attach_dets_repaired(:azb14_trunc)

    result =
      try do
        {:ok, pid2} = DetsMirror.start_link(dir: dir, tables: [table], interval: 3_600_000, repair: true)
        GenServer.stop(pid2)
        {:repaired, :typed_ok}
      rescue
        e in ArgumentError -> {:typed_refusal, e.message}
      end

    repaired? = match?({:repaired, :typed_ok}, result)

    if repaired? do
      assert_receive {:dets_repaired, ^table}, 5_000
    else
      {:typed_refusal, msg} = result
      assert msg =~ "dm_t_resources"
    end

    # Other planes keep serving: the store answers regardless of mirror fate.
    assert :ok = Store.put(:dm_t_resources, "post-corruption", %{"serving" => true})
    assert {:ok, %{"serving" => true}} = Store.get(:dm_t_resources, "post-corruption")

    :telemetry.detach(:azb14_trunc)
  end

  test "corruption variant header-byte-flip: typed outcome only, never an untyped crash loop" do
    table = :dm_t_resources
    dir = ctx_dir()
    path = Path.join(dir, "#{table}.dets")

    {:ok, pid} = DetsMirror.start_link(dir: dir, tables: [table], interval: 3_600_000, repair: true)
    :ets.insert(table, {"hdr-key", %{"v" => 1}})
    DetsMirror.sync(pid)
    GenServer.stop(pid)

    # Corruption variant (b): flip the first header byte.
    <<first::binary-size(1), rest::binary>> = File.read!(path)
    File.write!(path, <<bxor(first, 0xFF)::binary, rest::binary>>)

    result =
      try do
        {:ok, pid2} = DetsMirror.start_link(dir: dir, tables: [table], interval: 3_600_000, repair: true)
        GenServer.stop(pid2)
        {:repaired, :typed_ok}
      rescue
        e in ArgumentError -> {:typed_refusal, e.message}
      end

    case result do
      {:repaired, :typed_ok} -> :ok
      {:typed_refusal, msg} -> assert msg =~ "dm_t_resources"
    end

    # Other planes keep serving.
    assert :ok = Store.put(:dm_t_resources, "post-hdr", %{"serving" => true})
  end

  test "anti-vacuity: repair:false on a torn file refuses typed — the DETS_UNREPAIRED condition fires" do
    table = :dm_t_resources
    dir = ctx_dir()
    path = Path.join(dir, "#{table}.dets")

    :ok = write_unclean(path, [{"av-key", %{"v" => 1}}])

    result =
      try do
        {:ok, pid} = DetsMirror.start_link(dir: dir, tables: [table], interval: 3_600_000, repair: false)
        GenServer.stop(pid)
        :opened_clean
      rescue
        e in ArgumentError -> {:refused, e.message}
      end

    # The fence must be load-bearing: repair:false on a torn file is a typed
    # refusal (start_link's fail-closed prevalidation or the init-time
    # corrupt_mirror outcome) — never a silent clean open.
    assert match?({:refused, _}, result)
    {:refused, msg} = result
    assert msg =~ "dm_t_resources"
  end

  test "graphlaw/WasmEngine killed mid-request: caller receives :engine_unavailable as HTTP 503 typed body, nothing admitted" do
    Store.clear()

    Store.put(:smalt_subscriptions, @sub, %{
      "id" => "/subscriptions/#{@sub}",
      "subscriptionId" => @sub,
      "displayName" => "AZB-14",
      "state" => "Enabled"
    })

    res_id =
      "/subscriptions/#{@sub}/resourceGroups/test-rg/providers/Microsoft.Storage/storageAccounts/azb14-kill"

    SmaltTest.Env.with(
      [graph_law: [enforcement: :fail_closed], graphlaw_engine: :ash_graphlaw],
      fn ->
        # REAL kill of the engine process in the mid-request window: the next
        # enforcement hit must observe the engine down.
        case Process.whereis(Smalt.Affidavit.WasmEngine) do
          nil -> :ok
          pid -> Process.exit(pid, :kill)
        end

        conn =
          conn(:put,
            "/subscriptions/#{@sub}/resourceGroups/test-rg/providers/Microsoft.Storage/storageAccounts/azb14-kill?api-version=2021-12-02",
            %{"location" => "eastus", "properties" => %{"skuName" => "Standard_LRS"}}
          )
          |> Router.call(Router.init([]))

        assert conn.status == 503
        err = Jason.decode!(conn.resp_body)["error"]
        assert err["code"] == "EngineUnavailable"
        assert err["message"] =~ ":engine_unavailable"

        # Falsifier face: nothing was admitted while the engine was down.
        assert Store.get(:smalt_resources, res_id) == :error
      end
    )
  end

  defp ctx_dir do
    Path.join(System.tmp_dir!(), "smalt_azb14_#{System.unique_integer([:positive])}")
    |> tap(&File.mkdir_p!/1)
    |> tap(&on_exit(fn -> File.rm_rf!(&1) end))
  end

  defp probe_rows(path) do
    name = String.to_atom("azb14_probe_#{System.unique_integer()}")

    case :dets.open_file(name, file: to_charlist(path), repair: true) do
      {:ok, d} ->
        rows = :dets.match_object(d, :_)
        :dets.close(d)
        rows

      {:error, reason} ->
        raise "probe open of #{path} failed: #{inspect(reason)}"
    end
  end
end
