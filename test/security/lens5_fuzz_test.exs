defmodule Smalt.Security.Lens5FuzzTest do
  use ExUnit.Case, async: false
  alias Smalt.Security.{ReceiptSigner, Attestation, ConfidentialLedger}

  # lens-5 cycle-5: hostile-input sweep over the public verify paths.
  # Law: verify paths refuse typed, never raise.
  test "verify paths never raise on hostile inputs" do
    keys = [nil, 42, {}, [], %{}, "a", make_ref(), self()]

    # structural garbage tokens
    tokens =
      for pad <- 0..64 do
        String.duplicate("x", pad)
      end ++
        [
          "",
          ".",
          "..",
          "...",
          "a.b.c.d",
          "!!!.%%$.***",
          Base.url_encode64("not json", padding: false) <> ".x.y",
          Base.url_encode64(~s({"alg":"RS256"}), padding: false) <>
            "." <>
            Base.url_encode64("[]", padding: false) <> ".z",
          Base.url_encode64(~s({"alg":"RS256","typ":123}), padding: false) <>
            "." <>
            Base.url_encode64("{}", padding: false) <> ".w",
          Base.url_encode64(~s({"alg":123}), padding: false) <>
            "." <>
            Base.url_encode64("{}", padding: false) <> ".v",
          Base.url_encode64(~s({"alg":"RS256"}), padding: false) <>
            "." <>
            Base.url_encode64(~s({"exp":"soon"}), padding: false) <> ".u",
          Base.url_encode64(~s({"alg":"RS256"}), padding: false) <>
            "." <>
            Base.url_encode64(~s({"exp":1.5}), padding: false) <> ".t",
          String.duplicate("A", 100_000) <> "." <> String.duplicate("B", 100_000) <> ".C"
        ]

    for t <- tokens do
      assert match?({:error, _}, ReceiptSigner.verify(t)) or
               match?({:ok, _}, ReceiptSigner.verify(t)),
             "verify raised/misreturned on #{inspect(String.slice(t, 0, 40))}"
    end

    for t <- tokens do
      assert match?({:error, _}, ReceiptSigner.verify_token(t)) or
               match?({:ok, _}, ReceiptSigner.verify_token(t)),
             "verify_token raised/misreturned on #{inspect(String.slice(t, 0, 40))}"
    end

    for t <- tokens do
      assert match?({:error, _}, Attestation.verify_token(t)) or
               match?({:ok, _}, Attestation.verify_token(t)),
             "attest verify raised on #{inspect(String.slice(t, 0, 40))}"
    end

    # non-binary token args
    for k <- keys do
      assert match?({:error, _}, ReceiptSigner.verify(k))
      assert match?({:error, _}, ReceiptSigner.verify_token(k))
    end
  end

  test "append path never raises on hostile ledger names and opts" do
    # hostile ledger names (binary guard admits any binary)
    for ledger <- ["", String.duplicate("/", 100), "a/b/c", "\0", String.duplicate("é", 5000)] do
      res = ConfidentialLedger.append_transaction(ledger, %{"k" => "v"})
      assert match?({:ok, _}, res) or match?({:error, _, _}, res), "raise on #{inspect(ledger)}"
    end

    # unknown opts ignored
    assert match?(
             {:ok, _},
             ConfidentialLedger.append_transaction("opts-lens5", %{"a" => 1}, unknown_opt: :x)
           )
  end

  test "get_transaction/list/get_latest never raise on hostile names" do
    for ledger <- ["", "a/b", "\0", String.duplicate("z", 3000)] do
      assert :error == ConfidentialLedger.get_transaction(ledger, "latest") or
               match?({:ok, _}, ConfidentialLedger.get_transaction(ledger, "latest"))

      assert is_list(ConfidentialLedger.list_transactions(ledger))

      assert :error == ConfidentialLedger.get_latest(ledger) or
               match?({:ok, _}, ConfidentialLedger.get_latest(ledger))
    end
  end
end
