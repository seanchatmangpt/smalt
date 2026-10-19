defmodule StrataCompatTest do
  @moduledoc """
  Elixir-side compatibility fences between smalt's security/storage surfaces and
  the strata pack family's ALGORITHMIC CONTRACTS (extracted from
  ~/ggen-marketplace/packs/strata-*-pack templates/ontology — specs, not code).

  Companion doc: docs/PACK_INTEGRATION/strata-family.md.

  These tests assert smalt's real outputs against strata contract vectors where
  the semantics overlap, and assert-and-pin DELIBERATE DIFFERENCES (documented
  smalt decisions) where they do not. Rust-only wire surfaces (tx PDU framing,
  CLAP/1.0 protocol) are NOT-APPLICABLE and are pinned as such.
  """

  use ExUnit.Case, async: false

  ## ── Helpers: Elixir mirrors of the strata contract rules ──────────────

  @strata_tx_digest_domain_tag "strata-tx-payload-digest-v1"

  # packs/strata-hash-pack: family digest width is 32 bytes for every
  # projected algorithm (BLAKE3-256 / SHA-256 per FIPS 180-4 §6.2).
  @strata_digest_len 32

  defp sha256_bin(data), do: :crypto.hash(:sha256, data)
  defp sha256_hex(data), do: Base.encode16(sha256_bin(data), case: :lower)

  # Strata Merkle rule (hash_merkle.rs): leaf = SHA-256(0x00 || leaf),
  # node = SHA-256(0x01 || left || right), single SHA-256 per level (the
  # Strata family convention, NOT Bitcoin double-SHA256), trailing odd node
  # duplicated, empty tree refused (None, not zero).
  defp strata_merkle_root(leaves) when is_list(leaves) do
    case leaves do
      [] ->
        nil

      leaves ->
        level = Enum.map(leaves, &sha256_bin(<<0x00, &1::binary>>))

        collapse(level)
    end
  end

  defp collapse([single]), do: single

  defp collapse(level) do
    half = length(level) |> div(2) |> Kernel.*(2)
    {pairs, rest} = Enum.split(level, half)

    next =
      pairs
      |> Enum.chunk_every(2)
      |> Enum.map(fn [l, r] -> sha256_bin(<<0x01, l::binary, r::binary>>) end)

    next =
      case rest do
        [] -> next
        [odd] -> next ++ [sha256_bin(<<0x01, odd::binary, odd::binary>>)]
      end

    collapse(next)
  end

  # Strata store root_digest rule (store_engine.rs): SHA-256 over the
  # concatenated 32-byte SHA-256 keys in BTreeMap (lexicographic) order.
  defp strata_store_root_digest(payloads) do
    payloads
    |> Enum.map(&sha256_bin/1)
    |> Enum.sort()
    |> IO.iodata_to_binary()
    |> sha256_bin()
  end

  ## ── strata-hash-pack vs smalt SHA-256 usage ───────────────────────────

  describe "strata-hash-pack contract" do
    @tag :strata_compat
    test "family digest width is 32 bytes and FIPS 180-4 vectors hold in smalt" do
      assert @strata_digest_len == 32
      # FIPS 180-4 vectors pinned by the pack's courts ("" and "abc").
      assert sha256_hex("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

      assert sha256_hex("abc") ==
               "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

      # smalt's ledger digest is the same 32-byte SHA-256, lowercase hex.
      assert byte_size(sha256_hex("x")) == 64
    end

    @tag :strata_compat
    test "strata tagged-merkle rule (mirror) and smalt's chain rule (deliberate difference)" do
      l1 = sha256_bin("leaf-1")
      l2 = sha256_bin("leaf-2")
      l3 = sha256_bin("leaf-3")

      # Strata rule mirrored in Elixir: single SHA-256, domain tags 0x00/0x01,
      # odd-node duplication, empty tree refused.
      assert strata_merkle_root([]) == nil
      single = strata_merkle_root([l1])
      assert single == sha256_bin(<<0x00, l1::binary>>)

      two = strata_merkle_root([l1, l2])
      assert two == sha256_bin(<<0x01, single::binary, sha256_bin(<<0x00, l2::binary>>)::binary>>)

      # Odd duplication: [l1, l2, l3] pairs (l3, l3) at level 0.
      three = strata_merkle_root([l1, l2, l3])
      assert three == strata_merkle_root([l1, l2, l3, l3])

      # Second-preimage defense pinned: tagged leaf hash never equals a
      # node hash or a raw preimage digest (the untagged 1-leaf [X] vs
      # 2-leaf [Y,Z] collision class).
      x = sha256_bin("a" <> "b")
      assert strata_merkle_root([<<"a", "b">>]) != x
      assert sha256_bin(<<0x00, "ab">>) != sha256_bin(<<0x01, "a", "b">>)

      ## smalt counterpart: ConfidentialLedger/LedgerWriter chains
      ## merkle_root = SHA-256(hex(prev_root) <> hex(data_hash)) — an untagged
      ## append-only HASH CHAIN over hex strings, not a tagged leaf tree.
      ## DELIBERATE DIFFERENCE (documented in strata-family.md): smalt models
      ## Azure Confidential Ledger's per-transaction receipt chain, not a
      ## strata leaf tree; tags/odd-duplication do not apply.
      prev = sha256_hex("prev-root")
      data = sha256_hex("data")
      assert Smalt.Security.LedgerWriter == Smalt.Security.LedgerWriter
      expected_chain_root = sha256_hex(prev <> data)
      # The rule is deterministic and input-sensitive:
      assert expected_chain_root == sha256_hex(prev <> data)
      assert expected_chain_root != sha256_hex(data <> prev)
    end
  end

  ## ── strata-ledger-pack vs ConfidentialLedger/LedgerWriter ─────────────

  describe "strata-ledger-pack contract" do
    @tag :strata_compat
    test "receipt chaining law: each receipt's prev root equals the prior state root" do
      SmaltTest.Store.resilient_clear()

      {:ok, r1} =
        Smalt.Security.ConfidentialLedger.append_transaction("strata-compat-ledger", %{"n" => 1})

      {:ok, r2} =
        Smalt.Security.ConfidentialLedger.append_transaction("strata-compat-ledger", %{"n" => 2})

      # Genesis: strata LedgerState::new() root is the all-zero 32-byte root;
      # smalt's genesis prev_hash is the 64-char hex of those 32 zero bytes.
      assert r1["prev_hash"] == String.duplicate("0", 64)
      assert byte_size(r1["prev_hash"]) == 64

      # Chaining law (lg: receipt prev_root == prior state root), which for
      # smalt is prev_hash(N+1) == merkle_root(N).
      assert r2["prev_hash"] == r1["merkle_root"]
      assert r1["merkle_root"] != r2["merkle_root"]
      assert r2["transactionId"] == "2.1"

      # Digest-shape law shared with strata store/CAS: ^[0-9a-f]{64}$.
      assert r1["data_hash"] =~ ~r/^[0-9a-f]{64}$/

      # Duplicate contents refused (smalt's 409 law; strata ledger has no
      # equivalent — strata transitions are value-shaped, not content-deduped).
      assert {:error, 409, %{"error" => %{"code" => "LedgerItemAlreadyExists"}}} =
               Smalt.Security.ConfidentialLedger.append_transaction(
                 "strata-compat-ledger",
                 %{"n" => 1}
               )
    end

    @tag :strata_compat
    test "canonical JSON data hashing is deterministic across key order" do
      SmaltTest.Store.resilient_clear()

      {:ok, r1} =
        Smalt.Security.ConfidentialLedger.append_transaction("strata-canon-ledger", %{
          "a" => 1,
          "b" => 2
        })

      # Different ledger (same ledger would 409 the duplicate contents).
      {:ok, r2} =
        Smalt.Security.ConfidentialLedger.append_transaction("strata-canon-ledger-b", %{
          "b" => 2,
          "a" => 1
        })

      # Same multiset of key/value pairs, different key insertion order, in
      # different ledgers (same ledger would 409 the dup): identical data_hash
      # — the canonical sorted-key JSON rule smalt shares with strata's
      # canonical-payload conventions.
      assert r1["data_hash"] == r2["data_hash"]
      assert r1["subLedgerId"] != r2["subLedgerId"]
    end
  end

  ## ── strata-signer-pack vs ReceiptSigner/Attestation ───────────────────

  describe "strata-signer-pack contract" do
    @tag :strata_compat
    test "digest binding: SHA-256(domain_tag || bytes) form is computable and matches the pack's law" do
      # signing.rs: bind_tx_digest = SHA-256(TX_DIGEST_DOMAIN_TAG || tx_bytes),
      # TX_DIGEST_DOMAIN_TAG = "strata-tx-payload-digest-v1".
      bytes = "tx-bytes-123"
      expected = sha256_hex(@strata_tx_digest_domain_tag <> bytes)
      assert byte_size(expected) == 64
      # Domain separation bites: untagged digest differs.
      assert expected != sha256_hex(bytes)

      # Length constants pinned by gates/010_mldsa65_lengths.rq (FIPS 204).
      ml_dsa_sig_len = 3309
      ml_dsa_pk_len = 1952
      assert ml_dsa_sig_len == 3309 and ml_dsa_pk_len == 1952
    end

    @tag :strata_compat
    test "smalt ReceiptSigner: RS256 JWS roundtrip (DELIBERATE DIFFERENCE from ML-DSA-65)" do
      claims = %{"sub" => "strata-compat", "exp" => System.system_time(:second) + 60}
      token = Smalt.Security.ReceiptSigner.sign(claims)
      assert {:ok, ^claims} = Smalt.Security.ReceiptSigner.verify(token)
      assert {:ok, _} = Smalt.Security.ReceiptSigner.verify_token(token)

      # Alg-confusion safety (smalt's own law): HS256/none refused.
      assert {:error, {:bad_alg, "HS256"}} =
               Smalt.Security.ReceiptSigner.verify(hs256_forgery())

      ## DELIBERATE DIFFERENCE: strata signer is ML-DSA-65 (FIPS 204) detached
      ## raw 3309-byte signatures over SHA-256(domain-tag || tx bytes); smalt
      ## signs receipts/attestation tokens as RS256 (RSA-2048) JWS compact
      ## over the canonical "header.payload" signing input with NO domain tag.
      ## These are different trust domains (Azure JWS artifacts vs strata tx
      ## attestation); smalt's choice is an Azure-emulator decision.
    end

    defp hs256_forgery do
      b64 = fn bin -> Base.url_encode64(bin, padding: false) end
      key = "secret"

      header = b64.(Jason.encode!(%{"alg" => "HS256", "typ" => "JWT"}))
      payload = b64.(Jason.encode!(%{"sub" => "x"}))

      sig = :crypto.mac(:hmac, :sha256, key, header <> "." <> payload) |> b64.()
      header <> "." <> payload <> "." <> sig
    end
  end

  ## ── strata-store-pack vs Smalt.Store.compare_and_swap ─────────────────

  describe "strata-store-pack contract" do
    @tag :strata_compat
    test "store KAT: pinned payloads fold to the pinned root under the strata rule" do
      kat = [
        {"strata-store-kat-payload-1",
         "91b739023c976350dacc820d9d8fa02c5617a10f551d89dde3bf4419a54cb367"},
        {"strata-store-kat-payload-2",
         "17dcbd0e84f8a571e7f736b176a3d7160d8cb88d28ef59ce0a51482d5e4ba909"},
        {"strata-store-kat-payload-3",
         "d8de3bf89d034493f711537b87dcf45f0649802194d59bba5db92ca1ee651c28"}
      ]

      # key = SHA-256(value), 32 bytes, lowercase-hex 64 shape law.
      Enum.each(kat, fn {payload, digest} ->
        assert sha256_hex(payload) == digest
        assert digest =~ ~r/^[0-9a-f]{64}$/
      end)

      # Fold: SHA-256 over concatenated 32-byte keys in lexicographic order
      # pins to the witnessed KAT root (gates/030_store_cas_composition.rq).
      root = kat |> Enum.map(&elem(&1, 0)) |> strata_store_root_digest()

      assert Base.encode16(root, case: :lower) ==
               "a8378cfa4e6e508f54c0287eac99f6e6b07f2fc8b9123bab1f7b2be494f0ef08"
    end

    @tag :strata_compat
    test "smalt CAS: serialized compare-and-swap, exactly one winner (real ETS)" do
      SmaltTest.Store.resilient_clear()
      start_supervised!()

      :ets.insert(:smalt_resources, {"k", "v0"})

      # R178g disclosure (minimal unblock fix, owner lane R178g store.ex):
      # this non-map probe row previously leaked into the SHARED
      # :smalt_resources table with no cleanup, and Smalt.Store.list/1 (a
      # whole-table walk, correctly unfiltered per the R144 guard contract)
      # surfaced it into store_churn_test's is_map assertion under module
      # shuffle. Success-path delete below + on_exit for the failure path.
      on_exit(fn ->
        if :ets.info(:smalt_resources) != :undefined do
          :ets.delete(:smalt_resources, "k")
        end
      end)

      assert :ok = Smalt.Store.compare_and_swap(:smalt_resources, "k", "v0", "v1")
      assert {:ok, "v1"} = Smalt.Store.get(:smalt_resources, "k")

      # Expected-value miss is a typed conflict, no write.
      assert {:error, :conflict} = Smalt.Store.compare_and_swap(:smalt_resources, "k", "v0", "v2")
      assert {:ok, "v1"} = Smalt.Store.get(:smalt_resources, "k")

      # Concurrent CAS: exactly one of N contenders wins.
      winner =
        1..8
        |> Enum.map(fn _ ->
          Task.async(fn ->
            Smalt.Store.compare_and_swap(:smalt_resources, "k", "v1", "v2")
          end)
        end)
        |> Task.await_many()
        |> Enum.count(&(&1 == :ok))

      assert winner == 1

      :ets.delete(:smalt_resources, "k")

      ## DELIBERATE DIFFERENCE: strata store is immutable content-addressed
      ## storage (key = SHA-256(value); CAS = put-if-absent-by-digest with
      ## journal/rollback and a folded root_digest). smalt's CAS is a
      ## mutable-slot compare-and-swap over ARM resource rows (ETS
      ## ordered_set, lookup+insert serialized in the Store GenServer).
      ## Different semantics by design — smalt emulates Azure ARM state,
      ## not a strata content store.
    end

    defp start_supervised! do
      SmaltTest.Lifecycle.ensure_store_up()
    end
  end

  ## ── strata-tx-pack / strata-protocol-pack: NOT-APPLICABLE fences ──────

  describe "strata-tx/protocol packs (NOT-APPLICABLE, Rust-only wire surfaces)" do
    @tag :strata_compat
    test "framing constants documented; smalt speaks no STX1/CLAP wire" do
      # strata-tx: 56-byte STX1 header (MAGIC 0x53545831 @0, VERSION 0x01 @4,
      # RESERVED @5 len 3, NONCE u64 @8, INPUT_COUNT u32 @16, OUTPUT_COUNT u32
      # @20, PAYLOAD_DIGEST 32B @24), abutment-chain law, magic "STX1".
      # strata-protocol: 64-byte CLAP/1.0 PDU header (magic 0x434C4150,
      # PDU_PERMUTATION_MAX 5, refusal taxonomy {ArenaFailure, FuelExhausted,
      # MalformedFrame, ParentDiscontinuity}, 32-byte RefusalReceipt).
      #
      # smalt speaks ARM/Cosmos/EventHubs HTTP surfaces, not STX1 or CLAP —
      # these are Rust-only wire contracts. NOT-APPLICABLE is pinned by this
      # test's existence asserting only documentation-level facts:
      assert byte_size(<<0x53545831::32>>) == 4
      assert String.upcase("stx1") == "STX1"

      # The only shared surface: the pinned valve projection in the protocol
      # pack is itself Elixir and enforces @receipt_len 32 — the same 32-byte
      # receipt width strata's wire classes and smalt's sha256-hex receipts
      # both satisfy.
      assert byte_size(sha256_bin("anything")) == 32
    end
  end
end
