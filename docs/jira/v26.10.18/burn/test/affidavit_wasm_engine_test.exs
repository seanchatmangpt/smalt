defmodule Smalt.Affidavit.WasmEngineTest do
  @moduledoc """
  Anti-vacuity court for `Smalt.Affidavit.WasmEngine` (lane W4 subject).

  Fences (all against the real WASM artifact at priv/wasm, never a
  mock — Chicago discipline):

    1. missing-artifact path: a config-overridden bogus path makes
       `start_link/1` refuse with `{:error, :engine_unavailable}`;
    2. a real engine serves the v1 wire (capabilities) through the
       af_alloc/af_call/af_free C-ABI;
    3. the wire's typed refusal (unknown_op) is a typed code, not success
       — the flip proof: a known op answers ok:true on the same transport;
    4. blake3 commit round-trip: same bytes -> same commitment; one
       mutated byte -> different commitment (hash binding is real).
  """

  use ExUnit.Case, async: false

  alias Smalt.Affidavit.WasmEngine

  # Engine is a NAMED SINGLETON: when another suite already started it, a
  # supervisor child-spec start is rejected {:error, {:already_started, pid}}
  # — that is a SUCCESS (reuse), never a failure.
  defp start_engine! do
    if reusable_engine?(), do: :ok, else: supervised_start!()
  end

  defp reusable_engine? do
    case Process.whereis(WasmEngine) do
      nil ->
        false

      _pid ->
        try do
          match?({:ok, _}, WasmEngine.call_json(Jason.encode!(%{op: "capabilities"})))
        catch
          :exit, _ -> false
        end
    end
  end

  defp supervised_start! do
    start_supervised!(WasmEngine)
  rescue
    e in RuntimeError ->
      if reusable_engine?(), do: :ok, else: reraise(e, __STACKTRACE__)
  end

  defp wire(req_binary) do
    start_engine!()

    case WasmEngine.call_json(req_binary) do
      {:ok, resp} -> Jason.decode!(resp)
      {:error, :engine_unavailable} = err -> flunk("engine unavailable: #{inspect(err)}")
    end
  end

  defp commit_hex(payload) when is_binary(payload) do
    wire(Jason.encode!(%{op: "commit", payload: payload}))["commitment"]
  end

  test "missing artifact fails closed with {:error, :engine_unavailable}" do
    # v26.10.18 lib redesign: the app tree now owns the named engine via
    # WasmEngine.Supervisor's owner child, so a bare bogus-path start_link
    # hit the whereis passthrough ({:error, {:already_started, _}}) before
    # admission ever ran. A NORMAL stop is the typed seam that frees the
    # name: the owner classifies it as intentional and idles (no restart),
    # so the missing-artifact admission path is actually exercised. Tests
    # below re-arm through start_engine!/1 either way.
    if pid = Process.whereis(WasmEngine) do
      :ok = GenServer.stop(pid, :normal)

      SmaltTest.AssertEventually.eventually(
        fn ->
          if is_nil(Process.whereis(WasmEngine)), do: {:ok, :gone}, else: :retry
        end,
        observable: "engine name released after normal stop"
      )
    end

    assert {:error, :engine_unavailable} =
             WasmEngine.start_link(path: "/nonexistent/affidavit_wasm.wasm")
  end

  test "real artifact passes admission and serves the v1 wire" do
    start_engine!()

    {:ok, resp} = WasmEngine.call_json(Jason.encode!(%{op: "capabilities"}))
    caps = Jason.decode!(resp)

    assert caps["ok"] == true
    assert caps["abi_version"] == 1
    assert "verify" in caps["ops"]
    assert "jcs_canonicalize" in caps["ops"]
    assert "commit" in caps["ops"]
  end

  test "unknown op is a typed refusal, not success (flip witness)" do
    resp = wire(Jason.encode!(%{op: "definitely_not_an_op"}))

    assert resp["ok"] == false
    assert resp["error"]["code"] == "unknown_op"
    # flip: a known op answers ok:true on the same transport
    assert wire(Jason.encode!(%{op: "capabilities"}))["ok"] == true
  end

  test "commit round-trip: same bytes same commitment, mutated bytes flip it" do
    h1 = commit_hex("affidavit-payload")
    h2 = commit_hex("affidavit-payload")
    assert h1 == h2
    assert byte_size(h1) == 64

    h3 = commit_hex("affidavit-payload-mutated")
    assert h1 != h3
  end

  test "call_json with a non-binary request fails closed" do
    start_engine!()
    assert WasmEngine.call_json({:not_a_binary}) == {:error, :engine_unavailable}
  end

  test "call/2 with a nil pid and a dead engine fails closed" do
    assert WasmEngine.call(nil, "{}") == {:error, :engine_unavailable}
  end
end
