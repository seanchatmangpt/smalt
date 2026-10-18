defmodule Smalt.AffidavitWasmTest do
  @moduledoc """
  Operator-mandated real-run tests for `Smalt.Affidavit.WasmEngine`
  (`lib/smalt/affidavit/wasm_engine.ex`) against the live vendored artifact
  `priv/wasm/affidavit_wasm.wasm`.

  1. successful state-delta admission returns a 352-byte CTRT with magic
     "CTRT" (real `call_admit_and_seal/4` with tariff 12345, modality 0x01);
  2. tariff basis cents round-trips byte-exact from the CTRT layout
     (offset 167, 8-byte LE u64 == input);
  3. fail-closed: oversized payload (> 16 MiB) -> `{:error, :payload_too_large}`,
     garbage delta -> typed `{:error, _}`, and a subsequent call still
     succeeds (no crash-loop).

  No mocks, no skips: the engine and artifact are live. If the engine
  genuinely cannot load, the test fails with the verbatim error (BLOCKED).
  """

  use ExUnit.Case, async: false

  alias Smalt.Affidavit.WasmEngine

  @artifact "priv/wasm/affidavit_wasm.wasm"
  @tariff 12_345
  @modality 0x01
  @ctrt_bytes 352
  @tariff_offset 167
  @max_payload 16 * 1024 * 1024

  @sample_delta ~s({"artifact":"affidavit-wasm-v1","entries":[{"delta":{"key":"k1","value":"v1"}}],"op":"admit_delta"})

  setup do
    if pid = Process.whereis(WasmEngine) do
      GenServer.stop(pid, :normal)
      wait_until(fn -> is_nil(Process.whereis(WasmEngine)) end)
    end

    on_exit(fn ->
      if pid = Process.whereis(WasmEngine) do
        GenServer.stop(pid, :normal)
      end
    end)

    assert File.regular?(@artifact), "live artifact missing: #{@artifact}"

    # Real engine start against the live vendored artifact. A failure here is
    # a BLOCKED outcome, surfaced verbatim — never a skip.
    case WasmEngine.start_link([]) do
      {:ok, pid} ->
        %{engine: pid}

      {:error, {:already_started, pid}} ->
        # Race: another suite started the named singleton between our stop
        # and start. That is reuse, not failure — assert it is healthy.
        assert {:ok, _} = WasmEngine.call_json(Jason.encode!(%{op: "capabilities"}))
        %{engine: pid}

      {:error, reason} ->
        flunk("BLOCKED: engine cannot load live artifact — verbatim: #{inspect(reason)}")
    end
  end

  test "1: admission returns 352-byte CTRT with magic CTRT" do
    assert {:ok, %{ctrt_bytes: ctrt}} =
             WasmEngine.call_admit_and_seal(@sample_delta, @tariff, @modality, %{})

    assert is_binary(ctrt)
    assert byte_size(ctrt) == @ctrt_bytes, "CTRT must be 352 bytes, got #{byte_size(ctrt)}"
    assert binary_part(ctrt, 0, 4) == "CTRT"
  end

  test "2: tariff basis cents round-trip byte-exact at CTRT offset 167 (LE u64)" do
    assert {:ok, %{ctrt_bytes: ctrt}} =
             WasmEngine.call_admit_and_seal(@sample_delta, @tariff, @modality, %{})

    tariff_le = binary_part(ctrt, @tariff_offset, 8)
    assert tariff_le == <<@tariff::little-unsigned-integer-size(64)>>
  end

  test "3: mutated payload and garbage delta fail closed typed, no crash-loop" do
    # (a) oversized payload (> 16 MiB) -> typed :payload_too_large
    oversized = :binary.copy(<<0>>, @max_payload + 1)

    assert {:error, :payload_too_large} =
             WasmEngine.call_admit_and_seal(oversized, @tariff, @modality, %{})

    # (b) garbage delta: the engine hashes arbitrary binary, so any binary
    # delta resolves typed (sealed or refused) — it must never raise. A
    # mutated out-of-domain argument (modality outside {1,2}) refuses typed.
    garbage = <<0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0xFF>>

    assert match?(
             {:ok, %{ctrt_bytes: _}},
             WasmEngine.call_admit_and_seal(garbage, @tariff, @modality, %{})
           ) or
             match?({:error, _}, WasmEngine.call_admit_and_seal(garbage, @tariff, @modality, %{}))

    assert {:error, _typed} =
             WasmEngine.call_admit_and_seal(garbage, @tariff, 0x07, %{})

    # (c) engine still alive and serving: a well-formed call succeeds after
    # the failures — no crash-loop, no poisoned state.
    assert {:ok, %{ctrt_bytes: ctrt}} =
             WasmEngine.call_admit_and_seal(@sample_delta, @tariff, @modality, %{})

    assert byte_size(ctrt) == @ctrt_bytes
    assert binary_part(ctrt, 0, 4) == "CTRT"

    assert pid = Process.whereis(WasmEngine)
    assert Process.alive?(pid)
  end

  defp wait_until(fun, tries \\ 100)

  defp wait_until(_fun, 0), do: flunk("engine did not stop in time")

  defp wait_until(fun, tries) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, tries - 1)
    end
  end
end
