# Residual internal tier (WO-10, clean-room re-derivation from lib/).
#
# Provenance (lib/ read fresh):
#   - lib/smalt/affidavit/wasm_engine.ex: the named engine's caller
#     contract is TYPED ONLY — `{:ok, _}` | `{:error, :engine_unavailable}`
#     | `{:error, :artifact_digest_mismatch}` | `{:error, {:already_started, _}}`;
#     `call/2`, `call_json/1` and `affi_admit_and_seal/1` catch exits and
#     return `{:error, :engine_unavailable}` when the engine is down or
#     the caller passes no pid (lines: call(nil, _) clause, call_json/1
#     try/catch :exit, affi_admit_and_seal(_) fallback). Never raise.
#   - `start_link/1` whereis-probe first: a live engine yields the typed
#     `{:error, {:already_started, pid}}` passthrough (never collapsed).
#   - lib/smalt/affidavit/wasm_engine_supervisor.ex: `:one_for_one`
#     envelope around a single OWNER GenServer that start_links the named
#     engine and monitors it; abnormal engine death is retried in the
#     owner's OWN mailbox (@restart_delay_ms 250 send_after), consuming
#     zero supervisor intensity. `engine_running?/0` is a typed whereis
#     probe; `restore_owner/0` is the typed test/ops re-arm seam.
#
# Chicago discipline: real NIF engine, real kills, real supervisor
# restart; assertions land on typed return values and live pids.
Code.require_file("poll_helper.exs", __DIR__)

defmodule InternalTier.WasmNifLifecycleTest do
  use ExUnit.Case, async: false

  import SmaltTest.Internal.Poll, only: [eventually: 1, eventually: 2]

  alias Smalt.Affidavit.WasmEngine
  alias Smalt.Affidavit.WasmEngine.Supervisor

  setup do
    # The supervisor may already run (full-app boot owns it). Adopt or
    # start standalone — both end in the named supervisor being live.
    case Process.whereis(Supervisor) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        assert {:ok, _} = Supervisor.start_link(:ok)
        :ok
    end

    # Bounded poll on the observable: the engine name is registered.
    assert {:ok, engine_pid} =
             eventually(fn ->
               case Process.whereis(WasmEngine) do
                 pid when is_pid(pid) -> {:ok, pid}
                 nil -> {:engine_down, Supervisor.engine_running?()}
               end
             end)

    {:ok, engine: engine_pid}
  end

  @tag :smalt_internal
  test "engine_running? tracks the named engine and flip after kill/restart" do
    assert Supervisor.engine_running?() == true
    pid = Process.whereis(WasmEngine)

    # Real kill of the NIF-owned engine process.
    Process.exit(pid, :kill)

    # Observable flip to down...
    assert {:ok, false} =
             eventually(
               fn ->
                 if Supervisor.engine_running?(), do: {:still_up, pid}, else: {:ok, false}
               end,
               timeout_ms: 5_000
             )

    # ...and back up via the owner's own-mailbox restart (250ms class).
    assert {:ok, true} =
             eventually(
               fn ->
                 if Supervisor.engine_running?(), do: {:ok, true}, else: {:still_down, :pending}
               end,
               timeout_ms: 15_000
             )

    new_pid = Process.whereis(WasmEngine)
    assert is_pid(new_pid) and new_pid != pid
  end

  @tag :smalt_internal
  test "double-start of the named engine is the typed already_started passthrough" do
    assert Supervisor.engine_running?() == true
    live = Process.whereis(WasmEngine)

    assert {:error, {:already_started, ^live}} = WasmEngine.start_link([])
    # Also via the second start face (opts defaulted in the module).
    assert {:error, {:already_started, ^live}} = WasmEngine.start_link(path: nil, pin_path: nil)
  end

  @tag :smalt_internal
  test "callers observe typed {:error, :engine_unavailable} while the engine is down, never raise" do
    pid = Process.whereis(WasmEngine)

    Process.exit(pid, :kill)

    assert {:ok, :down} =
             eventually(
               fn ->
                 if Supervisor.engine_running?(), do: {:still_up, pid}, else: {:ok, :down}
               end,
               timeout_ms: 5_000
             )

    # Typed vocabulary DURING the outage window (wasm_engine.ex call(nil,_)
    # clause and the exit-catching call_json/1):
    assert WasmEngine.call(nil, ~c"ping") == {:error, :engine_unavailable}
    assert WasmEngine.call(nil, "ping") == {:error, :engine_unavailable}
    assert WasmEngine.call_json("ping") == {:error, :engine_unavailable}
    assert WasmEngine.affi_admit_and_seal(nil) == {:error, :engine_unavailable}
    # Non-binary garbage falls off the clause head into the typed fallback.
    assert WasmEngine.call(make_ref(), :not_binary) == {:error, :engine_unavailable}

    # Owner restart brings the typed {:ok, _} face back.
    assert {:ok, true} =
             eventually(
               fn ->
                 if Supervisor.engine_running?(), do: {:ok, true}, else: {:still_down, :pending}
               end,
               timeout_ms: 15_000
             )
  end

  @tag :smalt_internal
  test "restore_owner/0 re-arms a fresh owner generation with a live engine" do
    assert {:ok, owner_pid} = Supervisor.restore_owner()
    assert is_pid(owner_pid)

    assert {:ok, true} =
             eventually(
               fn ->
                 if Supervisor.engine_running?(), do: {:ok, true}, else: {:still_down, :pending}
               end,
               timeout_ms: 15_000
             )

    # The re-armed generation is a fresh named engine, usable by callers.
    live = Process.whereis(WasmEngine)
    assert {:error, {:already_started, ^live}} = WasmEngine.start_link([])
  end
end
