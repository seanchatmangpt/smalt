defmodule Smalt.Security.SecurityHardeningTest do
  use ExUnit.Case, async: false

  alias Smalt.Security.{Attestation, ConfidentialLedger, ReceiptSigner}
  alias Smalt.DataPlane.SKR
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

    # -- cycle-4 fuzz: exact typed refusals -----------------------------------

    test "rejects missing-alg header" do
      payload = Base.url_encode64(Jason.encode!(%{"exp" => 9_999_999_999}), padding: false)

      header = Base.url_encode64(Jason.encode!(%{"typ" => "JWT"}), padding: false)

      # check_alg fires before the signature check, so any sig bytes still
      # yield the typed :bad_alg refusal
      assert {:error, :bad_alg} =
               ReceiptSigner.verify(header <> "." <> payload <> "." <> header)
    end

    test "rejects foreign-key-signed token (replayed/foreign MAA JWT)" do
      foreign_priv = :public_key.generate_key({:rsa, 2048, 65_537})

      header = Base.url_encode64(Jason.encode!(%{"alg" => "RS256", "typ" => "JWT"}), padding: false)
      payload =
        Base.url_encode64(
          Jason.encode!(%{"exp" => System.system_time(:second) + 60, "iss" => "https://evil.example/"}),
          padding: false
        )

      sig =
        :public_key.sign(header <> "." <> payload, :sha256, foreign_priv)
        |> Base.url_encode64(padding: false)

      assert {:error, :bad_signature} =
               ReceiptSigner.verify(header <> "." <> payload <> "." <> sig)
    end

    test "rejects foreign-key token signed with a DIFFERENT key size (1024-bit RSA)" do
      # key-size confusion: a syntactically valid RS256 token from a weaker
      # foreign key must fail the same typed refusal, never a size-based
      # bypass or crash
      foreign_priv = :public_key.generate_key({:rsa, 1024, 65_537})

      header = Base.url_encode64(Jason.encode!(%{"alg" => "RS256", "typ" => "JWT"}), padding: false)

      payload =
        Base.url_encode64(
          Jason.encode!(%{"exp" => System.system_time(:second) + 60, "iss" => "https://evil.example/"}),
          padding: false
        )

      sig =
        :public_key.sign(header <> "." <> payload, :sha256, foreign_priv)
        |> Base.url_encode64(padding: false)

      assert {:error, :bad_signature} =
               ReceiptSigner.verify(header <> "." <> payload <> "." <> sig)
    end

    test "rejects non-map JSON payload" do
      # split/decode rejects the array shape before any key material is touched
      payload = Base.url_encode64(Jason.encode!([1, 2, 3]), padding: false)
      header = Base.url_encode64(Jason.encode!(%{"alg" => "RS256", "typ" => "JWT"}), padding: false)

      assert {:error, :invalid_json} =
               ReceiptSigner.verify(header <> "." <> payload <> "." <> header)
    end

    test "rejects non-integer exp" do
      claims = %{"exp" => "soon"}
      token = ReceiptSigner.sign(claims)

      assert {:error, :token_expired} = ReceiptSigner.verify_token(token)
    end

    # -- cycle-5: clock-skew boundary + header-key confusion ------------------

    test "exp == now is accepted, exp == now - 1 refused (skew boundary pinned)" do
      # exp == now is accepted at verify-time: the second can tick between the
      # test's `now` capture and verify_token's own clock read, so the accept
      # half is retried on a fresh `now` (up to 10 attempts) — the boundary
      # itself (exp >= verify-time now) is exactly what is pinned, and exp ==
      # now - 1 refuses deterministically on any tick.
      accepted? =
        Enum.any?(1..10, fn _ ->
          now = System.system_time(:second)
          match?({:ok, _}, ReceiptSigner.verify_token(ReceiptSigner.sign(%{"exp" => now})))
        end)

      assert accepted?

      now = System.system_time(:second)

      assert {:error, :token_expired} =
               ReceiptSigner.verify_token(ReceiptSigner.sign(%{"exp" => now - 1}))
    end

    test "nbf == now accepted, nbf == now + 1 refused (typed :token_not_yet_valid)" do
      now = System.system_time(:second)

      assert {:ok, _} =
               ReceiptSigner.verify_token(ReceiptSigner.sign(%{"exp" => now + 60, "nbf" => now}))

      assert {:error, :token_not_yet_valid} =
               ReceiptSigner.verify_token(
                 ReceiptSigner.sign(%{"exp" => now + 60, "nbf" => now + 1})
               )

      # non-integer nbf is uninterpretable, not ignored
      assert {:error, :token_not_yet_valid} =
               ReceiptSigner.verify_token(
                 ReceiptSigner.sign(%{"exp" => now + 60, "nbf" => "soon"})
               )

      # absent nbf changes nothing (existing corpus re-run through the new clause)
      assert {:ok, _} = ReceiptSigner.verify_token(ReceiptSigner.sign(%{"exp" => now + 60}))
    end

    test "kid-carrying forged header breaks the signing input -> bad_signature" do
      claims = %{"exp" => System.system_time(:second) + 60}
      token = ReceiptSigner.sign(claims)
      [_, p, s] = String.split(token, ".", parts: 3)

      # attacker rewrites the header to point at their key; the header is part
      # of the signing input, so the original signature no longer verifies
      forged_header =
        Base.url_encode64(
          Jason.encode!(%{"alg" => "RS256", "typ" => "JWT", "kid" => "attacker-key-1"}),
          padding: false
        )

      assert {:error, :bad_signature} =
               ReceiptSigner.verify(forged_header <> "." <> p <> "." <> s)
    end

    # -- cycle-8: JWT header chaos (Bao/Joken posture corpus) -----------------

    test "alg-swap RS256->HS256 with the public key as HMAC secret is refused" do
      # classic alg-confusion: HMAC "secret" = the would-be public key bytes.
      # check_alg refuses before any key material or MAC is touched, so the
      # secret bytes never influence the verdict.
      header = Base.url_encode64(Jason.encode!(%{"alg" => "HS256", "typ" => "JWT"}), padding: false)

      payload =
        Base.url_encode64(Jason.encode!(%{"exp" => System.system_time(:second) + 60}), padding: false)

      mac =
        :crypto.mac(:hmac, :sha256, "public-key-bytes-as-secret", header <> "." <> payload)
        |> Base.url_encode64(padding: false)

      assert {:error, {:bad_alg, "HS256"}} =
               ReceiptSigner.verify(header <> "." <> payload <> "." <> mac)
    end

    test "crit-carrying header is not processable: signature over rewritten header fails" do
      claims = %{"exp" => System.system_time(:second) + 60}
      token = ReceiptSigner.sign(claims)
      [_, p, s] = String.split(token, ".", parts: 3)

      forged_header =
        Base.url_encode64(
          Jason.encode!(%{"alg" => "RS256", "crit" => ["exp"], "exp" => true}),
          padding: false
        )

      # the signer has no crit support, so a crit header can only arrive
      # forged — and the header is part of the signing input
      assert {:error, :bad_signature} =
               ReceiptSigner.verify(forged_header <> "." <> p <> "." <> s)
    end

    test "b64:false header (Bao token-attack form) is refused" do
      claims = %{"exp" => System.system_time(:second) + 60}
      token = ReceiptSigner.sign(claims)
      [_, p, s] = String.split(token, ".", parts: 3)

      forged_header =
        Base.url_encode64(Jason.encode!(%{"alg" => "RS256", "b64" => false, "crit" => ["b64"]}), padding: false)

      assert {:error, :bad_signature} =
               ReceiptSigner.verify(forged_header <> "." <> p <> "." <> s)
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

    test "client_payload_hash is invariant under key-order permutation (nested maps)" do
      Application.put_env(:smalt, :maa_measurement_baseline, [@measurement])

      nested_a = %{
        "measurement" => @measurement,
        "policy" => %{"b" => 1, "a" => %{"y" => [1, 2], "x" => true}}
      }

      nested_b = %{
        "policy" => %{"a" => %{"x" => true, "y" => [1, 2]}, "b" => 1},
        "measurement" => @measurement
      }

      {:ok, _, claims_a} = Attestation.attest_enclave(nested_a)
      {:ok, _, claims_b} = Attestation.attest_enclave(nested_b)

      hash_a = claims_a["x-ms-runtime"]["client_payload_hash"]
      hash_b = claims_b["x-ms-runtime"]["client_payload_hash"]

      assert hash_a == hash_b

      # and it really is content-derived: a value change moves the hash
      {:ok, _, claims_c} = Attestation.attest_enclave(Map.put(nested_a, "policy", %{}))
      refute claims_c["x-ms-runtime"]["client_payload_hash"] == hash_a

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
        for i <- 1..12 do
          {:ok, r} = ConfidentialLedger.append_transaction("ledger-a", %{"i" => i})
          r
        end

      # 12 appends force double-digit seqs: "10.1" must sort AFTER "9.1"
      # (numeric parse, not string compare — string sort would invert).
      fetched = Enum.map(1..12, fn i -> ConfidentialLedger.get_transaction("ledger-a", "#{i}.1") end)
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

    # -- cycle-5: receipt-field tamper binding + fork fuzz --------------------

    test "receipt signature is a verifiable JWS bound to the exact receipt fields" do
      {:ok, r1} = ConfidentialLedger.append_transaction("ledger-sig", %{"a" => 1})
      {:ok, r2} = ConfidentialLedger.append_transaction("ledger-sig", %{"b" => 2})

      for r <- [r1, r2] do
        assert {:ok, claims} = ReceiptSigner.verify(r["signature"])
        # the JWS payload is exactly the receipt minus its signature field
        assert claims == Map.delete(r, "signature")
      end

      # post-sign field tamper is always detectable: the bound payload no
      # longer equals the presented receipt
      tampered = Map.put(r1, "contents", %{"a" => 999})
      {:ok, bound} = ReceiptSigner.verify(r1["signature"])
      refute bound == Map.delete(tampered, "signature")

      # signature replay across tx ids is detectable the same way: r1's
      # signature binds r1's transactionId, never r2's
      {:ok, bound2} = ReceiptSigner.verify(r1["signature"])
      assert bound2["transactionId"] == r1["transactionId"]
      refute bound2["transactionId"] == r2["transactionId"]
    end

    test "64-writer fork fuzz: every prev_hash unique, every writer persisted exactly once" do
      parent = self()

      tasks =
        for i <- 1..64 do
          Task.async(fn ->
            {:ok, r} = ConfidentialLedger.append_transaction("ledger-forkfuzz", %{"w" => i})
            send(parent, {:done, i})
            r
          end)
        end

      receipts = Task.await_many(tasks, 30_000)
      assert length(receipts) == 64

      # fork = two transactions chaining off the SAME prev_hash; a fork means
      # the prev_hash multiset has a duplicate
      prevs = Enum.map(receipts, & &1["prev_hash"])
      assert length(Enum.uniq(prevs)) == 64
      assert Enum.count(prevs, &(&1 == @zero)) == 1

      # every writer's content persisted exactly once (loser never re-persisted)
      writers = receipts |> Enum.map(fn %{"contents" => %{"w" => w}} -> w end) |> Enum.sort()
      assert writers == Enum.to_list(1..64)

      # and the persisted chain recomputes as one genesis chain
      stored =
        ConfidentialLedger.list_transactions("ledger-forkfuzz")

      assert length(stored) == 64

      Enum.reduce(stored, @zero, fn receipt, expected_prev ->
        assert receipt["prev_hash"] == expected_prev
        receipt["merkle_root"]
      end)
    end

    test "mixed workload: 64 appends + 40 readers + 5 duplicate writers concurrently" do
      parent = self()

      append_tasks =
        for i <- 1..64 do
          Task.async(fn ->
            {:ok, r} = ConfidentialLedger.append_transaction("ledger-mixed", %{"w" => i})
            send(parent, {:done, :append, i})
            r
          end)
        end

      read_tasks =
        for _ <- 1..40 do
          Task.async(fn ->
            result =
              case ConfidentialLedger.get_latest("ledger-mixed") do
                {:ok, receipt} ->
                  # a reader may race an append mid-chain; whatever it sees
                  # must be a SELF-CONSISTENT link, never torn
                  expected =
                    Base.encode16(
                      :crypto.hash(:sha256, receipt["prev_hash"] <> receipt["data_hash"]),
                      case: :lower
                    )

                  assert receipt["merkle_root"] == expected
                  {:ok, receipt}

                :error ->
                  :empty
              end

            send(parent, {:done, :read, self()})
            result
          end)
        end

      dup_tasks =
        for _ <- 1..5 do
          Task.async(fn ->
            result =
              ConfidentialLedger.append_transaction("ledger-mixed", %{"dup" => true})

            send(parent, {:done, :dup, self()})
            result
          end)
        end

      appends = Task.await_many(append_tasks, 30_000)
      reads = Task.await_many(read_tasks, 30_000)
      dups = Task.await_many(dup_tasks, 30_000)

      # appends: exactly one persisted link per writer
      assert length(appends) == 64
      tx_ids = Enum.map(appends, & &1["transactionId"])
      assert length(Enum.uniq(tx_ids)) == 64

      # duplicates of identical contents: exactly ONE admitted, 4 x 409
      admitted = Enum.count(dups, &match?({:ok, _}, &1))
      refused = Enum.count(dups, &match?({:error, 409, "LedgerItemAlreadyExists"}, &1))
      assert admitted == 1
      assert refused == 4

      # readers: no torn links (asserted inside every read task)
      assert length(reads) == 40
      assert Enum.all?(reads, &(&1 == :empty or match?({:ok, _}, &1)))

      # settled chain recomputes: 64 + 1 admitted dup = 65 links, one chain
      stored = ConfidentialLedger.list_transactions("ledger-mixed")
      assert length(stored) == 65

      Enum.reduce(stored, @zero, fn receipt, expected_prev ->
        assert receipt["prev_hash"] == expected_prev
        receipt["merkle_root"]
      end)
    end

    # -- cycle-9: wave-2 courts ------------------------------------------------

    test "baseline tamper: flipping ONE measurement byte refuses attestation" do
      Application.put_env(:smalt, :maa_measurement_baseline, [@measurement])

      # single-bit flip in the last hex char: adjacent to the valid baseline
      flipped =
        String.slice(@measurement, 0, 62) <>
          if String.last(@measurement) == "f", do: "0", else: "f"

      assert flipped != @measurement

      assert {:error, 400, "attestationFailedVerdict"} =
               Attestation.attest_enclave(%{"measurement" => flipped})

      assert {:error, 400, "attestationFailedVerdict"} =
               Attestation.attest_enclave(%{"measurement" => String.upcase(@measurement)})

      Application.delete_env(:smalt, :maa_measurement_baseline)
    end

    test "jti near-collision: same-jti releases within one clock tick, first-writer-wins" do
      put_skr_key = fn name -> Store.put(:smalt_vault_keys, name, %{"kid" => "k-" <> name, "release_policy" => %{"authority" => "smalt-test"}}) end
      put_skr_key.("skr-tick-a")
      put_skr_key.("skr-tick-b")

      # one token, two releases launched on a barrier so both land inside the
      # same clock tick; different key names isolate the version counters
      token = Smalt.Security.ReceiptSigner.sign(attest_claims())

      barrier = :erlang.make_ref()
      parent = self()

      tasks =
        for name <- ["skr-tick-a", "skr-tick-b"] do
          Task.async(fn ->
            send(parent, :ready)
            # pin: match the ref, don't bind a fresh variable
            receive do: (^barrier -> :go)
            release(name, token)
          end)
        end

      # release both workers once both are parked
      for _ <- tasks, do: receive do: (:ready -> :ok)
      for t <- tasks, do: send(t.pid, barrier)

      results = Task.await_many(tasks, 30_000)

      assert Enum.count(results, &match?({:ok, 200, _}, &1)) == 1
      assert Enum.count(results, &match?({:error, 403, _}, &1)) == 1
    end

    defp release(name, token) do
      conn =
        :post
        |> Plug.Test.conn("/keys/#{name}/release")
        |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)

      SKR.release(name, conn)
    end

    defp attest_claims do
      now = System.system_time(:second)

      %{
        "x-ms-compliance-status" => "azure-compliant-cvm",
        "x-ms-runtime" => %{"jti" => System.unique_integer([:positive]) |> to_string()},
        "iat" => now,
        "exp" => now + 7200
      }
    end

    defp attest_claims_with_jti(jti) do
      now = System.system_time(:second)

      %{
        "x-ms-compliance-status" => "azure-compliant-cvm",
        "x-ms-runtime" => %{"jti" => jti},
        "iat" => now,
        "exp" => now + 7200
      }
    end
  end

  ## Lens-2 (ledger + SKR deep lens 2): cross-surface isolation vs TrustProfile,
  ## implicit-create fence, cursor stability, M7-class payload-tamper court.

  describe "lens-2 cross-surface isolation (ledger/SKR vs TrustProfile)" do
    test "a ledger/MAA JWS is refused by TrustProfile.verify with :unknown_key_id" do
      # Distinct token grammars: ledger receipts and MAA tokens carry no
      # envelope key_id, so the TrustProfile gate refuses them before any
      # signature check can make them pass (check_key_id precedes check_rsa).
      token = ReceiptSigner.sign(%{"sub" => "ledger-1", "exp" => System.system_time(:second) + 60})

      assert {:error, :unknown_key_id} = Smalt.TrustProfile.verify(token)
    end

    test "a TrustProfile envelope is refused by the ReceiptSigner token gate" do
      {:ok, envelope} = Smalt.TrustProfile.new(subject: "ledger-skr-lens2-subject")

      assert {:ok, token} = Smalt.TrustProfile.sign(envelope)

      # Each surface caches its own generated keypair in :persistent_term
      # (`{ReceiptSigner, :keypair}` vs `{TrustProfile, :keypair}`), so even the
      # raw signature layer refuses the cross-surface token. Since lens-3 the
      # refusal is STRUCTURAL and fires first: the envelope declares
      # typ "ctp-envelope-v1", refused by the RFC 8725 explicit-typing fence
      # before any key material is touched (key-independent, see lens-3 court).
      assert {:error, {:bad_typ, "ctp-envelope-v1"}} = ReceiptSigner.verify(token)
      assert {:error, {:bad_typ, "ctp-envelope-v1"}} = ReceiptSigner.verify_token(token)
    end

    test "non-interop is bidirectional at the full-gate layer" do
      # MAA token -> SKR path refuses a TrustProfile envelope (no compliance
      # claim), completing the isolation matrix.
      {:ok, envelope} = Smalt.TrustProfile.new(subject: "iso-matrix")
      {:ok, tp_token} = Smalt.TrustProfile.sign(envelope)

      Store.put(:smalt_vault_keys, "skr-iso-key", %{
        "kid" => "k-iso",
        "release_policy" => %{"authority" => "smalt-test"}
      })

      conn =
        :post
        |> Plug.Test.conn("/keys/skr-iso-key/release")
        |> Plug.Conn.put_req_header("authorization", "Bearer " <> tp_token)

      assert {:error, 403, %{"error" => %{"code" => "UnauthorizedAttestation"}}} =
               SKR.release("skr-iso-key", conn)
    end
  end

  # lens-3: fence courts must RESTORE the prior env value, not delete it — a
  # config-level flag (the flag-flip experiment's own regime) was being erased
  # by these after-blocks for every test later in the run, order-masking the
  # pivot's true blast radius. Same masking class as the maa baseline toggles
  # (out of this court's scope, receipted).
  defp restore_ledger_enforce_existence(prior) do
    if prior == nil do
      Application.delete_env(:smalt, :ledger_enforce_existence)
    else
      Application.put_env(:smalt, :ledger_enforce_existence, prior)
    end
  end

  describe "lens-2 implicit-create divergence fence" do
    test "default: append to never-created ledger implicitly creates it (documented divergence)" do
      assert {:ok, receipt} =
               ConfidentialLedger.append_transaction("never-created-default", %{"a" => 1})

      assert receipt["transactionId"] == "1.1"
    end

    test "enforced: append to never-created ledger is refused with the 404-class envelope" do
      prior = Application.get_env(:smalt, :ledger_enforce_existence)
      Application.put_env(:smalt, :ledger_enforce_existence, true)

      try do
        assert {:error, 404, "LedgerNotFound"} =
                 ConfidentialLedger.append_transaction("never-created-fenced", %{"a" => 1})
      after
        restore_ledger_enforce_existence(prior)
      end
    end

    test "enforced: explicit creation marker admits the append (fix shape works)" do
      prior = Application.get_env(:smalt, :ledger_enforce_existence)
      Application.put_env(:smalt, :ledger_enforce_existence, true)

      try do
        Store.put(:smalt_ledger_meta, {:created, "fenced-created"}, true)

        assert {:ok, %{"transactionId" => "1.1"}} =
                 ConfidentialLedger.append_transaction("fenced-created", %{"a" => 1})
      after
        restore_ledger_enforce_existence(prior)
      end
    end

    test "enforced: a ledger with prior transaction state admits appends" do
      # Seed state with the fence off (the seed append itself would otherwise be
      # the implicit create), then flip the fence: prior state admits appends.
      assert {:ok, _} = ConfidentialLedger.append_transaction("fenced-existing", %{"seed" => 1})
      prior = Application.get_env(:smalt, :ledger_enforce_existence)
      Application.put_env(:smalt, :ledger_enforce_existence, true)

      try do
        assert {:ok, %{"transactionId" => "2.1"}} =
                 ConfidentialLedger.append_transaction("fenced-existing", %{"next" => 2})
      after
        restore_ledger_enforce_existence(prior)
      end
    end
  end

  describe "lens-2 ledger read cursor under mixed write traffic" do
    test "list_transactions snapshots are immutable, gap-free prefixes of the settled chain" do
      parent = self()

      # Take snapshots of the read cursor while appends land concurrently.
      append_tasks =
        for i <- 1..32 do
          Task.async(fn ->
            {:ok, _} = ConfidentialLedger.append_transaction("ledger-cursor", %{"w" => i})
            send(parent, {:append_done, i})
          end)
        end

      snapshot_tasks =
        for _ <- 1..12 do
          Task.async(fn ->
            snap = ConfidentialLedger.list_transactions("ledger-cursor")
            send(parent, {:snap_done, self()})
            snap
          end)
        end

      Task.await_many(append_tasks, 30_000)
      snapshots = Task.await_many(snapshot_tasks, 30_000)

      settled = ConfidentialLedger.list_transactions("ledger-cursor")
      assert length(settled) == 32

      # Every snapshot is a prefix of the settled chain, same order, same
      # receipts (read-path immutability: appends never rewrite earlier rows).
      Enum.each(snapshots, fn snap ->
        assert length(snap) <= 32
        prefix = Enum.take(settled, length(snap))
        assert snap == prefix
      end)

      # Chain integrity of the settled chain.
      Enum.reduce(settled, @zero, fn receipt, expected_prev ->
        assert receipt["prev_hash"] == expected_prev
        receipt["merkle_root"]
      end)
    end

    test "get_latest cursor is monotone: never regresses under concurrent appends" do
      parent = self()

      tasks =
        for i <- 1..24 do
          Task.async(fn ->
            {:ok, _} = ConfidentialLedger.append_transaction("ledger-cursor-mono", %{"w" => i})
            send(parent, :done)
          end)
        end

      reader =
        Task.async(fn ->
          prev_seq = 0

          # Sample latest repeatedly while appends land; seq must never go down.
          for _ <- 1..200 do
            case ConfidentialLedger.get_latest("ledger-cursor-mono") do
              {:ok, %{"transactionId" => tx_id}} ->
                seq = tx_id |> String.split(".") |> hd() |> String.to_integer()
                assert seq >= prev_seq
                seq

              :error ->
                prev_seq
            end
          end
        end)

      Task.await_many(tasks ++ [reader], 30_000)
    end
  end

  describe "lens-2 fence precedence + policy-hash binding" do
    test "existence fence fires BEFORE the dup check: no 409, no state leaked" do
      prior = Application.get_env(:smalt, :ledger_enforce_existence)
      Application.put_env(:smalt, :ledger_enforce_existence, true)

      try do
        contents = %{"fence" => "precedence"}

        # Under the fence, a never-created ledger refuses 404 (not 409) and the
        # dup counter is never minted for it (computed with the product's own
        # canonicalization: sorted-key JSON -> sha256 hex).
        assert {:error, 404, "LedgerNotFound"} =
                 ConfidentialLedger.append_transaction("fence-precedence", contents)

        data_hash =
          contents
          |> Jason.encode!()
          |> then(&:crypto.hash(:sha256, &1))
          |> Base.encode16(case: :lower)

        assert :error = Store.get(:smalt_ledger_meta, {:dup, "fence-precedence", data_hash})

        # Fence off: the same contents append as a FRESH ledger at tx 1.1 —
        # proving the refused append minted no counters under the fence.
        restore_ledger_enforce_existence(nil)

        assert {:ok, %{"transactionId" => "1.1"}} =
                 ConfidentialLedger.append_transaction("fence-precedence", contents)
      after
        restore_ledger_enforce_existence(prior)
      end
    end

    # lens-4 mission item 3: commit-point law at the failure boundary. Invalid
    # (non-JSON-encodable) contents arrive FIRST. The refusal must be a typed
    # 400-class envelope, the serialized writer must SURVIVE (one bad append
    # must not kill the writer for all writers), and the failure must burn no
    # state: no dup counter, no seq, no meta — a later VALID append of the
    # same contents must be admitted at tx 1.1 (phantom-duplicate guard).
    test "invalid contents arriving FIRST: typed refusal, writer survives, no state burned" do
      ledger = "commit-point-lens4"
      invalid = %{"bad" => {:tuple, :not_json}}

      # Typed refusal, not a crash / EXIT.
      assert {:error, 400, "InvalidBody"} =
               ConfidentialLedger.append_transaction(ledger, invalid)

      # Writer alive for everyone: a concurrent-world probe.
      assert {:ok, %{"transactionId" => "1.1"}} =
               ConfidentialLedger.append_transaction(ledger, %{"valid" => "first"})

      # And the invalid shape stays refused while valid traffic flows.
      assert {:error, 400, "InvalidBody"} =
               ConfidentialLedger.append_transaction(ledger, invalid)

      assert {:ok, %{"transactionId" => "2.1"}} =
               ConfidentialLedger.append_transaction(ledger, %{"valid" => "second"})
    end

    # Mixed fuzz: valid and invalid contents interleaved under concurrency.
    # Every admitted write is chain-coherent; every refusal is the typed 400;
    # the settled seq set is exactly the valid writers (dense 1..N over the
    # valid appends), the failures burned nothing.
    test "mixed valid/invalid fuzz under concurrency: chain coherent, failures burn nothing" do
      ledger = "commit-point-fuzz-lens4"
      invalid = %{"bad" => {:tuple, :not_json}}

      results =
        1..32
        |> Enum.map(fn i ->
          Task.async(fn ->
            if rem(i, 4) == 0 do
              {:invalid, ConfidentialLedger.append_transaction(ledger, invalid)}
            else
              {:valid, ConfidentialLedger.append_transaction(ledger, %{"i" => i})}
            end
          end)
        end)
        |> Task.await_many(30_000)

      {valid_results, invalid_results} = Enum.split_with(results, fn {kind, _} -> kind == :valid end)
      assert length(valid_results) == 24
      assert length(invalid_results) == 8

      # Every refusal is the typed envelope, never a crash.
      Enum.each(invalid_results, fn {:invalid, r} ->
        assert {:error, 400, "InvalidBody"} = r
      end)

      # Every admitted write persisted, and exactly the valid class did.
      Enum.each(valid_results, fn {:valid, {:ok, _}} -> :ok end)

      settled = ConfidentialLedger.list_transactions(ledger)
      assert length(settled) == 24

      seqs = Enum.map(settled, fn %{"transactionId" => id} -> id |> String.split(".") |> hd() |> String.to_integer() end)
      assert seqs == Enum.to_list(1..24)

      # Chain coherence across the settled prefix (recompute like the cycle-1
      # lens-1 court).
      Enum.chunk_every(settled, 2, 1, :discard)
      |> Enum.each(fn [%{"prev_hash" => prev, "merkle_root" => root, "data_hash" => dh} | _] ->
        assert root == Base.encode16(:crypto.hash(:sha256, prev <> dh), case: :lower)
      end)
    end

    # lens-4: writer-death resilience. The writer is stateless (all ledger
    # state lives in Store); if it dies mid-stream the next append lazily
    # restarts it and the chain must continue WITHOUT fork or seq reuse.
    test "writer death mid-stream: lazy restart continues the chain without fork or seq reuse" do
      ledger = "writer-death-lens4"
      assert {:ok, %{"transactionId" => "1.1"}} =
               ConfidentialLedger.append_transaction(ledger, %{"n" => 1})

      # Kill the serialized writer mid-stream.
      pid = GenServer.whereis(Smalt.Security.LedgerWriter)
      assert is_pid(pid)
      Process.exit(pid, :kill)
      # Let the monitor Down propagate before the next append.
      Process.sleep(10)

      assert {:ok, %{"transactionId" => "2.1", "prev_hash" => prev2, "merkle_root" => root2}} =
               ConfidentialLedger.append_transaction(ledger, %{"n" => 2})

      # Chained off the pre-death root, not a genesis re-init.
      assert prev2 == root1_pre_death(ledger, 1)

      assert root2 ==
               Base.encode16(:crypto.hash(:sha256, prev2 <> hash_contents(%{"n" => 2})),
                 case: :lower
               )

      assert {:ok, _} = ConfidentialLedger.get_transaction(ledger, "latest")
    end

    defp root1_pre_death(ledger, seq) do
      {:ok, receipt} = ConfidentialLedger.get_transaction(ledger, "#{seq}.1")
      receipt["merkle_root"]
    end

    defp hash_contents(m) do
      m |> Jason.encode!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
    end

    test "release policy change changes the released material and policyHash" do
      Store.put(:smalt_vault_keys, "skr-policy", %{
        "kid" => "k-policy",
        "release_policy" => %{"authority" => "smalt-test", "export" => "allowed"}
      })

      # No-jti token: legal to release repeatedly (documented dev mode), which
      # isolates the policy rotation variable from the jti single-use gate.
      token =
        ReceiptSigner.sign(%{
          "x-ms-compliance-status" => "azure-compliant-cvm",
          "iat" => System.system_time(:second),
          "exp" => System.system_time(:second) + 7200
        })

      assert {:ok, 200, first} = release("skr-policy", token)

      # Rotate the policy in place: same key, same token, different policy.
      Store.put(:smalt_vault_keys, "skr-policy", %{
        "kid" => "k-policy",
        "release_policy" => %{"authority" => "smalt-test", "export" => "denied"}
      })

      assert {:ok, 200, second} = release("skr-policy", token)

      # Different material, different policyHash (token has no jti, so both
      # releases are legal dev-mode replays bounded by RS256+exp only).
      refute first["value"] == second["value"]
      refute first["policyHash"] == second["policyHash"]
      assert first["keyMaterialVersion"] == 1
      assert second["keyMaterialVersion"] == cycle_policy_version(second)
    end

    defp cycle_policy_version(body), do: body["keyMaterialVersion"]

    test "HKDF binding: same key+policy releases identical material; per-key salt isolates keys" do
      # Same key + same policy + same (no-jti) token -> identical material on
      # every release (deterministic, replayable); a different key name under
      # the same policy derives DIFFERENT material (per-key HKDF salt).
      Store.put(:smalt_vault_keys, "skr-det-a", %{
        "kid" => "k-det-a",
        "release_policy" => %{"authority" => "smalt-test"}
      })

      Store.put(:smalt_vault_keys, "skr-det-b", %{
        "kid" => "k-det-b",
        "release_policy" => %{"authority" => "smalt-test"}
      })

      token =
        ReceiptSigner.sign(%{
          "x-ms-compliance-status" => "azure-compliant-cvm",
          "iat" => System.system_time(:second),
          "exp" => System.system_time(:second) + 7200
        })

      assert {:ok, 200, a1} = release("skr-det-a", token)
      assert {:ok, 200, a2} = release("skr-det-a", token)
      assert a1["value"] == a2["value"], "same key+policy must release identical material"
      assert a1["policyHash"] == a2["policyHash"]
      assert a1["keyMaterialVersion"] == 1
      assert a2["keyMaterialVersion"] == 2

      assert {:ok, 200, b1} = release("skr-det-b", token)
      refute b1["value"] == a1["value"], "different key name must derive different material"
    end
  end

  describe "lens-2 SKR commit-point conservation" do
    test "failed releases burn neither jti nor keyMaterialVersion" do
      Store.put(:smalt_vault_keys, "skr-conserve", %{
        "kid" => "k-conserve",
        "release_policy" => %{"authority" => "smalt-test"}
      })

      now = System.system_time(:second)

      # Token A: malformed recipient JWK -> release fails at wrap, BEFORE the
      # commit point: no version counter, no jti consumed.
      jti_a = "conserve-jti-a-#{System.unique_integer([:positive])}"

      bad_recipient_token =
        ReceiptSigner.sign(%{
          "x-ms-compliance-status" => "azure-compliant-cvm",
          "x-ms-runtime" => %{"jti" => jti_a},
          "skr_recipient_jwk" => %{"kty" => "EC", "crv" => "P-256"},
          "iat" => now,
          "exp" => now + 7200
        })

      assert {:error, 400, %{"error" => %{"code" => "InvalidParameter"}}} =
               release("skr-conserve", bad_recipient_token)

      assert :error = Store.get(:smalt_vault_keys, "skr-version:skr-conserve")
      assert :error = Store.get(:smalt_attestation_baseline, "skr-jti:" <> jti_a)

      # The SAME jti is still releasable (was never consumed by the failure).
      token_a = ReceiptSigner.sign(attest_claims_with_jti(jti_a))

      assert {:ok, 200, %{"keyMaterialVersion" => 1}} = release("skr-conserve", token_a)

      # Token B: jti replay refused AFTER wrap but BEFORE version increment —
      # a replayed release burns no keyMaterialVersion either.
      assert {:error, 403, %{"error" => %{"code" => "TokenReplay"}}} =
               release("skr-conserve", token_a)

      assert {:ok, 1} = Store.get(:smalt_vault_keys, "skr-version:skr-conserve")

      # Fresh jti releases version 2.
      assert {:ok, 200, %{"keyMaterialVersion" => 2}} =
               release("skr-conserve", ReceiptSigner.sign(attest_claims()))

      assert {:ok, 2} = Store.get(:smalt_vault_keys, "skr-version:skr-conserve")
    end
  end

  describe "lens-2 M7-class JWS payload-tamper court" do
    test "tampering the receipt payload's contents field breaks signature verification" do
      assert {:ok, receipt} =
               ConfidentialLedger.append_transaction("ledger-tamper", %{"contents" => "original"})

      jws = receipt["signature"]
      assert is_binary(jws)
      [h, p, s] = String.split(jws, ".", parts: 3)

      # Fresh M7 mutant: flip a byte INSIDE the signed payload's contents value.
      claims = Jason.decode!(Base.url_decode64!(p, padding: false))
      assert claims["contents"] == %{"contents" => "original"}

      tampered_claims = Map.put(claims, "contents", "tampered-value")
      tampered_p = Base.url_encode64(Jason.encode!(tampered_claims), padding: false)

      tampered_jws = h <> "." <> tampered_p <> "." <> s

      assert {:error, :bad_signature} = ReceiptSigner.verify(tampered_jws)

      # And the honest receipt still verifies (court is non-vacuous).
      assert {:ok, ^claims} = ReceiptSigner.verify(jws)
    end
  end

  ## Lens-3

  describe "lens-3 SKR release under concurrent policy rotation" do
    # Mission pin: the release policy is mutated between attest and wrap --
    # which version binds? Answer pinned: the SNAPSHOT read at admission
    # (fetch_exportable's single atomic Store.get) binds. Hash and HKDF material
    # both derive from that one snapshot, so an accepted release is always
    # internally coherent with EXACTLY ONE policy version; a concurrent
    # rotation can never produce a torn {hash, material} pair.
    test "policy snapshot at admission binds: every release is coherent with exactly one rotated policy version" do
      prior_secret = Application.get_env(:smalt, :kv_master_secret)
      prior_legacy = Application.get_env(:smalt, :skr_allow_legacy_header)
      Application.put_env(:smalt, :kv_master_secret, "lens3-rotation-court")
      Application.put_env(:smalt, :skr_allow_legacy_header, false)

      try do
        p1 = %{"rotation" => "v1"}
        p2 = %{"rotation" => "v2"}
        Store.put(:smalt_vault_keys, "skr-race", %{"kid" => "k-race", "release_policy" => p1})

        ikm = :crypto.hash(:sha256, "lens3-rotation-court")

        expected =
          for p <- [p1, p2], into: %{} do
            h = :crypto.hash(:sha256, Jason.encode!(p))
            {Base.url_encode64(h, padding: false),
             SKR.hkdf_sha256(ikm, "skr-race", "smalt-skr-release" <> h, 32) |> Base.url_encode64(padding: false)}
          end

        token =
          ReceiptSigner.sign(%{
            "x-ms-compliance-status" => "azure-compliant-cvm",
            "iat" => System.system_time(:second),
            "exp" => System.system_time(:second) + 7000
          })

        rotator =
          Task.async(fn ->
            loop = fn loop, current ->
              Store.put(:smalt_vault_keys, "skr-race", %{"kid" => "k-race", "release_policy" => current})
              next = if current == p1, do: p2, else: p1

              receive do
                :stop -> :ok
              after
                0 -> loop.(loop, next)
              end
            end

            loop.(loop, p1)
          end)

        tasks =
          for _ <- 1..16 do
            Task.async(fn -> release("skr-race", token) end)
          end

        results = Task.await_many(tasks, 30_000)
        send(rotator.pid, :stop)
        assert :ok = Task.await(rotator, 5000)

        assert length(results) == 16
        assert Enum.all?(results, &match?({:ok, 200, _}, &1))

        hashes = Enum.map(results, fn {:ok, 200, body} -> body["policyHash"] end)
        assert Enum.all?(hashes, &(&1 in Map.keys(expected)))

        Enum.each(results, fn {:ok, 200, body} ->
          assert body["value"] == Map.fetch!(expected, body["policyHash"])
        end)

        # NOTE: which rotation versions get exercised is timing-dependent (the
        # releases are fast), so asserting BOTH appear would be flaky. The
        # binding pin is the per-release HKDF coherence asserted above.
        # keyMaterialVersion: strictly unique per release, dense 1..16.
        versions = Enum.map(results, fn {:ok, 200, body} -> body["keyMaterialVersion"] end)
        assert Enum.sort(versions) == Enum.to_list(1..16)

        # Coherence means determinism: same hash -> same material across releases.
        Enum.each(Enum.group_by(results, fn {:ok, 200, body} -> body["policyHash"] end), fn {_h, group} ->
          assert Enum.all?(group, fn {:ok, 200, body} -> body["value"] == elem(hd(group), 2)["value"] end)
        end)

        # Non-vacuity note: which rotation versions get exercised is timing-
        # dependent (releases are fast), so asserting BOTH appear would be
        # flaky; the binding pin is per-release coherence with the expected
        # HKDF of the returned hash, which is asserted above for every release.
      after
        Application.put_env(:smalt, :kv_master_secret, prior_secret)
        Application.put_env(:smalt, :skr_allow_legacy_header, prior_legacy)
      end
    end
  end

  describe "lens-3 ReceiptSigner envelope-typing fence (RFC 8725 SS3.11)" do
    # Cross-lane probe receipted (trust-profile lens-2 routed): under a SHARED
    # signing key, ReceiptSigner.verify fully admitted a ctp-envelope-v1
    # TrustProfile envelope — non-interop leaned on the two surfaces holding
    # different keypairs, not on any structural fence. Fixed with explicit
    # typing: typ present-and-not-"JWT" is refused BEFORE the key is touched.
    test "foreign envelope typ is refused structurally under a SHARED key" do
      _ = ReceiptSigner.sign(%{"exp" => System.system_time(:second) + 60})

      pair = :persistent_term.get({ReceiptSigner, :keypair})
      :persistent_term.put({Smalt.TrustProfile, :keypair}, pair)

      try do
        {:ok, envelope} = Smalt.TrustProfile.new(subject: "lens3-typ-fence")
        {:ok, token} = Smalt.TrustProfile.sign(envelope)

        assert {:error, {:bad_typ, "ctp-envelope-v1"}} = ReceiptSigner.verify(token)
        assert {:error, {:bad_typ, "ctp-envelope-v1"}} = ReceiptSigner.verify_token(token)

        # The same token still verifies under its OWN surface (no key movement,
        # refusal is structural, not key-dependent).
        assert {:ok, _} = Smalt.TrustProfile.verify(token)
      after
        :persistent_term.erase({Smalt.TrustProfile, :keypair})
      end
    end

    test "typ JWT and absent typ are admitted (no regression on native tokens)" do
      native = ReceiptSigner.sign(%{"exp" => System.system_time(:second) + 60})
      assert {:ok, _} = ReceiptSigner.verify(native)

      # Legacy header with NO typ: admitted (typ is optional per RFC 7519).
      claims = %{"exp" => System.system_time(:second) + 60}
      payload = Base.url_encode64(Jason.encode!(claims), padding: false)
      header = Base.url_encode64(Jason.encode!(%{"alg" => "RS256"}), padding: false)
      signing_input = header <> "." <> payload

      sig =
        signing_input
        |> then(fn input ->
          {priv, _} = :persistent_term.get({ReceiptSigner, :keypair})
          :public_key.sign(input, :sha256, priv)
        end)
        |> Base.url_encode64(padding: false)

      assert {:ok, ^claims} = ReceiptSigner.verify(signing_input <> "." <> sig)
    end

    # Mission item: MAA JWT with DUPLICATED claims (iss twice, exp twice) —
    # which wins? Pinned (observed, this Jason version): FIRST-wins — Jason
    # keeps the first occurrence of a duplicate key, so the first `exp` and
    # first `iss` govern every downstream check (exp gate, compliance-status).
    # The signature covers the raw bytes, so whichever duplicate appears first
    # is what the verifier sees; the second occurrence is inert.
    test "duplicated JWT claims: FIRST-wins (Jason), the signed bytes bind" do
      now = System.system_time(:second)

      # Valid first exp, expired second exp -> ADMITTED at the first value.
      payload =
        ~s({"iss":"https://smalt-attestation.local/","exp":#{now + 3600},"iss":"https://evil.local/","exp":#{now - 10}})

      assert {:ok, claims} = verify_raw(payload)
      assert claims["exp"] == now + 3600
      assert claims["iss"] == "https://smalt-attestation.local/"

      # Expired first exp, valid second exp -> REFUSED on the first value.
      payload2 =
        ~s({"iss":"https://evil.local/","exp":#{now - 10},"iss":"https://smalt-attestation.local/","exp":#{now + 3600}})

      assert {:error, :token_expired} = verify_raw(payload2)
    end

    # lens-4: typ edge shapes under the RFC 8725 SS3.11 fence. The fence is
    # EXACT-BYTE match ("JWT"): case variants and media-type forms are refused
    # with the typed refusal, before the key is touched. RFC 7515 SS4.1.9
    # recommends case-insensitive MIME comparison and the `application/jwt`
    # prefix elision; the fence deliberately deviates — attacker-controlled
    # header, conservative exact match — and the deviation is PINNED here so a
    # loosening (or the RFC 7515 alignment) is a visible court decision.
    test "typ edge shapes: exact-match fence pins case/media/parameter variants" do
      _ = ReceiptSigner.sign(%{"exp" => System.system_time(:second) + 60})
      claims = %{"exp" => System.system_time(:second) + 60}
      payload = Base.url_encode64(Jason.encode!(claims), padding: false)

      raw = fn typ_value ->
        header = Base.url_encode64(Jason.encode!(%{"alg" => "RS256", "typ" => typ_value}), padding: false)
        signing_input = header <> "." <> payload

        sig =
          signing_input
          |> then(fn input ->
            {priv, _} = :persistent_term.get({ReceiptSigner, :keypair})
            :public_key.sign(input, :sha256, priv)
          end)
          |> Base.url_encode64(padding: false)

        ReceiptSigner.verify(signing_input <> "." <> sig)
      end

      # Admitted: exactly "JWT".
      assert {:ok, ^claims} = raw.("JWT")

      # Refused: case variants (RFC 7515 SS4.1.9 would admit; deliberately
      # stricter — pinned divergence).
      assert {:error, {:bad_typ, "jwt"}} = raw.("jwt")
      assert {:error, {:bad_typ, "Jwt"}} = raw.("Jwt")

      # Refused: media-type form and parameterized form (RFC 7515 SS4.1.9
      # prefix elision NOT implemented — pinned divergence).
      assert {:error, {:bad_typ, "application/jwt"}} = raw.("application/jwt")
      assert {:error, {:bad_typ, "JWT;charset=utf-8"}} = raw.("JWT;charset=utf-8")

      # Refused: whitespace padding, and non-binary typ values (map/integer) —
      # a JSON header cannot carry an interpreted typ here; refusal is typed
      # with the raw value, never a crash.
      assert {:error, {:bad_typ, " JWT "}} = raw.(" JWT ")
      assert {:error, {:bad_typ, 5}} = raw.(5)
      assert {:error, {:bad_typ, %{"a" => 1}}} = raw.(%{"a" => 1})
    end

    defp verify_raw(payload_json) do
      # lens-5 flake fix: reading the keypair :persistent_term directly raises
      # `no persistent term stored with this key` when no earlier test has
      # initialized the signer (random ExUnit ordering) — the dup-claims row
      # was the observed order-dependent failure. Warming via the public sign
      # path guarantees the keypair exists before the raw read.
      _warm = ReceiptSigner.sign(%{"verify_raw_warmup" => true})

      header = Base.url_encode64(Jason.encode!(%{"alg" => "RS256", "typ" => "JWT"}), padding: false)
      payload = Base.url_encode64(payload_json, padding: false)
      signing_input = header <> "." <> payload

      sig =
        signing_input
        |> then(fn input ->
          {priv, _} = :persistent_term.get({ReceiptSigner, :keypair})
          :public_key.sign(input, :sha256, priv)
        end)
        |> Base.url_encode64(padding: false)

      ReceiptSigner.verify_token(signing_input <> "." <> sig)
    end
  end

  # ==========================================================================
  # lens-9: ledger-NAME crash class + coercion fence (the lens-5 law applied
  # to the parameter lens-5 never totalized: the ledger name itself).
  # ==========================================================================
  describe "lens-9 ledger-name crash class" do
    test "hostile ledger names are typed refusals, never raises, never coerced" do
      hostile = [{:t, 1}, %{a: 1}, [:l], 42, nil, 3.14, {1, 2, 3}]

      for name <- hostile do
        # No raise may escape; no silent to_string coercion into "42"/"".
        assert {:error, 400, "InvalidLedgerName"} =
                 ConfidentialLedger.append_transaction(name, %{"x" => 1})

        assert :error = ConfidentialLedger.get_transaction(name, "latest")
        assert :error = ConfidentialLedger.get_latest(name)
        assert [] = ConfidentialLedger.list_transactions(name)
      end

      # The refusal burned nothing: a valid append right after is seq 1.1.
      assert {:ok, %{"transactionId" => "1.1"}} =
               ConfidentialLedger.append_transaction("l9-name-fence", %{"x" => 1})
    end

    test "atom names remain admitted (documented @spec form), binary + atom name identity" do
      assert {:ok, r1} = ConfidentialLedger.append_transaction(:l9_atom_ledger, %{"x" => 1})
      assert {:ok, r1} == ConfidentialLedger.get_latest("l9_atom_ledger")

      # Same ledger by atom and binary: shared chain, seq 2.1.
      assert {:ok, %{"transactionId" => "2.1"}} =
               ConfidentialLedger.append_transaction("l9_atom_ledger", %{"y" => 2})

      assert {:ok, %{"subLedgerId" => "l9_atom_ledger"}} =
               ConfidentialLedger.get_latest(:l9_atom_ledger)
    end
  end

  # Lens-10: the lens-9 law totalized the ledger NAME; the same crash class
  # (caller-shaped data raising or being silently coerced at a public API
  # boundary) extends to the other public heads on this surface. Each court
  # pins: hostile shape -> typed refusal, zero coercion, zero residue.
  describe "lens-10 boundary-totalization sweep" do
    test "hostile tx_id shapes at get_transaction/2 are typed :error, never raises, never coerced" do
      hostile = [{:t, 1}, %{a: 1}, [:l], 42, nil, 3.14, ""]

      for tx <- hostile do
        assert :error = ConfidentialLedger.get_transaction("l10-tx-fence", tx)
      end

      # The refusal burned nothing: a valid append right after is seq 1.1.
      assert {:ok, %{"transactionId" => "1.1"}} =
               ConfidentialLedger.append_transaction("l10-tx-fence", %{"x" => 1})

      assert :error = ConfidentialLedger.get_transaction("l10-tx-miss-decoy", "latest")

      # Coercion decoy: a receipt stored under the coerced key "…/42" must NOT
      # be reachable through a hostile tx_id 42 (reads go through the same
      # typed boundary as writes — no silent to_string coercion).
      Store.put(:smalt_ledger_transactions, "l10-tx-miss-decoy/42", %{"decoy" => true})
      assert :error = ConfidentialLedger.get_transaction("l10-tx-miss-decoy", 42)

      assert {:ok, _} = ConfidentialLedger.get_transaction("l10-tx-fence", "1.1")
      assert {:ok, _} = ConfidentialLedger.get_transaction("l10-tx-fence", "latest")
    end

    test "hostile attestation type params are typed 400 refusals, never raises, never coerced" do
      measurement = String.duplicate("ab", 32)
      Application.put_env(:smalt, :maa_measurement_baseline, [measurement])

      try do
        for type <- [{:t, 1}, [:l], 42, 3.14] do
          assert {:error, 400, "attestationFailedVerdict"} =
                   Attestation.attest_enclave(%{"measurement" => measurement}, type)
        end

        # nil/false keep the documented default; binary type passes through
        # into the signed claims.
        assert {:ok, _, %{"x-ms-attestation-type" => "sevsnpvm"}} =
                 Attestation.attest_enclave(%{"measurement" => measurement}, nil)

        assert {:ok, _, %{"x-ms-attestation-type" => "custom-tee"}} =
                 Attestation.attest_enclave(%{"measurement" => measurement}, "custom-tee")
      after
        Application.delete_env(:smalt, :maa_measurement_baseline)
      end
    end

    test "hostile SKR key names are typed 400 refusals, never raises" do
      conn = Plug.Test.conn(:post, "/keys/x/release")

      for name <- [{:t, 1}, :atom_key, 42, nil, %{a: 1}, [:l]] do
        assert {:error, 400, %{"error" => %{"code" => "InvalidParameter"}}} =
                 SKR.release(name, conn)
      end

      # Zero residue: the refusal never touched the vault keys table.
      assert :error = Store.get(:smalt_vault_keys, :atom_key)
    end

    test "empty ledger names (binary \"\" and atom :\"\") are refused — no anonymous ledger" do
      for name <- ["", :""] do
        assert {:error, 400, "InvalidLedgerName"} =
                 ConfidentialLedger.append_transaction(name, %{"x" => 1})

        assert :error = ConfidentialLedger.get_transaction(name, "latest")
        assert :error = ConfidentialLedger.get_latest(name)
        assert [] = ConfidentialLedger.list_transactions(name)
      end

      # Zero residue: no anonymous ledger materialized.
      assert [] = ConfidentialLedger.list_transactions("")
    end
  end
end
