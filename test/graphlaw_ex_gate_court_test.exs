# GL28-2 — Smalt ingress commit-gate courts against the REAL graphlaw_ex
# bridge (real graphlaw wasm engine from PRIV_WASM) and the real ETS Store.
#
# Chicago: no mocks. The collaborator set is the real wasm artifact (the same
# module whose digest the envelope's engine_digest pins), the real
# canonical-N-Quads projection computed inside that module, real Ed25519
# signing (:crypto), real BLAKE3 (b3sum — the same tool the repo's wasm courts
# digest artifacts with), and the real Store ensemble. The receipt is minted
# by signing the payload's canonical blake3 with the court's Ed25519 test key;
# receipt_blake3 is BLAKE3 over the canonical receipt document (GL28-2-SMALT-
# WIRE-SPEC §2.2).
#
# Courts (GL28-2-SMALT-WIRE-SPEC §6, dispatch contract):
#   1. valid envelope -> :ok and the resource PUT lands in Store
#   2. one tampered payload byte -> :smalt_payload_mismatch, Store unchanged
#   3. missing receipt/envelope -> :smalt_no_receipt
#   4. replayed receipt_blake3 -> :smalt_receipt_replay_fail
#   5. oversize payload (16 MiB + 1) -> :smalt_oversize, no engine allocation
#   6. anti-vacuity: the gate disabled (config kill-switch) lets the SAME
#      tampered payload LAND — proving the gate was load-bearing
#
# Loud skip: a missing wasm artifact is a typed skip, never a faked pass;
# GRAPHLAW_REQUIRE_ENGINE=1 turns the skip into a failure (fail-closed gate).
#
# Context: solo (async: false — real shared ETS Store + one engine host).

defmodule Smalt.GraphlawEx.GateCourtTest do
  use ExUnit.Case, async: false

  alias Smalt.GraphlawEx.AdmissionGate
  alias Smalt.Store

  @wasm_path System.get_env("PRIV_WASM") ||
               Path.expand("priv/graphlaw/graphlaw.wasm", __DIR__)
  @require_engine System.get_env("GRAPHLAW_REQUIRE_ENGINE") == "1"

  @table :smalt_resources
  # Lane-unique keyspace prefix: every court's keys live under it.
  @prefix "gl282gatecourt"

  # Ed25519 court key: deterministic from a court seed (hw-signer pattern:
  # SHA-256 seed -> 32-byte Ed25519 seed). Compile-time constants.
  @seed :crypto.hash(:sha256, "gl282-gate-court-ed25519-seed")
  @key_id "gl282-court-test-key"

  defp keypair_pub, do: :crypto.generate_key(:eddsa, :ed25519, @seed) |> elem(0)
  defp keypair_priv, do: :crypto.generate_key(:eddsa, :ed25519, @seed) |> elem(1)

  setup_all do
    if File.regular?(@wasm_path), do: GraphlawEx.EngineLoad.purge_cache()
    :ok
  end

  setup do
    # The shipped gate posture (config/test.exs) is restored after every
    # court, flip or not — the kill-switch flip below must never leak.
    original_gate_env = Application.get_env(:smalt, :graphlaw_ex_gate)

    on_exit(fn ->
      case original_gate_env do
        nil -> Application.delete_env(:smalt, :graphlaw_ex_gate)
        env -> Application.put_env(:smalt, :graphlaw_ex_gate, env)
      end
    end)

    if File.regular?(@wasm_path) do
      # Real Store sandbox (shared ensemble; already-started tolerated).
      case GenServer.start_link(Store, []) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end

      # Real graphlaw_ex bridge over the REAL artifact, after Store
      # (sanctioned boot order). :unpinned — PRIV_WASM is not the vendored
      # artifact the MANIFEST pin covers.
      start_supervised!({GraphlawEx, wasm_path: @wasm_path, expected_sha256: :unpinned})

      assert {:ok, %{wasm_sha256: engine_digest}} = GraphlawEx.Host.info(GraphlawEx)
      assert is_binary(engine_digest) and byte_size(engine_digest) == 64

      # Baseline: the lane keyspace starts empty.
      assert [] = Store.list_prefix(@table, @prefix <> "/")

      {:ok, engine_digest: engine_digest}
    else
      message =
        "[SKIP] GL28-2 gate courts: no wasm artifact at #{@wasm_path} " <>
          "(set PRIV_WASM to the absolute path of the graphlaw wasm module). " <>
          "A loud skip is not a pass."

      if @require_engine, do: flunk(message)

      IO.puts(message)
      {:ok, engine_digest: nil}
    end
  end

  # Compile-time loud skip: a missing artifact tags every court below.
  unless File.regular?(@wasm_path) do
    @tag :skip
  end

  # ── Court 1: a valid envelope commits and the resource PUT lands ────────
  test "valid envelope: gate :ok and the resource PUT lands in Store", ctx do
    key = resource_key("valid")
    on_exit(fn -> purge(key) end)

    payload = resource_payload(key, "v1")
    envelope = mint!(payload, ctx.engine_digest, key)

    assert :ok =
             commit("PUT", key, payload, envelope,
               body: payload,
               engine_digest: ctx.engine_digest,
               seen_receipts: MapSet.new()
             )

    # Real readback: the record the caller PUT is the record in Store.
    assert {:ok, record} = Store.get(@table, key)
    assert record["payload_blake3"] == blake3_hex(payload)
    assert record["receipt_blake3"] == envelope.receipt_blake3
  end

  # ── Court 2: one tampered byte -> :smalt_payload_mismatch, zero mutation ─
  test "tampered payload byte refuses typed and the Store readback is unchanged", ctx do
    key = resource_key("tamper")
    on_exit(fn -> purge(key) end)

    payload = resource_payload(key, "v1")
    envelope = mint!(payload, ctx.engine_digest, key)

    tampered = flip_one_byte(payload)

    assert {:refused, :smalt_payload_mismatch, details} =
             AdmissionGate.gate("PUT", envelope,
               body: tampered,
               engine_digest: ctx.engine_digest,
               seen_receipts: MapSet.new()
             )

    assert details.payload_bytes == byte_size(payload)
    assert details.body == byte_size(tampered)

    # Zero state mutation: the refused request leaves the keyspace empty.
    assert :error = Store.get(@table, key)
    assert [] = Store.list_prefix(@table, @prefix <> "/")
  end

  # ── Court 3: a missing receipt refuses :smalt_no_receipt ────────────────
  test "mutation without a receipt (nil and key-less envelope) refuses :smalt_no_receipt",
       ctx do
    payload = resource_payload(resource_key("noreceipt"), "v1")

    assert {:refused, :smalt_no_receipt, %{envelope: nil}} =
             AdmissionGate.gate("PUT", nil,
               body: payload,
               engine_digest: ctx.engine_digest
             )

    # The map form of the 5-tuple missing the receipt key is the same class.
    partial = %{admitted_mutation: true, payload_bytes: payload}

    assert {:refused, :smalt_no_receipt, %{missing_keys: missing}} =
             AdmissionGate.gate("PUT", partial,
               body: payload,
               engine_digest: ctx.engine_digest
             )

    assert :receipt_blake3 in missing
  end

  # ── Court 4: a replayed receipt refuses :smalt_receipt_replay_fail ──────
  test "replayed receipt_blake3 is refused on the second presentation", ctx do
    key = resource_key("replay")
    on_exit(fn -> purge(key) end)

    payload = resource_payload(key, "v1")
    envelope = mint!(payload, ctx.engine_digest, key)

    ledger = MapSet.new()

    # First presentation: fresh receipt passes the gate; the caller commits,
    # then records the receipt into the ledger (spec §3.5 — post-commit).
    assert :ok =
             AdmissionGate.gate("PUT", envelope,
               body: payload,
               engine_digest: ctx.engine_digest,
               seen_receipts: ledger
             )

    Store.put(@table, key, committed_record(payload, envelope))
    ledger = MapSet.put(ledger, envelope.receipt_blake3)

    # Second presentation of the SAME receipt: typed replay refusal.
    assert {:refused, :smalt_receipt_replay_fail, %{receipt_blake3: replayed}} =
             AdmissionGate.gate("PUT", envelope,
               body: payload,
               engine_digest: ctx.engine_digest,
               seen_receipts: ledger
             )

    assert replayed == envelope.receipt_blake3

    # Zero mutation on the refusal: the committed v1 record is untouched.
    assert {:ok, record} = Store.get(@table, key)
    assert record["receipt_blake3"] == envelope.receipt_blake3
    assert record["revision"] == "v1"
  end

  # ── Court 5: oversize body -> :smalt_oversize, no engine allocation ─────
  test "16 MiB + 1 body refuses :smalt_oversize at the packet-4 cap", ctx do
    cap = AdmissionGate.max_payload()
    assert cap == GraphlawEx.ABI.max_request_bytes()

    # The turnstile cannot admit a body above the cap (the ABI refuses before
    # any engine allocation), so this envelope's receipt is minted over the
    # raw body bytes — the subject is the Smalt-side cap refusal, which must
    # fire before the engine is consulted (spec §6 smalt_oversize_court).
    payload = :crypto.strong_rand_bytes(16) <> String.duplicate("a", cap - 15)

    signature = :crypto.sign(:eddsa, :none, raw_digest(payload), [keypair_priv(), :ed25519])

    receipt_doc =
      receipt_document(
        payload_blake3: blake3_hex(payload),
        engine_sha256: ctx.engine_digest,
        key_id: @key_id,
        signature_hex: Base.encode16(signature, case: :lower)
      )

    envelope = %{
      admitted_mutation: true,
      payload_bytes: payload,
      receipt_blake3: blake3_hex(receipt_doc),
      engine_digest: ctx.engine_digest,
      ocel_frame: ocel_frame("oversize")
    }

    assert {:refused, :smalt_oversize, details} =
             AdmissionGate.gate("PUT", envelope,
               body: payload,
               engine_digest: ctx.engine_digest
             )

    assert details.max_payload == cap
    assert details.payload_bytes == byte_size(payload)
  end

  # ── Court 6 (anti-vacuity): gate disabled -> the SAME tampered payload ──
  # LANDS. A gate that cannot be switched off cannot prove it was
  # load-bearing; a flip that does not land is a vacuous court (the config
  # kill-switch, not a code edit, is the sanctioned inversion).
  test "gate inverted (enabled: false) lets the tampered payload land", ctx do
    key = resource_key("flip")
    on_exit(fn -> purge(key) end)

    payload = resource_payload(key, "v1")
    envelope = mint!(payload, ctx.engine_digest, key)
    tampered = flip_one_byte(payload)

    # BASELINE: gate enabled (config/test.exs posture) -> typed refusal; the
    # caller helper never reaches Store.
    assert Application.get_env(:smalt, :graphlaw_ex_gate)[:enabled] == true

    assert {:refused, :smalt_payload_mismatch, _} =
             commit("PUT", key, tampered, envelope,
               body: tampered,
               engine_digest: ctx.engine_digest,
               seen_receipts: MapSet.new()
             )

    assert :error = Store.get(@table, key)

    # FLIP: the config kill-switch disables the gate -> the SAME tampered
    # payload commits and lands in Store.
    Application.put_env(:smalt, :graphlaw_ex_gate, enabled: false)

    assert :ok =
             commit("PUT", key, tampered, envelope,
               body: tampered,
               engine_digest: ctx.engine_digest,
               seen_receipts: MapSet.new()
             )

    assert {:ok, record} = Store.get(@table, key)
    assert record["payload_blake3"] == blake3_hex(tampered)
  end

  ## ── caller flow (spec §3 law: gate -> commit -> record) ────────────────

  # The caller-side commit law the router seam implements: consult the gate
  # config kill-switch, gate the mutation, commit only on :ok. Zero writes
  # on any refusal.
  defp commit(method, key, body, envelope, opts) do
    if Application.get_env(:smalt, :graphlaw_ex_gate, [])[:enabled] do
      case AdmissionGate.gate(method, envelope, opts) do
        :ok ->
          :ok = Store.put(@table, key, committed_record(body, envelope))
          :ok

        {:refused, _, _} = refused ->
          refused
      end
    else
      # Gate disabled: the mutation commits ungated (the anti-vacuity leg).
      :ok = Store.put(@table, key, committed_record(body, envelope))
      :ok
    end
  end

  ## ── envelope minting over the REAL bridge ──────────────────────────────

  # Mint a full admission envelope: project the payload through the REAL
  # engine (canonical op), BLAKE3 the canonical N-Quads ("the payload's
  # canonical blake3"), sign the digest with the court's Ed25519 test key,
  # and fold the canonical receipt document into receipt_blake3 (spec §2.2).
  # Every leg is real.
  defp mint!(payload, engine_digest, key) do
    {:ok, canonical} =
      GraphlawEx.Capability.API.canonical(
        [data: %{text: payload, dialect: "turtle"}],
        server: GraphlawEx
      )

    assert canonical.quads >= 1
    assert is_binary(canonical.nquads) and canonical.nquads != ""

    payload_blake3 = blake3_hex(canonical.nquads)
    raw = Base.decode16!(payload_blake3, case: :lower)

    signature = :crypto.sign(:eddsa, :none, raw, [keypair_priv(), :ed25519])

    # Mint self-check: the signature verifies under the court's public key.
    assert :crypto.verify(:eddsa, :none, raw, signature, [keypair_pub(), :ed25519])

    receipt_doc =
      receipt_document(
        payload_blake3: payload_blake3,
        engine_sha256: engine_digest,
        key_id: @key_id,
        signature_hex: Base.encode16(signature, case: :lower)
      )

    envelope = %{
      admitted_mutation: true,
      payload_bytes: payload,
      receipt_blake3: blake3_hex(receipt_doc),
      engine_digest: engine_digest,
      ocel_frame: ocel_frame(key)
    }

    # Wire-shape check: exactly the 5 envelope keys, all truthy (spec §2).
    assert MapSet.new(AdmissionGate.envelope_keys()) == MapSet.new(Map.keys(envelope))

    envelope
  end

  # Canonical receipt document: deterministic text binding the payload
  # digest, engine identity, signing key and signature — the fold input for
  # receipt_blake3 (spec §2.2 BLAKE3(Canon(receipt))).
  defp receipt_document(opts) do
    Enum.join(
      [
        "graphlaw-ex.receipt/v1",
        "payload_blake3:#{opts[:payload_blake3]}",
        "engine_sha256:#{opts[:engine_sha256]}",
        "key_id:#{opts[:key_id]}",
        "signature:#{opts[:signature_hex]}"
      ],
      "\n"
    )
  end

  defp raw_digest(payload), do: Base.decode16!(blake3_hex(payload), case: :lower)

  # BLAKE3 over arbitrary bytes via the real b3sum tool (the same tool the
  # repo's wasm courts use for artifact digests). Unique temp file per call,
  # removed after the digest.
  defp blake3_hex(bytes) do
    path =
      Path.join(
        System.tmp_dir!(),
        "gl282-court-blake3-#{:os.system_time(:native)}-#{:erlang.unique_integer([:positive])}"
      )

    File.write!(path, bytes)

    try do
      {out, 0} = System.cmd("b3sum", [path])
      String.slice(out, 0, 64)
    after
      File.rm(path)
    end
  end

  ## ── fixtures ────────────────────────────────────────────────────────────

  # The mutation body: a Turtle document naming the resource under the lane
  # keyspace. payload_bytes is the exact body the turnstile admitted (§2.1).
  defp resource_payload(key, revision) do
    """
    @prefix sm: <https://smalt.dev/gl282/> .
    <https://smalt.dev/gl282/resource/#{key}> sm:revision "#{revision}" ; sm:body "#{key}" .
    """
  end

  defp resource_key(suffix), do: "#{@prefix}/#{suffix}"

  defp committed_record(payload, envelope) do
    %{
      "payload_blake3" => blake3_hex(payload),
      "receipt_blake3" => envelope.receipt_blake3,
      "revision" => envelope.ocel_frame["revision"],
      "admitted_by" => "graphlaw_ex"
    }
  end

  defp ocel_frame(key) do
    %{"class" => "mutation", "resource" => key, "revision" => "v1", "method" => "PUT"}
  end

  defp flip_one_byte(payload) do
    <<front::binary-size(8), byte::integer-size(8), rest::binary>> = payload
    <<front::binary, :erlang.bxor(byte, 0x01)::integer-size(8), rest::binary>>
  end

  defp purge(key), do: Store.delete(@table, key)
end
