defmodule Smalt.Affidavit.WasmEngineFailClosedTest do
  @moduledoc """
  Crash-ladder fences for `Smalt.Affidavit.WasmEngine`
  (`lib/smalt/affidavit/wasm_engine.ex`):

    1. corrupt/truncated .wasm at the configured path -> typed engine error,
       no raise, and repeat call/2 stays typed (no crash-loop)
    2. oversized payload -> typed refusal (engine ABI limit face), no raise,
       engine unaffected (next valid call still succeeds)
    3. 10 concurrent call/2 -> all resolve, no deadlock, engine state consistent
    4. artifact present but wrong hash -> fail-closed digest-pin gate
       (`{:error, :artifact_digest_mismatch}`), with a positive control
       proving the gate admits the pristine artifact (gate not vacuous).

  Fail-closed law: every refusal is a typed `{:error, _}` — the engine
  never raises and never fabricates a result.
  """

  use ExUnit.Case, async: false

  alias Smalt.Affidavit.WasmEngine
  alias Smalt.Enclave.Doctor

  @artifact "priv/wasm/affidavit_wasm.wasm"
  @pin "priv/wasm/affidavit.sha256"

  # A request the guest module itself accepts (witnessed: the guest's
  # unknown-op error enumerates "capabilities" as a known op).
  @valid_request ~s({"op":"capabilities"})

  # ---------------------------------------------------------------------------
  # Lifecycle helpers (engine is a named singleton, not in the sup tree)
  # ---------------------------------------------------------------------------

  defp stop_engine do
    if pid = Process.whereis(WasmEngine) do
      GenServer.stop(pid, :normal)
      wait_until(fn -> is_nil(Process.whereis(WasmEngine)) end)
      # lane10 settle: wasmtime store/instance teardown is asynchronous
      # behind the NIF; an immediate re-start races it and init fails
      # :engine_start_failed (witnessed inter-test flake). Small settle.
      Process.sleep(25)
    end

    :ok
  end

  defp wait_until(fun, tries \\ 100) do
    if fun.() do
      :ok
    else
      if tries > 0 do
        Process.sleep(10)
        wait_until(fun, tries - 1)
      else
        flunk("wait_until: condition not met after #{tries} tries")
      end
    end
  end

  # Typed-start with singleton-race tolerance: the engine is a NAMED
  # SINGLETON, so when another suite (async pair race) already started it,
  # a direct start_link returns {:error, {:already_started, pid}} instead of
  # this fence's expected typed outcome. Stop the duplicate, settle, retry
  # once so the fence observes ITS intended artifact state.
  defp typed_start(opts) do
    case WasmEngine.start_link(opts) do
      {:error, {:already_started, pid}} ->
        GenServer.stop(pid, :normal)
        wait_until(fn -> is_nil(Process.whereis(WasmEngine)) end)
        Process.sleep(25)
        WasmEngine.start_link(opts)

      other ->
        other
    end
  end

  defp flush_exits do
    receive do
      {:EXIT, _pid, _reason} -> flush_exits()
    after
      0 -> :ok
    end
  end

  defp with_engine(opts, fun) do
    stop_engine()
    result = typed_start(opts)

    try do
      fun.(result)
    after
      stop_engine()
    end
  end

  defp tmp_wasm(name, bytes) do
    path = Path.join(System.tmp_dir!(), name <> "_#{System.unique_integer()}.wasm")
    :ok = File.write!(path, bytes)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp artifact_bytes, do: File.read!(@artifact)

  defp sha256(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  setup do
    stop_engine()
    on_exit(fn -> stop_engine() end)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Fence 1: corrupt/truncated artifact -> typed error, no crash-loop
  # ---------------------------------------------------------------------------

  test "fence 1: truncated artifact start is typed, repeat calls stay typed" do
    full = artifact_bytes()
    trunc_path = tmp_wasm("affidavit_truncated", binary_part(full, 0, div(byte_size(full), 4)))

    # Default pin gates the truncated bytes: typed digest refusal, never a raise.
    assert {:error, :artifact_digest_mismatch} = typed_start(path: trunc_path)

    # With no engine running, call/2 is typed and repeatable (no crash-loop:
    # there is no process to crash, and the test process never dies).
    assert {:error, :engine_unavailable} = WasmEngine.call(nil, @valid_request)

    with_engine([path: trunc_path], fn start ->
      assert {:error, :artifact_digest_mismatch} = start
      assert is_nil(Process.whereis(WasmEngine))

      # repeat calls while the engine is down: typed, identical, no crash-loop
      assert {:error, :engine_unavailable} = WasmEngine.call(self(), @valid_request)
      assert {:error, :engine_unavailable} = WasmEngine.call(self(), @valid_request)
    end)

    assert is_nil(Process.whereis(WasmEngine))
  end

  test "fence 1b: garbage bytes artifact is typed, never a raise" do
    garbage_path = tmp_wasm("affidavit_garbage", <<0, 1, 2, 3, 4, 5>>)

    assert {:error, :artifact_digest_mismatch} = typed_start(path: garbage_path)
    assert is_nil(Process.whereis(WasmEngine))
  end

  test "fence 1c: missing artifact path is typed" do
    missing = Path.join(System.tmp_dir!(), "affidavit_absent_#{System.unique_integer()}.wasm")

    assert {:error, :engine_unavailable} = typed_start(path: missing)
    assert is_nil(Process.whereis(WasmEngine))
  end

  # ---------------------------------------------------------------------------
  # Fence 2: oversized payload -> typed refusal, engine unaffected
  # ---------------------------------------------------------------------------

  test "fence 2: oversized payload refuses typed, engine still serves" do
    with_engine([], fn start ->
      assert {:ok, pid} = start
      assert Process.alive?(pid)

      # 64 MiB payload, far past the guest ABI MAX_REQUEST_BYTES limit
      # (witnessed af_alloc -> 0 for 64 MiB in the admission probe).
      oversized = :binary.copy(<<0>>, 64 * 1024 * 1024)
      assert {:error, :engine_unavailable} = WasmEngine.call(pid, oversized)

      # engine state consistent: alive, same name, and the next VALID call
      # still gets a real guest response (the refusal was typed, not a crash).
      assert Process.whereis(WasmEngine) == pid
      assert Process.alive?(pid)

      assert {:ok, resp} = WasmEngine.call(pid, @valid_request)
      assert {:ok, %{"ok" => true, "abi_version" => 1, "module" => "affidavit-wasm"}} =
               Jason.decode(resp)
    end)
  end

  # ---------------------------------------------------------------------------
  # Fence 3: 10 concurrent call/2 -> all resolve, no deadlock, engine consistent
  # ---------------------------------------------------------------------------

  test "fence 3: 10 concurrent callers all resolve, engine alive and consistent" do
    with_engine([], fn start ->
      assert {:ok, pid} = start

      results =
        1..10
        |> Task.async_stream(
          fn i -> {i, WasmEngine.call(pid, @valid_request)} end,
          max_concurrency: 10,
          timeout: 15_000
        )
        |> Enum.to_list()

      assert Enum.all?(results, &match?({:ok, _}, &1)),
             "no caller may crash or deadlock (timeout kills): #{inspect(results, limit: 5)}"

      rows = Enum.map(results, fn {:ok, row} -> row end)
      assert length(rows) == 10

      Enum.each(rows, fn {i, result} ->
        assert {:ok, resp} = result, "caller #{i} got #{inspect(result)}"
        assert {:ok, %{"ok" => ok_flag}} = Jason.decode(resp)
        assert is_boolean(ok_flag)
      end)

      # engine state consistent: same pid, alive, still serving after the burst
      assert Process.whereis(WasmEngine) == pid
      assert Process.alive?(pid)
      assert {:ok, _resp} = WasmEngine.call(pid, @valid_request)
    end)
  end

  # ---------------------------------------------------------------------------
  # Fence 4: wrong-hash artifact -> fail-closed digest gate (+ positive control)
  # ---------------------------------------------------------------------------

  test "fence 4: wrong-hash artifact refuses typed; pristine artifact admits" do
    full = artifact_bytes()

    # (a) fail-closed face: one flipped byte + the REAL sidecar pin -> refusal
    wrong_path = tmp_wasm("affidavit_wronghash", "X" <> binary_part(full, 1, byte_size(full) - 1))

    assert {:error, :artifact_digest_mismatch} = typed_start(path: wrong_path)
    assert is_nil(Process.whereis(WasmEngine))

    # (b) non-vacuity control: pristine bytes + the REAL sidecar pin admits.
    #     A gate that refused everything would also pass (a) — this proves it
    #     actually distinguishes pinned bytes from tampered bytes.
    assert {:ok, pid} = typed_start(path: @artifact)
    assert Process.alive?(pid)
    assert {:ok, _resp} = WasmEngine.call(pid, @valid_request)
    stop_engine()

    # (c) at-rest receipt: sidecar pin == on-disk artifact bytes == the
    #     module-attribute fallback pin the engine admits without a sidecar.
    pin_line = @pin |> File.read!() |> String.split("\n") |> Enum.find(&(&1 != ""))
    [pin_sha, pin_name] = String.split(String.trim(pin_line), "  ")
    assert pin_name == "affidavit_wasm.wasm"
    assert sha256(full) == pin_sha

    # module-attribute fallback: pristine bytes admit with a MISSING sidecar
    # (pin falls back to @artifact_sha256; the bytes must match it exactly).
    with_engine([path: @artifact, pin_path: "/nonexistent/pin.sha256"], fn start ->
      assert {:ok, _pid} = start
    end)
  end

  # ---------------------------------------------------------------------------
  # Fence 5 (lane 10): 16 MiB host cap refuses PRE-ALLOC — exactly at cap+1
  # the typed refusal {:error, :payload_too_large} fires before the guest
  # is touched (no af_alloc, no wedged guest heap).
  # ---------------------------------------------------------------------------

  @tag :lane10
  test "fence 5: 16_777_217-byte delta refuses {:error, :payload_too_large} pre-alloc" do
    with_engine([], fn start ->
      assert {:ok, pid} = start

      # cap + 1 byte: must be refused HOST-side, before any guest allocation.
      over = :binary.copy(<<0>>, 16_777_217)
      assert {:error, :payload_too_large} = WasmEngine.call_admit_and_seal(over, 0, 1, %{})

      # engine untouched: same pid, alive, and a sub-cap delta does NOT hit
      # the cap refusal (positive control — a cap that refused everything
      # would also pass the first assertion).
      assert Process.whereis(WasmEngine) == pid

      sub_cap = Jason.encode!(%{"op" => "capabilities", "n" => 1})
      refute match?({:error, :payload_too_large}, WasmEngine.call_admit_and_seal(sub_cap, 0, 1, %{}))

      # and a valid call still gets a real guest response afterwards
      assert {:ok, resp} = WasmEngine.call(pid, @valid_request)
      assert {:ok, %{"ok" => true}} = Jason.decode(resp)
    end)
  end

  # ---------------------------------------------------------------------------
  # Fence 6 (lane 10): mailbox-bound engine calls — 10 concurrent
  # call_admit_and_seal callers with DISTINCT input classes all resolve
  # typed within the timeout; each caller's result matches ITS OWN input
  # (replies cannot be crossed — no stale-reply poisoning, the write_mem
  # bug class). Interleaving is real: refused, valid and invalid-arity
  # callers are in flight simultaneously against one serialized mailbox.
  # ---------------------------------------------------------------------------

  @tag :lane10
  test "fence 6: 10 concurrent call_admit_and_seal resolve typed, no reply crossing" do
    with_engine([], fn start ->
      assert {:ok, pid} = start

      deltas = 1..8 |> Enum.map(&Jason.encode!(%{"op" => "seal_probe", "caller" => &1}))

      jobs =
        [
          {:oversized, fn -> WasmEngine.call_admit_and_seal(:binary.copy(<<0>>, 16_777_217), 0, 1, %{}) end},
          {:bad_modality, fn -> WasmEngine.call_admit_and_seal(~s({"op":"x"}), 0, 3, %{}) end}
        ] ++
          Enum.with_index(deltas, fn d, i ->
            {{:delta, i}, fn -> WasmEngine.call_admit_and_seal(d, 0, 1, %{}) end}
          end)

      results =
        jobs
        |> Task.async_stream(fn {_tag, fun} -> fun.() end,
          max_concurrency: 10,
          timeout: 15_000
        )
        |> Enum.zip(jobs)
        |> Enum.map(fn {{:ok, res}, {tag, _fun}} -> {tag, res} end)

      # every caller resolved typed within the timeout (a deadlock surfaces
      # as an exited task / timeout exit — the Enum above would raise).
      assert length(results) == 10

      Enum.each(results, fn {_tag, res} ->
        assert match?({:ok, _}, res) or match?({:error, _}, res),
               "untyped result: #{inspect(res)}"
      end)

      # no reply crossing: each caller's result matches its OWN input class
      assert Enum.all?(results, fn
               {:oversized, {:error, :payload_too_large}} -> true
               {:bad_modality, {:error, :engine_unavailable}} -> true
               {{:delta, _i}, res} -> match?({:ok, _}, res) or match?({:error, _}, res)
               _ -> false
             end),
             "reply crossed or misclassified: #{inspect(results, limit: 12)}"

      # at least one real guest seal resolved OK (interleaving with a live
      # ABI round-trip actually happened, not only client-side refusals)
      assert Enum.any?(results, fn
               {{:delta, _i}, res} -> match?({:ok, _}, res)
               _ -> false
             end),
             "no guest seal resolved OK: #{inspect(results, limit: 12)}"

      # engine state consistent after the burst
      assert Process.whereis(WasmEngine) == pid
      assert {:ok, _resp} = WasmEngine.call(pid, @valid_request)
    end)
  end

  # ---------------------------------------------------------------------------
  # Fence 7 (lane 10): crash-loop guard — a faulting call (engine hard-killed
  # mid-flight) is followed by typed refusals, never a raise, and a healthy
  # restart restores service. The second (post-crash) call is still typed-
  # correct.
  # ---------------------------------------------------------------------------

  @tag :lane10
  test "fence 7: faulting call then healthy call — second stays typed-correct" do
    # start_link/2 links the caller; a hard :kill would propagate to this
    # test process. Trap and flush — the kill must be observable ONLY as
    # typed refusals, never as a test-process crash (crash-loop face).
    Process.flag(:trap_exit, true)

    with_engine([], fn start ->
      assert {:ok, pid} = start

      # one healthy call to prove service, then the fault: hard-kill the
      # engine (no :normal exit, no cleanup) mid-run.
      assert {:ok, _resp} = WasmEngine.call(pid, @valid_request)
      Process.exit(pid, :kill)
      wait_until(fn -> is_nil(Process.whereis(WasmEngine)) end)
      flush_exits()

      # the next TWO calls are typed refusals; the test process survives
      # (no crash-loop) and the refusal is identical both times.
      assert {:error, :engine_unavailable} = WasmEngine.call(self(), @valid_request)
      assert {:error, :engine_unavailable} = WasmEngine.call_admit_and_seal(~s({"op":"x"}), 0, 1, %{})

      # healthy restart: the second (post-crash) generation still answers
      # typed-correct with a real guest response.
      assert {:ok, pid2} = typed_start([])
      assert pid2 != pid

      assert {:ok, resp} = WasmEngine.call(pid2, @valid_request)
      assert {:ok, %{"ok" => true, "abi_version" => 1, "module" => "affidavit-wasm"}} =
               Jason.decode(resp)
    end)
  end

  # ---------------------------------------------------------------------------
  # Fence 8 (lane 10): doctor degrade-not-crash — with the engine killed
  # mid-run and the artifact unreachable, Smalt.Enclave.Doctor.run/0
  # returns a typed WARN row (AFFIDAVIT_WASM_DEGRADED, aggregate DEGRADED),
  # never raises. Non-vacuity: the healthy configuration PASSes first, so
  # the WARN cannot be the check's only face.
  # ---------------------------------------------------------------------------

  @tag :lane10
  test "fence 8: doctor engine-killed mid-run degrades typed, never raises" do
    saved_path = Application.get_env(:smalt, :affidavit_wasm_path)
    saved_pin = Application.get_env(:smalt, :affidavit_wasm_pin_path)

    on_exit(fn ->
      if saved_path, do: Application.put_env(:smalt, :affidavit_wasm_path, saved_path)
      if saved_pin, do: Application.put_env(:smalt, :affidavit_wasm_pin_path, saved_pin)
    end)

    # W17/D1 repair (lane 614): restore the env INLINE, not only in on_exit.
    # on_exit callbacks run at case end; without an inline restore, the
    # put_env(missing) below poisoned every later with_engine([]) start in
    # the module (order-dependent {:error, :engine_unavailable}).
    try do
      stop_engine()

      # (a) healthy face: engine down but artifact reachable — the doctor's
      #     own engine_loads? boots it and the check PASSes.
      receipt_ok = Doctor.run()
      check_ok = Enum.find(receipt_ok["checks"], &(&1["domain"] == "affidavit_wasm"))
      assert check_ok["status"] == "PASS", "healthy face must PASS: #{inspect(check_ok)}"
      stop_engine()

      # (b) degraded face: engine killed + artifact unreachable.
      missing = Path.join(System.tmp_dir!(), "affidavit_absent_#{System.unique_integer()}.wasm")
      Application.put_env(:smalt, :affidavit_wasm_path, missing)

      receipt = Doctor.run()
      check = Enum.find(receipt["checks"], &(&1["domain"] == "affidavit_wasm"))

      assert check["status"] == "WARN"
      assert check["code"] == "AFFIDAVIT_WASM_DEGRADED"
      assert is_binary(check["details"]) and check["details"] != ""
      assert receipt["status"] == "DEGRADED"

      # typed remediation contract still resolves (fail-closed table, no raise)
      assert cmd = receipt["remediation_map"]["AFFIDAVIT_WASM_DEGRADED"]
      assert is_binary(cmd) and cmd != ""
    after
      if saved_path,
        do: Application.put_env(:smalt, :affidavit_wasm_path, saved_path),
        else: Application.delete_env(:smalt, :affidavit_wasm_path)

      if saved_pin,
        do: Application.put_env(:smalt, :affidavit_wasm_pin_path, saved_pin),
        else: Application.delete_env(:smalt, :affidavit_wasm_pin_path)
    end
  end

  # ---------------------------------------------------------------------------
  # Fence 9 (lane630, DEF-1): init refusals are observable — a forced init
  # fault (bogus artifact path) still returns the typed
  # {:error, :engine_unavailable} contract, AND the underlying init reason
  # is preserved: Logger.warning with the verbatim inspect (captured) plus
  # a :persistent_term last-refusal read back via last_init_refusal/0.
  # Non-vacuity: a stale prior refusal must not satisfy the assertion —
  # the bogus-path start must advance the recorded reason.
  # ---------------------------------------------------------------------------

  @tag :lane630
  test "fence 9: init fault keeps typed contract and preserves the real reason" do
    import ExUnit.CaptureLog

    # (a) fresh-process baseline: bogus artifact path forces an init fault.
    WasmEngine.reset_last_init_refusal()
    missing = Path.join(System.tmp_dir!(), "affidavit_absent_#{System.unique_integer()}.wasm")
    prev = WasmEngine.last_init_refusal()
    assert prev == :none

    logs =
      capture_log(fn ->
        assert {:error, :engine_unavailable} = typed_start(path: missing)
      end)

    # (b) typed caller contract unchanged...
    assert is_nil(Process.whereis(WasmEngine))

    # (c) ...and the underlying init reason is observable, not collapsed:
    #     enoent-class reason for the bogus path, advanced past any prior value.
    reason = WasmEngine.last_init_refusal()
    refute reason == prev, "init refusal not advanced — observability seam is vacuous"

    flat = reason |> inspect() |> String.downcase()

    assert flat =~ "missing" or flat =~ "enoent" or flat =~ "artifact",
           "expected an artifact/enoent-class init reason, got: #{inspect(reason)}"

    # (d) the same verbatim reason reached the log (Logger.warning, inspect form)
    logged = inspect(reason)
    assert logs =~ logged, "Logger.warning must carry the verbatim inspect of the reason"
  end

  # ---------------------------------------------------------------------------
  # Fence 10 (lane644, churn hardening): the bounded start retry must be
  # load-bearing only on the :engine_start_failed class. 5 start/kill cycles
  # with 10 parallel tasks interleaving bogus-path artifact refusals and
  # valid-path restarts racing the wasmtime NIF async-teardown window:
  #   - every bogus-path start refuses FAST (<100ms) and typed — the retry
  #     must never leak sleep onto the artifact-refusal path;
  #   - every valid start resolves to a live engine or an already-started
  #     registry (never a persistent fabricated unavailability);
  #   - after the hammering stops, one more valid start succeeds outright
  #     (eventual success within the retry bound).
  # ---------------------------------------------------------------------------

  @tag :lane644
  test "fence 10: restart hammer under parallel load — valid starts recover within the retry bound, artifact refusals stay fast" do
    missing = Path.join(System.tmp_dir!(), "affidavit_absent_#{System.unique_integer()}.wasm")
    stop_engine()
    flush_exits()

    all_results =
      Enum.map(1..5, fn _cycle ->
        stop_engine()

        tasks =
          Enum.map(1..10, fn i ->
            Task.async(fn ->
              t0 = System.monotonic_time(:millisecond)

              result =
                if rem(i, 2) == 0 do
                  # bogus artifact path — must refuse FAST, never retried
                  WasmEngine.start_link(path: missing)
                else
                  # valid start immediately after the kill — races the NIF
                  # teardown window the bounded retry covers
                  WasmEngine.start_link([])
                end

              {i, result, System.monotonic_time(:millisecond) - t0}
            end)
          end)

        Task.await_many(tasks, 15_000)
      end)

    flat = List.flatten(all_results)
    {valid, bogus} = Enum.split_with(flat, fn {i, _, _} -> rem(i, 2) == 1 end)

    # bogus-path artifact refusals: typed AND fast (no retry sleep leaked)
    Enum.each(bogus, fn {i, r, ms} ->
      assert {:error, :engine_unavailable} = r, "bogus start #{i}: #{inspect(r)}"
      assert ms < 100, "artifact refusal #{i} took #{ms}ms — retry leaked onto refusal path"
    end)

    # valid starts: live engine or already-started registry, never a hang or
    # a persistent unavailability
    Enum.each(valid, fn {i, r, ms} ->
      assert match?({:ok, _}, r) or match?({:error, {:already_started, _}}, r),
             "valid start #{i} did not resolve (#{ms}ms): #{inspect(r)}"
    end)

    # eventual success: after the hammering, a plain valid start succeeds
    stop_engine()
    flush_exits()

    assert {:ok, pid} = typed_start([])
    GenServer.stop(pid, :normal)
    WasmEngine.reset_last_init_refusal()
  end
end
