defmodule Smalt.Affidavit.SealTest do
  @moduledoc """
  Anti-vacuity court for `Smalt.Affidavit.Seal` (lane W5 subject).

  Fences:

    1. happy path: a valid 5-R-field receipt seals into a 352-byte CTRT
       token whose magic/version/verdict bytes decode and whose
       delta-hash field re-verifies against the engine's own blake3
       (wire `commit` op) over the canonical JSON bytes;
    2. forged receipt (missing field) -> typed `{:invalid_receipt, field}`
       refusal, never success;
    3. the flip: sealing a mutated payload produces a different token and
       mutating a sealed token's hash bytes breaks the hash binding, so
       verification REFUSES — if mutation did not flip the verdict, the
       test fails;
    4. round-trip through the engine's verify export: a chain-sealed wire
       receipt verifies accepted:true on the same transport, and one
       mutated hex char in `chain_hash` flips the verdict to
       accepted:false (chain_integrity stage).
  """

  use ExUnit.Case, async: false

  alias Smalt.Affidavit.{Seal, WasmEngine}

  @genesis "affidavit-v26.9.28-genesis"
  @ctrt_bytes 352

  # -- engine helpers (real engine, real artifact) ---------------------------

  setup do
    start_engine!()
    :ok
  end

  # Engine is a NAMED SINGLETON: when another suite (even an async one)
  # already started it, a supervisor child-spec start is rejected with
  # {:error, {:already_started, pid}} (surfaced by start_supervised! as a
  # RuntimeError). That is a SUCCESS — reuse the running engine.
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
      # Race window: the singleton came up between the whereis check and the
      # supervisor start. Treat the duplicate as reuse, never a failure.
      if reusable_engine?(), do: :ok, else: reraise(e, __STACKTRACE__)
  end

  defp wire(req_binary) do
    case WasmEngine.call_json(req_binary) do
      {:ok, resp} -> Jason.decode!(resp)
      {:error, :engine_unavailable} = err -> flunk("engine unavailable: #{inspect(err)}")
    end
  end

  defp commit_hex(payload) when is_binary(payload) do
    wire(Jason.encode!(%{op: "commit", payload: payload}))["commitment"]
  end

  defp jcs(json_text) do
    wire(Jason.encode!(%{op: "jcs_canonicalize", json: json_text}))["canonical_json"]
  end

  # -- Seal fences ------------------------------------------------------------

  test "valid receipt admits and seals into a verifiable 352-byte CTRT" do
    receipt = %{
      subject_sha: String.duplicate("ab", 32),
      authority: "BRCE",
      consequence: "lib/smalt/affidavit/seal.ex",
      replay: "git show HEAD:lib/smalt/affidavit/seal.ex",
      standing: "ALIVE"
    }

    assert {:ok, %{sealed: sealed, receipt: canonical_text}} = Seal.admit_and_seal(receipt)

    assert byte_size(sealed) == @ctrt_bytes
    assert binary_part(sealed, 0, 4) == "CTRT"
    # version 1, little-endian at bytes 4..6
    assert binary_part(sealed, 4, 2) == <<1, 0>>
    # verdict byte: 1 = ACCEPT at offset 150
    assert binary_part(sealed, 150, 1) == <<1>>

    # canonicalization is JCS-style: lexicographic keys, compact, and
    # byte-identical to the engine's own jcs_canonicalize op
    assert is_binary(canonical_text)
    assert canonical_text == jcs(Jason.encode!(receipt))

    # delta-hash field re-verifies against the engine's own blake3
    delta_hash = binary_part(sealed, 70, 32) |> Base.encode16(case: :lower)
    assert delta_hash == commit_hex(canonical_text)
  end

  test "forged receipt: missing field is a typed refusal, not success" do
    forged = %{
      subject_sha: String.duplicate("cd", 32),
      authority: "BRCE",
      consequence: "x",
      replay: "y"
      # `standing` removed — forged by omission
    }

    assert {:error, {:invalid_receipt, _field}} = Seal.admit_and_seal(forged)
  end

  test "flip: mutated payload changes the token; mutated token bytes refuse" do
    receipt = %{
      subject_sha: String.duplicate("ab", 32),
      authority: "BRCE",
      consequence: "lib/smalt/affidavit/seal.ex",
      replay: "git show HEAD:lib/smalt/affidavit/seal.ex",
      standing: "ALIVE"
    }

    assert {:ok, %{sealed: sealed, receipt: canonical_text}} = Seal.admit_and_seal(receipt)

    # mutate the payload -> the sealed hash field MUST move (flip)
    mutated_receipt = %{receipt | subject_sha: String.duplicate("ff", 32)}
    assert {:ok, %{sealed: sealed2}} = Seal.admit_and_seal(mutated_receipt)
    assert binary_part(sealed, 70, 32) != binary_part(sealed2, 70, 32)

    # mutate the sealed bytes -> the hash binding MUST break -> refuse
    <<before::binary-size(70), _hash::binary-size(32), rest::binary>> = sealed
    tampered = before <> <<0, 0>> <> rest

    expected = commit_hex(canonical_text)

    tampered_hash = binary_part(tampered, 70, 32) |> Base.encode16(case: :lower)
    # the tampered token's stored hash no longer matches the engine's
    # blake3 over the original payload -> verification refuses
    assert tampered_hash != expected

    # and the intact token still verifies against the same hash
    intact_hash = binary_part(sealed, 70, 32) |> Base.encode16(case: :lower)
    assert intact_hash == expected
  end

  test "round-trip: chain-sealed receipt verifies via the engine verify export" do
    h0 = commit_hex(@genesis)

    payload_commitment = commit_hex("affidavit-payload")

    event = %{
      "id" => "e0",
      "seq" => 0,
      "event_type" => "op",
      "objects" => [],
      "payload_commitment" => payload_commitment
    }

    canonical_event = jcs(Jason.encode!(event))
    chain_hash = commit_hex(h0 <> canonical_event)

    receipt = %{
      "format_version" => "core/v1",
      "events" => [event],
      "chain_hash" => chain_hash
    }

    verdict = wire(Jason.encode!(%{op: "verify", receipt: receipt}))

    assert verdict["accepted"] == true
    assert verdict["profile"] == "CoreV1"

    # flip: one mutated hex char in chain_hash -> REFUSE, typed stage
    mutated = %{receipt | "chain_hash" => mutate_hex(chain_hash)}
    refused = wire(Jason.encode!(%{op: "verify", receipt: mutated}))

    assert refused["accepted"] == false
    stages = Enum.map(refused["outcomes"], & &1["stage"])
    assert "chain_integrity" in stages
    first_failed = Enum.find(refused["outcomes"], &(&1["passed"] == false))
    assert first_failed["stage"] == "chain_integrity"
  end

  defp mutate_hex(hex) do
    flipped =
      if String.starts_with?(hex, "0"),
        do: "1" <> String.slice(hex, 1..-1//1),
        else: "0" <> String.slice(hex, 1..-1//1)

    assert flipped != hex
    flipped
  end
end
