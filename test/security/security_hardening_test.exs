defmodule Smalt.Security.SecurityHardeningTest do
  use ExUnit.Case, async: false

  alias Smalt.Security.{Attestation, ConfidentialLedger, ReceiptSigner}
  alias Smalt.Store

  @measurement String.duplicate("ab", 32)
  @zero String.duplicate("0", 64)

  setup do
    if :ets.info(:smalt_ledger_meta) == :undefined do
      start_supervised!(Store)
    end

    Store.clear()
    :ok
  end

  ## ReceiptSigner

  describe "ReceiptSigner" do
    test "sign/verify round-trips claims" do
      claims = %{"sub" => "ledger-1", "n" => 42, "exp" => System.system_time(:second) + 60}
      token = ReceiptSigner.sign(claims)
      assert {:ok, ^claims} = ReceiptSigner.verify(token)
    end

    test "verify_token enforces exp" do
      expired = %{"exp" => System.system_time(:second) - 10}
      assert {:error, :token_expired} = ReceiptSigner.verify_token(ReceiptSigner.sign(expired))

      fresh = %{"exp" => System.system_time(:second) + 60}
      assert {:ok, _} = ReceiptSigner.verify_token(ReceiptSigner.sign(fresh))
    end

    test "rejects HS256 alg confusion" do
      claims = %{"exp" => System.system_time(:second) + 60, "sub" => "attacker"}

      header = Base.url_encode64(Jason.encode!(%{"alg" => "HS256", "typ" => "JWT"}), padding: false)
      payload = Base.url_encode64(Jason.encode!(claims), padding: false)

      forged_sig =
        :crypto.mac(:hmac, :sha256, "attacker-controlled-secret", header <> "." <> payload)
        |> Base.url_encode64(padding: false)

      assert {:error, {:bad_alg, "HS256"}} =
               ReceiptSigner.verify(header <> "." <> payload <> "." <> forged_sig)
    end

    test "rejects alg none" do
      header = Base.url_encode64(Jason.encode!(%{"alg" => "none"}), padding: false)
      payload = Base.url_encode64(Jason.encode!(%{"exp" => 9_999_999_999}), padding: false)

      assert {:error, {:bad_alg, "none"}} = ReceiptSigner.verify(header <> "." <> payload <> ".")
    end

    test "rejects tampered signature" do
      claims = %{"sub" => "x", "exp" => System.system_time(:second) + 60}
      token = ReceiptSigner.sign(claims)

      [h, p, _sig] = String.split(token, ".", parts: 3)
      forged = :crypto.strong_rand_bytes(256) |> Base.url_encode64(padding: false)

      assert {:error, :bad_signature} = ReceiptSigner.verify(h <> "." <> p <> "." <> forged)
    end

    test "rejects malformed tokens" do
      assert {:error, :invalid_token} = ReceiptSigner.verify("garbage")
      assert {:error, :invalid_token} = ReceiptSigner.verify(42)
    end
  end

  ## Attestation

  describe "Attestation" do
    test "in-baseline measurement yields signed compliant token" do
      Application.put_env(:smalt, :maa_measurement_baseline, [@measurement])

      assert {:ok, token, claims} = Attestation.attest_enclave(%{"measurement" => @measurement})

      assert claims["x-ms-compliance-status"] == "azure-compliant-cvm"
      assert claims["x-ms-attestation-type"] == "sevsnpvm"
      assert claims["x-ms-isolation-tee"] == "AMD-SEV-SNP"

      assert {:ok, verified} = Attestation.verify_token(token)
      assert verified["x-ms-compliance-status"] == "azure-compliant-cvm"

      Application.delete_env(:smalt, :maa_measurement_baseline)
    end

    test "measurement in Store baseline table is attested" do
      Store.put(:smalt_attestation_baseline, @measurement, %{"source" => "cvm-image"})

      assert {:ok, _token, claims} =
               Attestation.attest_enclave(%{"measurement" => @measurement})

      assert claims["x-ms-compliance-status"] == "azure-compliant-cvm"
    end

    test "out-of-baseline measurement fails with 400 attestationFailedVerdict" do
      Application.delete_env(:smalt, :maa_measurement_baseline)

      assert {:error, 400, "attestationFailedVerdict"} =
               Attestation.attest_enclave(%{"measurement" => String.duplicate("cd", 32)})
    end

    test "malformed measurement (not hex64) fails" do
      assert {:error, 400, "attestationFailedVerdict"} =
               Attestation.attest_enclave(%{"measurement" => "tooshort"})

      assert {:error, 400, "attestationFailedVerdict"} = Attestation.attest_enclave(%{})
    end

    test "verify_token rejects tampered attestation token" do
      Application.put_env(:smalt, :maa_measurement_baseline, [@measurement])
      {:ok, token, _} = Attestation.attest_enclave(%{"measurement" => @measurement})
      Application.delete_env(:smalt, :maa_measurement_baseline)

      [h, p, sig] = String.split(token, ".", parts: 3)
      # Flip a payload byte but keep the original signature.
      tampered_payload = p <> "x"

      assert {:error, _} =
               Attestation.verify_token(h <> "." <> tampered_payload <> "." <> sig)
    end
  end

  ## ConfidentialLedger

  describe "ConfidentialLedger" do
    test "appends with monotonic tx ids and chained merkle roots" do
      {:ok, r1} = ConfidentialLedger.append_transaction("ledger-a", %{"n" => 1})
      {:ok, r2} = ConfidentialLedger.append_transaction("ledger-a", %{"n" => 2})
      {:ok, r3} = ConfidentialLedger.append_transaction("ledger-a", %{"n" => 3})

      assert r1["transactionId"] == "1.1"
      assert r2["transactionId"] == "2.1"
      assert r3["transactionId"] == "3.1"

      assert r1["prev_hash"] == @zero
      assert r2["prev_hash"] == r1["merkle_root"]
      assert r3["prev_hash"] == r2["merkle_root"]
    end

    test "chain recomputation: merkle_root == sha256(prev <> data_hash)" do
      {:ok, r1} = ConfidentialLedger.append_transaction("ledger-a", %{"k" => "v"})
      {:ok, r2} = ConfidentialLedger.append_transaction("ledger-a", %{"k" => "v2"})

      for receipt <- [r1, r2] do
        expected =
          Base.encode16(
            :crypto.hash(:sha256, receipt["prev_hash"] <> receipt["data_hash"]),
            case: :lower
          )

        assert receipt["merkle_root"] == expected
      end

      data_hash_1 =
        Base.encode16(:crypto.hash(:sha256, Jason.encode!(%{"k" => "v"})), case: :lower)

      assert r1["data_hash"] == data_hash_1
    end

    test "receipts are signed and signature verifies" do
      {:ok, receipt} = ConfidentialLedger.append_transaction("ledger-a", %{"k" => "v"})
      sig = receipt["signature"]

      unsigned = Map.delete(receipt, "signature")

      assert {:ok, claims} = ReceiptSigner.verify(sig)

      # Signature must cover exactly the unsigned receipt payload.
      assert claims == unsigned
    end

    test "duplicate contents are refused with 409 LedgerItemAlreadyExists" do
      assert {:ok, _} = ConfidentialLedger.append_transaction("ledger-a", %{"dup" => true})

      assert {:error, 409, "LedgerItemAlreadyExists"} =
               ConfidentialLedger.append_transaction("ledger-a", %{"dup" => true})
    end

    test "duplicate detection is per-ledger" do
      assert {:ok, _} = ConfidentialLedger.append_transaction("ledger-a", %{"same" => 1})
      assert {:ok, _} = ConfidentialLedger.append_transaction("ledger-b", %{"same" => 1})
    end

    test "parallel appends keep seq strictly monotonic with no duplicate tx ids" do
      parent = self()

      tasks =
        for i <- 1..24 do
          Task.async(fn ->
            {:ok, receipt} =
              ConfidentialLedger.append_transaction("ledger-par", %{"writer" => i})

            send(parent, {:done, i})
            receipt["transactionId"]
          end)
        end

      tx_ids = Task.await_many(tasks, 30_000)
      assert length(tx_ids) == 24
      assert length(Enum.uniq(tx_ids)) == 24

      seqs =
        Enum.map(tx_ids, fn tx_id ->
          {seq, _} = Integer.parse(tx_id)
          seq
        end)

      assert Enum.sort(seqs) == Enum.to_list(1..24)
    end

    test "32-writer race cannot fork the chain: full recompute shows one genesis chain" do
      parent = self()

      tasks =
        for i <- 1..32 do
          Task.async(fn ->
            {:ok, receipt} = ConfidentialLedger.append_transaction("ledger-race", %{"writer" => i})
            send(parent, {:done, i})
            receipt
          end)
        end

      receipts = Task.await_many(tasks, 30_000)
      assert length(receipts) == 32

      receipts = Enum.sort_by(receipts, fn %{"transactionId" => tx} ->
        {seq, _} = Integer.parse(tx)
        seq
      end)

      # Contiguous unique seqs 1..32.
      seqs = Enum.map(receipts, fn %{"transactionId" => tx} ->
        {seq, _} = Integer.parse(tx)
        seq
      end)

      assert seqs == Enum.to_list(1..32)

      # Single genesis: the first block chains off the zero hash.
      assert hd(receipts)["prev_hash"] == @zero

      # Full chain recompute: each block's prev_hash is the prior merkle_root
      # (this is exactly the property the 5/5 fork repro violated: concurrent
      # appends chained off the same prev).
      Enum.reduce(receipts, @zero, fn receipt, expected_prev ->
        assert receipt["prev_hash"] == expected_prev

        expected_root =
          Base.encode16(
            :crypto.hash(:sha256, receipt["prev_hash"] <> receipt["data_hash"]),
            case: :lower
          )

        assert receipt["merkle_root"] == expected_root
        expected_root
      end)

      # Stored chain agrees with the returned chain.
      stored = ConfidentialLedger.list_transactions("ledger-race")
      assert Enum.map(stored, & &1["transactionId"]) == Enum.map(receipts, & &1["transactionId"])
    end

    test "64-writer race: single genesis chain, no fork, stored chain == returned chain" do
      parent = self()

      tasks =
        for i <- 1..64 do
          Task.async(fn ->
            {:ok, receipt} = ConfidentialLedger.append_transaction("ledger-race64", %{"w" => i})
            send(parent, {:done, i})
            receipt
          end)
        end

      receipts =
        tasks
        |> Task.await_many(60_000)
        |> Enum.sort_by(fn %{"transactionId" => tx} ->
          {seq, _} = Integer.parse(tx)
          seq
        end)

      assert length(receipts) == 64

      Enum.reduce(receipts, @zero, fn receipt, expected_prev ->
        assert receipt["prev_hash"] == expected_prev

        expected_root =
          Base.encode16(
            :crypto.hash(:sha256, receipt["prev_hash"] <> receipt["data_hash"]),
            case: :lower
          )

        assert receipt["merkle_root"] == expected_root
        expected_root
      end)

      stored = ConfidentialLedger.list_transactions("ledger-race64")

      assert Enum.map(stored, & &1["transactionId"]) ==
               Enum.map(receipts, & &1["transactionId"])
    end

    test "get_transaction supports tx_id and latest; list_transactions is ordered" do
      receipts =
        for i <- 1..5 do
          {:ok, r} = ConfidentialLedger.append_transaction("ledger-a", %{"i" => i})
          r
        end

      fetched = Enum.map(1..5, fn i -> ConfidentialLedger.get_transaction("ledger-a", "#{i}.1") end)
      assert fetched == Enum.map(receipts, &{:ok, &1})

      assert {:ok, latest} = ConfidentialLedger.get_transaction("ledger-a", "latest")
      assert latest == List.last(receipts)

      assert {:ok, latest} = ConfidentialLedger.get_latest("ledger-a")
      assert latest == List.last(receipts)

      assert ConfidentialLedger.list_transactions("ledger-a") == receipts
      assert ConfidentialLedger.list_transactions("missing") == []
      assert :error = ConfidentialLedger.get_latest("missing")
      assert :error = ConfidentialLedger.get_transaction("ledger-a", "999.1")
    end
  end
end
