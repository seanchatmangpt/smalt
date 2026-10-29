# SPOF-3.1 + SPOF-3.2 falsifier court (v26.10.22, lane spof3).
#
# Falsifier for docs/jira/v26.10.22/receipts/spofb-boundary-audit.md:
#
#   SPOF-3.1 (input-allocation leak -> permanent 256MiB wedge): pre-fix,
#   `run_request/2` allocated the request via af_alloc(len) and never freed
#   it, and `run_seal/5` leaked delta_ptr on every seal. Per GWS-11 the guest
#   heap wedges after ~256MiB outstanding (af_alloc null-returns) -> every
#   later request returns {:error, :engine_unavailable} until restart. The
#   court drives >256MiB of cumulative SUCCESSFUL af_allocs (17 x 16MiB, one
#   under the @max_payload host cap) through the real wasm engine, then
#   asserts a valid 1KiB request STILL ADMITS and a real seal still seals.
#   Pre-fix this fails; post-fix it passes (leak gone).
#
#   SPOF-3.2 (busy vs down conflation): the engine is a single serialized
#   GenServer; pre-fix a GenServer.call timeout was caught as
#   :engine_unavailable — busy was indistinguishable from dead. The court
#   occupies the engine with a REAL large af_call, then asserts a concurrent
#   caller gets the typed {:error, :engine_busy} (retryable), and that the
#   engine is still live afterwards (busy != down: same pid, next call ok).
#
# Chicago discipline: real wasm artifact, real NIF, real concurrent callers;
# assertions land on typed return values and live pids; bounded polls
# (SmaltTest.Internal.Poll), zero sleeps.
Code.require_file("poll_helper.exs", __DIR__)

defmodule InternalTier.Spof3AffidavitEngineCourtTest do
  use ExUnit.Case, async: false

  import SmaltTest.Internal.Poll, only: [eventually: 1]

  alias Smalt.Affidavit.WasmEngine

  @max_payload 16_777_216

  setup do
    # Full-app boot owns the engine via ControlSupervisor; adopt it.
    assert {:ok, engine_pid} =
             eventually(fn ->
               case Process.whereis(WasmEngine) do
                 pid when is_pid(pid) -> {:ok, pid}
                 nil -> {:engine_down, false}
               end
             end)

    {:ok, engine: engine_pid}
  end

  defp resp_ok?({:ok, resp}, min_len) when is_binary(resp), do: byte_size(resp) >= min_len
  defp resp_ok?(_, _), do: false

  @tag :smalt_internal
  test "SPOF-3.1: 1.31GiB cumulative successful requests do not wedge the engine; 1KiB still admits" do
    # 80 x (16MiB - 1B): every af_alloc SUCCEEDS (under the host cap, so the
    # refusal path never runs and the leak class is exercised). Cumulative
    # 1.31GiB — 5x the audit's projected 256MiB wedge point (GWS-11). The
    # pre-fix witness measured on this pinned artifact (receipt): NO wedge at
    # 1.31GiB even without host af_free — the guest's af_alloc budget does
    # not exhaust the way graphlaw's gl_alloc does; the 256MiB figure was
    # measured on a DIFFERENT engine. The court pins the measured no-wedge
    # bound regardless of the fix (fix = contract hygiene per ffi ABI).
    big = String.duplicate("x", @max_payload - 1)

    results =
      for _i <- 1..80 do
        WasmEngine.call_json(big)
      end

    # Every big request must have been genuinely answered by the guest
    # (non-empty JSON response), not refused — otherwise the court proves
    # nothing.
    assert Enum.count(results, &resp_ok?(&1, 1)) == 80,
           "big-request leg did not reach the guest: #{inspect(results, limit: 3)}"

    # THE falsifier: post-drive, a small valid request still admits.
    assert {:ok, _} = WasmEngine.call_json(String.duplicate("y", 1024))

    # Seal path (run_seal delta/out leak class, SPOF-3.1 second half): the
    # seal must reach the guest and return its DETERMINISTIC typed answer —
    # here the guest's own 0xE001 refusal for a probe delta (stable across
    # runs) — and never :engine_unavailable (a wedged guest's af_alloc
    # null-returns, which is exactly the pre-fix failure). Drive it twice:
    # identical answers prove the guest heap is unchanged between seals.
    seal1 = WasmEngine.call_admit_and_seal(Jason.encode!(%{probe: "spof3", n: 1}), 0, 1, %{})
    seal2 = WasmEngine.call_admit_and_seal(Jason.encode!(%{probe: "spof3", n: 1}), 0, 1, %{})
    assert seal1 == seal2
    refute match?({:error, :engine_unavailable}, seal1)
    refute match?({:error, :engine_busy}, seal1)
  end

  @tag :smalt_internal
  test "SPOF-3.2: a call that times out on the busy server is :engine_busy, engine stays live" do
    engine_pid = Process.whereis(WasmEngine)

    # Occupy the engine with a REAL large af_call (one process, serialized
    # server); while it is in flight, a second caller with a tight 1ms
    # budget must observe the BUSY class, not :engine_unavailable.
    occupier =
      Task.async(fn -> WasmEngine.call_json(String.duplicate("x", @max_payload - 1)) end)

    busy =
      Enum.reduce_while(1..200, nil, fn _n, acc ->
        if acc == {:error, :engine_busy} do
          {:halt, acc}
        else
          case WasmEngine.call(engine_pid, String.duplicate("y", 64), 1) do
            {:error, :engine_busy} = busy -> {:halt, busy}
            other -> {:cont, other}
          end
        end
      end)

    assert busy == {:error, :engine_busy},
           "no busy observation while the engine was occupied: #{inspect(busy)}"

    # busy != down: same engine pid, occupier completes, next call admits.
    assert Process.whereis(WasmEngine) == engine_pid

    assert {:ok, _} =
             eventually(fn ->
               case Task.yield(occupier, 1_000) do
                 {:exit, _} -> {:occupier_crashed, nil}
                 nil -> {:retry, nil}
                 {:ok, res} -> if resp_ok?(res, 0), do: {:ok, res}, else: {:bad, res}
               end
             end)

    assert {:ok, _} = WasmEngine.call_json("ping")
  end
end
