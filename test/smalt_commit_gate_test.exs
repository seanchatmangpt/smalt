defmodule Smalt.CommitGateTest do
  @moduledoc """
  GL28-2 `smalt_commit_gate_court` (spec §6) — pure-logic unit tier.

  Proves: a valid envelope commits; every §5 code fires on its trigger; the
  ungated method class passes through; the oversize boundary honors the
  16 MiB packet-4 cap; the validation chain is first-failure-wins in the
  shared contract order; the gate writes nothing (the replay ledger the
  caller holds is untouched by a gate call).

  Chicago discipline: no mocks — the gate's real collaborators are its own
  pure data (envelope map, MapSet ledger); assertions land on returned
  values and ledger state.
  """

  use ExUnit.Case, async: true

  alias Smalt.GraphlawEx.AdmissionGate

  @engine "gl-engine-digest-aaaa"
  @receipt String.duplicate("a", 64)
  @body "mutation-body-bytes"

  defp env(overrides \\ []) do
    Enum.into(overrides, %{
      admitted_mutation: true,
      payload_bytes: @body,
      receipt_blake3: @receipt,
      engine_digest: @engine,
      ocel_frame: %{event_class: :mutation_admitted}
    })
  end

  defp opts(overrides \\ []) do
    # Keyword.merge, not Enum.into: into on a keyword APPENDS the override
    # after the default, and Keyword.get/2 returns the first occurrence —
    # the override would be shadowed by the default.
    Keyword.merge([body: @body, engine_digest: @engine, seen_receipts: MapSet.new()], overrides)
  end

  defp code({:refused, code, _details}), do: code
  defp code(:ok), do: :ok

  ## ── ungated method passthrough (spec §3.1) ──────────────────────────────

  test "GET/HEAD/OPTIONS pass ungated even with no envelope and no opts" do
    for method <- ~w(GET HEAD OPTIONS) do
      assert AdmissionGate.gate(method, nil, []) == :ok
      assert AdmissionGate.gate(method, nil, body: "x") == :ok
    end
  end

  ## ── commit path ─────────────────────────────────────────────────────────

  test "valid envelope with body, engine digest and fresh ledger commits" do
    assert AdmissionGate.gate("PUT", env(), opts()) == :ok
    assert AdmissionGate.gate("POST", env(), opts()) == :ok
    assert AdmissionGate.gate("DELETE", env(), opts()) == :ok
  end

  test "commit path without a :body opt skips only the equality check" do
    assert AdmissionGate.gate("PUT", env(payload_bytes: "other"), engine_digest: @engine) == :ok
  end

  test "unknown method is fail-closed gated, never ungated" do
    assert code(AdmissionGate.gate("PATCH", nil, [])) == :smalt_no_receipt
    assert AdmissionGate.gate("PATCH", env(), opts()) == :ok
  end

  ## ── :smalt_no_receipt ───────────────────────────────────────────────────

  test "mutation with no envelope refuses :smalt_no_receipt" do
    assert {:refused, :smalt_no_receipt, %{envelope: nil}} =
             AdmissionGate.gate("POST", nil, opts())
  end

  test "non-map envelope refuses :smalt_no_receipt with the envelope class" do
    assert {:refused, :smalt_no_receipt, %{envelope_class: :binary}} =
             AdmissionGate.gate("POST", "not-a-map", opts())
  end

  test "envelope missing all keys refuses :smalt_no_receipt listing them" do
    {:refused, :smalt_no_receipt, %{missing_keys: missing}} =
      AdmissionGate.gate("POST", %{}, opts())

    assert Enum.sort(missing) == Enum.sort(AdmissionGate.envelope_keys())
  end

  test "envelope missing one key names it" do
    partial = Map.delete(env(), :ocel_frame)

    assert {:refused, :smalt_no_receipt, %{missing_keys: [:ocel_frame]}} =
             AdmissionGate.gate("POST", partial, opts())
  end

  test "nil or false key values count as missing" do
    for overrides <- [
          admitted_mutation: false,
          admitted_mutation: nil,
          payload_bytes: nil,
          receipt_blake3: nil,
          engine_digest: nil,
          ocel_frame: nil
        ] do
      assert code(AdmissionGate.gate("POST", env([overrides]), opts())) ==
               :smalt_no_receipt
    end
  end

  ## ── :smalt_payload_mismatch ─────────────────────────────────────────────

  test "envelope payload differing from the raw body refuses :smalt_payload_mismatch" do
    {:refused, :smalt_payload_mismatch, details} =
      AdmissionGate.gate("PUT", env(payload_bytes: "admitted-A"), opts(body: "sent-B"))

    assert details == %{payload_bytes: byte_size("admitted-A"), body: byte_size("sent-B")}
  end

  test "non-binary payload_bytes refuses :smalt_payload_mismatch, never crashes" do
    for bad <- [123, %{bytes: 3}, [1, 2, 3]] do
      {:refused, :smalt_payload_mismatch, %{reason: :payload_not_binary}} =
        AdmissionGate.gate("PUT", env(payload_bytes: bad), opts(body: @body))
    end
  end

  ## ── :smalt_oversize (packet-4 boundary) ─────────────────────────────────

  test "cap mirrors GraphlawEx.ABI.max_request_bytes/0" do
    assert AdmissionGate.max_payload() == GraphlawEx.ABI.max_request_bytes()
    assert AdmissionGate.max_payload() == 16 * 1024 * 1024
  end

  test "exactly 16 MiB commits (boundary inclusive)" do
    body = :binary.copy("x", AdmissionGate.max_payload())

    assert AdmissionGate.gate("PUT", env(payload_bytes: body), opts(body: body)) == :ok
  end

  test "16 MiB + 1 refuses :smalt_oversize with the cap in details" do
    body = :binary.copy("x", AdmissionGate.max_payload() + 1)

    refusal = AdmissionGate.gate("PUT", env(payload_bytes: body), opts(body: body))

    assert {:refused, :smalt_oversize, %{payload_bytes: size, max_payload: max}} = refusal
    assert size == AdmissionGate.max_payload() + 1
    assert max == AdmissionGate.max_payload()
  end

  ## ── :smalt_engine_drift ─────────────────────────────────────────────────

  test "envelope digest differing from the wired digest refuses :smalt_engine_drift" do
    {:refused, :smalt_engine_drift, details} =
      AdmissionGate.gate("PUT", env(engine_digest: "engine-B"), opts(engine_digest: "engine-A"))

    assert details == %{expected: "engine-A", actual: "engine-B"}
  end

  test "nil engine digest (not yet wired) fails closed as :smalt_engine_drift" do
    assert code(AdmissionGate.gate("PUT", env(), engine_digest: nil)) == :smalt_engine_drift
  end

  ## ── :smalt_receipt_invalid ──────────────────────────────────────────────

  test "malformed receipt hashes refuse :smalt_receipt_invalid" do
    bad_binary_receipts = [
      String.duplicate("a", 63),
      String.duplicate("a", 65),
      String.duplicate("a", 63) <> "g",
      String.upcase(String.duplicate("ab", 32))
    ]

    for bad <- bad_binary_receipts do
      {:refused, :smalt_receipt_invalid, %{receipt_blake3_class: :binary}} =
        AdmissionGate.gate("PUT", env(receipt_blake3: bad), opts())
    end

    {:refused, :smalt_receipt_invalid, %{receipt_blake3_class: :integer}} =
      AdmissionGate.gate("PUT", env(receipt_blake3: 12_345), opts())

    {:refused, :smalt_receipt_invalid, %{receipt_blake3_class: :map}} =
      AdmissionGate.gate("PUT", env(receipt_blake3: %{hash: @receipt}), opts())
  end

  test "receipt hash is 64 lowercase hex: mixed-case boundary is invalid, hex digits valid" do
    assert AdmissionGate.gate("PUT", env(receipt_blake3: String.duplicate("0", 64)), opts()) == :ok

    assert code(
             AdmissionGate.gate(
               "PUT",
               env(receipt_blake3: String.duplicate("a", 63) <> "A"),
               opts()
             )
           ) == :smalt_receipt_invalid
  end

  ## ── :smalt_receipt_replay_fail ──────────────────────────────────────────

  test "receipt already in the ledger refuses :smalt_receipt_replay_fail" do
    seen = MapSet.new([@receipt])

    assert {:refused, :smalt_receipt_replay_fail, %{receipt_blake3: @receipt}} =
             AdmissionGate.gate("PUT", env(), opts(seen_receipts: seen))
  end

  test "fresh receipt against a populated ledger commits" do
    seen = MapSet.new([String.duplicate("b", 64)])

    assert AdmissionGate.gate("PUT", env(), opts(seen_receipts: seen)) == :ok
  end

  test "absent ledger skips the replay check (shallow mode, spec §7 Q2)" do
    assert AdmissionGate.gate("PUT", env(), engine_digest: @engine, body: @body) == :ok
  end

  ## ── chain order: first failure wins (shared contract order) ─────────────

  test "envelope check precedes payload check" do
    # nil envelope AND an oversize body: no_receipt wins.
    assert code(AdmissionGate.gate("PUT", nil, body: String.duplicate("x", 100))) ==
             :smalt_no_receipt
  end

  test "payload check precedes engine check" do
    {:refused, :smalt_payload_mismatch, _} =
      AdmissionGate.gate(
        "PUT",
        env(payload_bytes: "other", engine_digest: "engine-B"),
        opts(body: @body, engine_digest: "engine-A")
      )
  end

  test "engine check precedes receipt check" do
    {:refused, :smalt_engine_drift, _} =
      AdmissionGate.gate(
        "PUT",
        env(engine_digest: "engine-B", receipt_blake3: "short"),
        opts(engine_digest: "engine-A")
      )
  end

  test "receipt check precedes replay check" do
    seen = MapSet.new(["short"])

    {:refused, :smalt_receipt_invalid, _} =
      AdmissionGate.gate("PUT", env(receipt_blake3: "short"), opts(seen_receipts: seen))
  end

  ## ── zero state mutation on refusal and commit ───────────────────────────

  test "gate never writes the caller's ledger (spec §3.6: zero mutation)" do
    seen = MapSet.new([@receipt])
    before = :erlang.phash2(seen)

    assert {:refused, :smalt_receipt_replay_fail, _} =
             AdmissionGate.gate("PUT", env(), opts(seen_receipts: seen))

    assert :erlang.phash2(seen) == before
    assert MapSet.size(seen) == 1
  end

  test "gate is deterministic: identical arguments, identical verdict" do
    assert AdmissionGate.gate("PUT", env(), opts()) ==
             AdmissionGate.gate("PUT", env(), opts())

    assert AdmissionGate.gate("PUT", env(payload_bytes: "z"), opts(body: "y")) ==
             AdmissionGate.gate("PUT", env(payload_bytes: "z"), opts(body: "y"))
  end
end
