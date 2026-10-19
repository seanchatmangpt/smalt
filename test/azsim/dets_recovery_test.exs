defmodule SmaltTest.Azsim.DetsRecoveryTest do
  @moduledoc """
  AZB-14 — SIGKILL storm + DETS needs_repair + typed vocabulary (court).

  Spec surface (docs/jira/v26sigkill-dets ticket, docs/jira/v26.10.18/azsim-burn/TICKETS.md AZB-14):

    * DETS opened with `repair: true` after an un-clean shutdown: the repair
      is witnessed by telemetry `[:smalt, :store, :dets_repaired]`; every
      acknowledged (fsynced) write is present after reboot and zero
      never-acked keys appear (zero unacknowledged phantom writes).
    * Forced-corruption variants (truncate tail / flip header byte) yield a
      TYPED boot outcome — repair succeeds (telemetry-witnessed) disjunct
      typed refusal — never an untyped crash loop.
    * Anti-vacuity: opening a killed file with `repair: false` refuses typed
      (the DETS_UNREPAIRED condition) — the fence is load-bearing.
    * Graphlaw/WasmEngine killed mid-request: caller receives
      `:engine_unavailable` as an HTTP 503 typed body; nothing admitted.

  The full 50-cycle seeded SIGKILL storm against real release VMs lives in
  `docker/burn/chaos-kill.sh` (`just burn-chaos-kill --cycles 50 --seed S`).
  """

  use ExUnit.Case, async: false
  use Plug.Test

  alias Smalt.ArmGateway.Router
  alias Smalt.Store
  alias Smalt.Store.DetsMirror

  @tables [:dm_t_resources, :dm_t_docs]
  @sub "00000000-0000-0000-0000-000000000000"

  setup do
    dir = ctx_dir()

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

  defp ctx_dir do
    dir = Path.join(System.tmp_dir!(), "smalt_azb14_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp attach_dets_repaired(tag) do
    :telemetry.attach(tag, [:smalt, :store, :dets_repaired], fn _e, _m, meta, pid ->
      send(pid, {:dets_repaired, meta[:table]})
    end, self())
  end

  # kill -9 shape, REAL child VM: opens the file, writes the acked batch and
  # fsyncs it, writes the in-flight batch WITHOUT sync, then halts abruptly
  # (halt/1 runs no cleanup — the dets files are left exactly as after
  # SIGKILL of the BEAM; observed child exit status 137, the kill -9 code).
  # Durability contract: acked (synced) rows survive; in-flight rows are
  # lost and must NEVER appear after reboot (zero phantoms).
  defp kill9_child_vm(dir, table, acked_n, inflight_n) do
    path = Path.join(dir, "#{table}.dets")
    script = Path.join(dir, "writer.exs")

    body =
      Enum.map_join(1..acked_n, "\n", fn i ->
        ~s[:dets.insert(d, {"azb14-ack-#{i}", %{"n" => #{i}}} ] |> String.replace(" ]", "]")
      end)

    inflight =
      Enum.map_join(1..inflight_n, "\n", fn i ->
        ~s[:dets.insert(d, {"azb14-phantom-#{i}", %{"n" => #{i}}} ] |> String.replace(" ]", "]")
      end)

    File.write!(script, """
    {:ok, d} = :dets.open_file(:azb14_writer, file: ~c"#{path}")
    #{body}
    :ok = :dets.sync(d)
    #{inflight}
    :erlang.halt(137)
    """)

    elixir_bin = System.find_executable("elixir") || raise "elixir not on PATH"
    {out, status} = System.cmd(elixir_bin, [script], stderr_to_stdout: true)
    {status, out, path}
  end

  test "needs_repair path: repair:true boot repairs the killed file, dets_repaired telemetry fires, all acked writes present, zero phantoms" do
    table = :dm_t_resources
    dir = ctx_dir()
    {137, _out, path} = kill9_child_vm(dir, table, 10, 5)

    # Precondition witness: the killed file is TORN — a repair:false open
    # refuses with needs_repair (the DETS_UNREPAIRED condition, observed
    # cross-VM against the real killed file).
    probe = String.to_atom("azb14_probe_#{System.unique_integer()}")
    {:error, {:needs_repair, _}} = :dets.open_file(probe, file: to_charlist(path), repair: false)

    attach_dets_repaired(:azb14_kill)
    {:ok, pid} = DetsMirror.start_link(dir: dir, tables: [table], interval: 3_600_000, repair: true)

    assert_receive {:dets_repaired, ^table}, 5_000

    rows = probe_rows(path)

    Enum.each(1..10, fn i ->
      assert Enum.any?(rows, fn {k, v} -> k == "azb14-ack-#{i}" and v == %{"n" => i} end)
    end)

    # Zero unacknowledged phantom writes: the in-flight batch (never acked)
    # and never-submitted controls are all absent.
    Enum.each(1..5, fn i ->
      refute Enum.any?(rows, fn {key, _} -> key == "azb14-phantom-#{i}" end)
    end)

    refute Enum.any?(rows, fn {key, _} -> key == "azb14-never-submitted" end)
    GenServer.stop(pid)
    :telemetry.detach(:azb14_kill)
  end

  test "corruption variant truncate-tail: typed outcome — repair with telemetry disjunct typed refusal; store keeps serving" do
    table = :dm_t_resources
    dir = ctx_dir()
    path = Path.join(dir, "#{table}.dets")

    {:ok, pid} = DetsMirror.start_link(dir: dir, tables: [table], interval: 3_600_000, repair: true)
    :ets.insert(table, {"trunc-key", %{"v" => 1}})
    DetsMirror.sync(pid)
    GenServer.stop(pid)

    # Corruption variant (a): truncate the tail.
    size = File.stat!(path).size
    <<kept::binary-size(div(size, 2))>> <> _rest = File.read!(path)
    File.write!(path, kept)

    attach_dets_repaired(:azb14_trunc)

    result =
      try do
        {:ok, pid2} = DetsMirror.start_link(dir: dir, tables: [table], interval: 3_600_000, repair: true)
        GenServer.stop(pid2)
        {:repaired, :typed_ok}
      rescue
        e in ArgumentError -> {:typed_refusal, e.message}
      end

    case result do
      {:repaired, :typed_ok} -> assert_receive {:dets_repaired, ^table}, 5_000
      {:typed_refusal, msg} -> assert msg =~ "dm_t_resources"
    end

    # Other planes keep serving: the store answers regardless of mirror fate.
    ensure_store()
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
    <<b>> = first
    File.write!(path, <<bxor(b, 0xFF), rest::binary>>)

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
    ensure_store()
    assert :ok = Store.put(:dm_t_resources, "post-hdr", %{"serving" => true})
  end

  test "anti-vacuity: repair:false on the killed file refuses typed — the DETS_UNREPAIRED condition fires" do
    table = :dm_t_resources
    dir = ctx_dir()
    {137, _out, _path} = kill9_child_vm(dir, table, 3, 3)

    result =
      try do
        case DetsMirror.start_link(dir: dir, tables: [table], interval: 3_600_000, repair: false) do
          {:ok, pid} ->
            GenServer.stop(pid)
            :opened_clean

          {:error, reason} ->
            {:refused, inspect(reason)}
        end
      rescue
        e in ArgumentError -> {:refused, e.message}
      end

    # The fence must be load-bearing: repair:false on a killed file is a
    # typed refusal — never a silent clean open.
    assert match?({:refused, _}, result)
    {:refused, msg} = result
    assert msg =~ "needs_repair" or msg =~ "corrupt_mirror"
  end

  test "graphlaw/WasmEngine killed mid-request: caller receives :engine_unavailable as HTTP 503 typed body, nothing admitted" do
    ensure_store()
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

        # Supervised-restart witness: the engine comes back after the kill.
        assert SmaltTest.AssertEventually.eventually(
                 fn ->
                   if is_pid(Process.whereis(Smalt.Affidavit.WasmEngine)) do
                     {:ok, :back}
                   else
                     {:retry, :down}
                   end
                 end,
                 deadline_ms: 5_000,
                 observable: "WasmEngine restarted after kill"
               )
      end
    )
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
