defmodule Smalt.Test.Internal.W3cbVcExportCourtTest do
  @moduledoc """
  W3C-B court (v26.10.22): VC 2.0 export face over the REAL ATH-1 receipt
  chain (`Smalt.Sync.Receipt` absorb/mint) and the REAL
  `Smalt.Security.ReceiptSigner` — real crypto, no mocks. Gates:

    a) mint a real 320-byte receipt, export to VC, verify round-trip
       (frameCount/merkleRoot read from the term, not trusted args)
    b) tamper any subject field -> {:error, {:bad_proof, _}}
    c) disagreeing frame_count/merkle_root overrides refused
    d) bad term (size/magic/version/reserved) refused
    e) VC 2.0 structure pinned
  """

  use ExUnit.Case, async: false

  alias Smalt.Receipt.VcExport
  alias Smalt.Sync.Receipt

  @issuer "did:web:substrate.loopback"

  # Real chain over 7 real frame payloads -> real 320-byte term (as binary
  # and as the hex token mint/1 emits).
  defp mint_real_receipt do
    frames = for i <- 1..7, do: <<i::64, "frame-payload-", i::32>>

    chain = Enum.reduce(frames, Receipt.empty_chain(), &Receipt.absorb(&2, &1))
    token = Receipt.mint(chain)
    term = Base.decode16!(token, case: :lower)
    {token, term}
  end

  defp export(receipt) do
    VcExport.to_vc(receipt,
      issuer: @issuer,
      seq_horizon: {1, 7}
    )
  end

  test "gate a: real receipt -> VC -> round-trip verify" do
    {_token, term} = mint_real_receipt()
    vc = export(term)

    assert {:ok, subject} = VcExport.verify_vc(vc)
    assert subject["receiptDigest"] == Base.encode16(term, case: :lower)
    assert subject["seqHorizon"] == %{"first" => 1, "last" => 7}
    # leafCount=7 read from the term; root = real chain root.
    assert subject["frameCount"] == 7
    assert byte_size(Base.decode16!(subject["merkleRoot"], case: :lower)) == 32
  end

  test "gate a2: hex token input equals term input" do
    {token, term} = mint_real_receipt()
    assert export(token)["credentialSubject"] == export(term)["credentialSubject"]
  end

  test "gate b1: tampered receiptDigest -> verify false" do
    {_t, term} = mint_real_receipt()
    vc = export(term)
    broken = put_in(vc, ["credentialSubject", "receiptDigest"], String.duplicate("ab", 320))
    assert {:error, {:bad_proof, _}} = VcExport.verify_vc(broken)
  end

  test "gate b2: tampered seqHorizon/frameCount/merkleRoot -> verify false" do
    {_t, term} = mint_real_receipt()
    vc = export(term)

    broken_seq = put_in(vc, ["credentialSubject", "seqHorizon", "last"], 99)
    assert {:error, {:bad_proof, _}} = VcExport.verify_vc(broken_seq)

    broken_count = put_in(vc, ["credentialSubject", "frameCount"], 99)
    assert {:error, {:bad_proof, _}} = VcExport.verify_vc(broken_count)

    broken_root = put_in(vc, ["credentialSubject", "merkleRoot"], String.duplicate("cd", 32))
    assert {:error, {:bad_proof, _}} = VcExport.verify_vc(broken_root)
  end

  test "gate b3: forged proofValue (signature over a different subject) -> verify false" do
    {_t, term} = mint_real_receipt()
    vc = export(term)

    # A VC over a DIFFERENT subject (different seq horizon) has a different
    # proofValue; splicing it in must fail the subject-binding check.
    other = VcExport.to_vc(term, issuer: @issuer, seq_horizon: {2, 9})
    forged = put_in(vc, ["proof", "proofValue"], other["proof"]["proofValue"])
    assert {:error, {:bad_proof, _}} = VcExport.verify_vc(forged)
  end

  test "gate c: override disagreeing with the term refused" do
    {_t, term} = mint_real_receipt()

    assert_raise ArgumentError, ~r/disagrees with the receipt term/, fn ->
      VcExport.to_vc(term, issuer: @issuer, seq_horizon: {1, 7}, frame_count: 42)
    end
  end

  test "gate d1: non-320-byte term refused" do
    assert_raise ArgumentError, ~r/320-byte term/, fn ->
      VcExport.to_vc(<<1, 2, 3>>, issuer: @issuer, seq_horizon: {1, 1})
    end
  end

  test "gate d2: bad magic / wrong version refused" do
    bad_magic = String.duplicate("00", 320) |> Base.decode16!(case: :lower)

    assert_raise ArgumentError, ~r/bad receipt magic/, fn ->
      VcExport.to_vc(bad_magic, issuer: @issuer, seq_horizon: {1, 1})
    end

    bad_version =
      Base.decode16!("534d4c54" <> "00000002" <> String.duplicate("00", 312), case: :lower)

    assert_raise ArgumentError, ~r/unsupported receipt version/, fn ->
      VcExport.to_vc(bad_version, issuer: @issuer, seq_horizon: {1, 1})
    end
  end

  test "gate e: VC 2.0 structure pinned" do
    {_t, term} = mint_real_receipt()
    vc = export(term) |> Map.put("id", "urn:uuid:1111")

    assert ["https://www.w3.org/ns/credentials/v2", ctx] = vc["@context"]
    assert %{"@version" => 1.1} = ctx
    assert Map.has_key?(ctx, "receiptDigest")

    assert vc["type"] == ["VerifiableCredential", "MerkleReceiptCredential"]
    assert vc["issuer"] == @issuer
    assert vc["proof"]["type"] == "DataIntegrityProof"
    assert vc["proof"]["cryptosuite"] == "smalt-rs256-jws"
    assert vc["proof"]["proofPurpose"] == "assertionMethod"
    assert String.contains?(vc["proof"]["verificationMethod"], "#key-1")
    assert byte_size(Base.decode16!(vc["proof"]["proofPayloadSha256"], case: :lower)) == 32
  end
end
