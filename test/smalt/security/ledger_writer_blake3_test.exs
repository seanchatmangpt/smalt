# Lane 11 (v26.11.6): BLAKE3 chain-link retarget golden vectors + verify law.
#
# Shared fixture: verification/chain_link_vectors.json — generated through
# gates/blake3_ref.py (KAT-fenced at import) and asserted by three
# implementations (Elixir here, Go twin in
# posh/internal/receipt/chain_link_test.go, and the Python gate).
#
# Run: MIX_BUILD_ROOT=_build-l11 mix test test/smalt/security/ledger_writer_blake3_test.exs

defmodule Smalt.Test.Security.LedgerWriterBlake3Test do
  use ExUnit.Case, async: false

  alias Smalt.Security.LedgerWriter
  alias Smalt.Store

  @vectors File.read!("/Users/sac/smalt/verification/chain_link_vectors.json")
           |> Jason.decode!()
  @gen2 @vectors["link_vectors"]
  @gen1 @vectors["legacy_vectors"]

  # -- shared golden vectors ---------------------------------------------------

  test "link_digest matches the shared fixture for every gen-2 link" do
    for v <- @gen2 do
      got =
        LedgerWriter.link_digest(
          v["prev_root_hex"],
          v["seq"],
          v["data_hash_hex"],
          v["sub_ledger_id"]
        )

      assert got == v["link_digest_hex"], "mismatch on #{v["name"]}: #{got}"
    end

    assert @gen2 != []
  end

  test "legacy_link matches the gen-1 golden vectors" do
    for v <- @gen1 do
      got = LedgerWriter.legacy_link(v["prev_root_hex"], v["data_hash_hex"])
      assert got == v["link_digest_hex"], "mismatch on #{v["name"]}"
    end

    assert @gen1 != []
  end

  # -- encoding-spec (kills hex-fold mutants) -----------------------------------

  test "hex-TEXT fold diverges from the raw32-byte link law" do
    v = hd(@gen2)
    domain = @vectors["domain"]

    hex_fold =
      Smalt.Posh.Blake3.digest_prefixed(
        domain <>
          v["prev_root_hex"] <>
          <<v["seq"]::unsigned-big-integer-size(64)>> <>
          v["data_hash_hex"] <>
          v["sub_ledger_id"]
      )
      |> Base.encode16(case: :lower)

    refute hex_fold == v["link_digest_hex"]

    assert LedgerWriter.link_digest(
             v["prev_root_hex"],
             v["seq"],
             v["data_hash_hex"],
             v["sub_ledger_id"]
           ) == v["link_digest_hex"]
  end

  # -- gen-1 replay verify (legacy chain verifies forever) ----------------------

  test "gen-1 receipt (no chain_gen key) verifies under the legacy law" do
    v = Enum.fetch!(@gen1, 1)

    receipt = %{
      "transactionId" => "#{v["seq"]}.1",
      "subLedgerId" => v["sub_ledger_id"],
      "data_hash" => v["data_hash_hex"],
      "prev_hash" => v["prev_root_hex"],
      "merkle_root" => v["link_digest_hex"],
      "contents" => %{"k" => "lane11-b"}
    }

    assert LedgerWriter.verify_receipt(receipt) == :ok
  end

  test "gen-1 receipt with a tampered link refuses" do
    v = hd(@gen1)

    receipt = %{
      "transactionId" => "1.1",
      "subLedgerId" => v["sub_ledger_id"],
      "data_hash" => v["data_hash_hex"],
      "prev_hash" => v["prev_root_hex"],
      "merkle_root" => String.duplicate("a", 64),
      "contents" => %{"k" => "lane11-a"}
    }

    assert {:error, {:link_mismatch, _}} =
             LedgerWriter.verify_receipt(receipt)
  end

  # -- gen-2 verify_receipt ------------------------------------------------------

  test "gen-2 receipt verifies; single-field mutations refuse 1:1" do
    v = Enum.fetch!(@gen2, 1)

    receipt = %{
      "transactionId" => "#{v["seq"]}.1",
      "subLedgerId" => v["sub_ledger_id"],
      "chain_gen" => 2,
      "data_hash" => v["data_hash_hex"],
      "prev_hash" => v["prev_root_hex"],
      "merkle_root" => v["link_digest_hex"],
      "contents" => %{"k" => "lane11-b"}
    }

    assert LedgerWriter.verify_receipt(receipt) == :ok

    # seq mutation (transactionId no longer matches the digest-bound seq)
    bad_seq = %{receipt | "transactionId" => "#{v["seq"] + 1}.1"}
    assert {:error, {:link_mismatch, _}} = LedgerWriter.verify_receipt(bad_seq)

    # sub_ledger_id mutation
    bad_ledger = %{receipt | "subLedgerId" => "other-ledger"}
    assert {:error, {:link_mismatch, _}} =
             LedgerWriter.verify_receipt(bad_ledger)

    # chain_gen erase -> falls back to gen-1 law -> link mismatch
    gen_erased = Map.delete(receipt, "chain_gen")
    assert {:error, {:link_mismatch, _}} =
             LedgerWriter.verify_receipt(gen_erased)

    # chain_gen stamped backwards 2 -> 1 -> gen-1 law -> link mismatch
    wrong_gen = %{receipt | "chain_gen" => 1}
    assert {:error, {:link_mismatch, _}} = LedgerWriter.verify_receipt(wrong_gen)

    # unknown generation refuses typed
    assert {:error, {:unknown_chain_gen, 3}} =
             LedgerWriter.verify_receipt(%{receipt | "chain_gen" => 3})
  end

  test "tampered contents refuse via data_hash re-derivation" do
    v = hd(@gen2)

    receipt = %{
      "transactionId" => "#{v["seq"]}.1",
      "subLedgerId" => v["sub_ledger_id"],
      "chain_gen" => 2,
      "data_hash" => v["data_hash_hex"],
      "prev_hash" => v["prev_root_hex"],
      "merkle_root" => v["link_digest_hex"],
      "contents" => %{"k" => "tampered"}
    }

    assert {:error, {:data_hash_mismatch, _}} =
             LedgerWriter.verify_receipt(receipt)
  end

  # -- real append path (Chicago: real writer, real Store) ----------------------

  test "append mints a gen-2 receipt that self-verifies and chains" do
    ledger = "lane11-append-#{System.unique_integer([:positive])}"

    {:ok, r1} = LedgerWriter.append(ledger, %{"k" => "one"})
    {:ok, r2} = LedgerWriter.append(ledger, %{"k" => "two"})

    assert r1["chain_gen"] == 2
    assert r2["chain_gen"] == 2
    # data_hash stays sha256 of sorted-key compact JSON (link-only retarget)
    expected_dh =
      :crypto.hash(:sha256, Jason.encode!(%{"k" => "one"}))
      |> Base.encode16(case: :lower)

    assert r1["data_hash"] == expected_dh
    assert r2["prev_hash"] == r1["merkle_root"]
    assert LedgerWriter.verify_receipt(r1) == :ok
    assert LedgerWriter.verify_receipt(r2) == :ok

    # The gen-2 link really is BLAKE3, not the legacy sha256 fold.
    refute r1["merkle_root"] ==
             LedgerWriter.legacy_link(r1["prev_hash"], r1["data_hash"])
  end

  # -- seam continuity: gen-1 latest receipt -> gen-2 append --------------------

  test "gen-2 append chains off a raw-decoded legacy root (seam continuity)" do
    ledger = "lane11-seam-#{System.unique_integer([:positive])}"

    gen1_receipt = %{
      "transactionId" => "7.1",
      "subLedgerId" => ledger,
      "data_hash" => hd(@gen1)["data_hash_hex"],
      "prev_hash" => "0" |> String.duplicate(64),
      "merkle_root" => hd(@gen1)["link_digest_hex"],
      "contents" => %{"k" => "seam-legacy"}
    }

    Store.start_link([])
    Store.put(:smalt_ledger_meta, {:latest, ledger}, gen1_receipt)

    {:ok, r} = LedgerWriter.append(ledger, %{"k" => "seam-new"})

    assert r["chain_gen"] == 2
    assert r["prev_hash"] == gen1_receipt["merkle_root"]
    # The seam link is the gen-2 law applied to the raw-decoded legacy root.
    assert r["merkle_root"] ==
             LedgerWriter.link_digest(
               gen1_receipt["merkle_root"],
               r["transactionId"] |> String.split(".") |> hd() |> String.to_integer(),
               r["data_hash"],
               ledger
             )

    assert LedgerWriter.verify_receipt(r) == :ok
  end
end
