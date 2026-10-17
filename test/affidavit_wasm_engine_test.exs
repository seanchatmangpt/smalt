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

  defp start_engine! do
    if Process.whereis(WasmEngine), do: :ok, else: start_supervised!(WasmEngine)
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
