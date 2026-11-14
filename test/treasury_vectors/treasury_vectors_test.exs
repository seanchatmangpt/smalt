defmodule Smalt.TreasuryVectorsTest do
  @moduledoc """
  Plane 1 published-doc conformance vectors (ISO 20022 pacs.008/camt.053,
  Lithic ASA, Plaid Auth). Fixture-shape checks always run; the module court
  loud-skips with [SKIP] when lib/smalt/treasury is absent.
  """
  use ExUnit.Case, async: true

  @dir __DIR__

  defp read(path), do: File.read!(Path.join(@dir, path))

  defp parse(path) do
    {doc, _} = :xmerl_scan.string(String.to_charlist(read(path)), namespace_conformant: true)
    doc
  end

  defp has?(doc, xpath), do: :xmerl_xpath.string(String.to_charlist(xpath), doc) != []
  defp json(path), do: path |> read() |> :json.decode()

  defp ln(p), do: "//*[local-name()='" <> String.replace(p, "/", "']/*[local-name()='") <> "']"

  test "pacs.008 xsd-shape: mandatory elements present" do
    doc = parse("iso20022/pacs008.xml")

    for p <- ~w(FIToFICstmrCdtTrf/GrpHdr/MsgId FIToFICstmrCdtTrf/GrpHdr/CreDtTm
                FIToFICstmrCdtTrf/GrpHdr/NbOfTxs FIToFICstmrCdtTrf/GrpHdr/SttlmInf/SttlmMtd
                FIToFICstmrCdtTrf/CdtTrfTxInf/PmtId/EndToEndId FIToFICstmrCdtTrf/CdtTrfTxInf/PmtId/UETR
                FIToFICstmrCdtTrf/CdtTrfTxInf/IntrBkSttlmAmt FIToFICstmrCdtTrf/CdtTrfTxInf/ChrgBr
                FIToFICstmrCdtTrf/CdtTrfTxInf/DbtrAgt/FinInstnId/BICFI
                FIToFICstmrCdtTrf/CdtTrfTxInf/CdtrAgt/FinInstnId/BICFI) do
      assert has?(doc, ln(p)), "missing #{p}"
    end

    assert has?(doc, ln("FIToFICstmrCdtTrf/CdtTrfTxInf/IntrBkSttlmAmt") <> "[@Ccy='USD']")
    s = read("iso20022/pacs008.xml")
    assert s =~ ~r/<UETR>[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}<\/UETR>/
    assert s =~ ~r/<BICFI>[A-Z]{6}[A-Z0-9]{2}([A-Z0-9]{3})?<\/BICFI>/
  end

  test "camt.053 xsd-shape: balances and entry; closing = opening + credit entry" do
    doc = parse("iso20022/camt053.xml")

    for p <- ~w(BkToCstmrStmt/GrpHdr/MsgId BkToCstmrStmt/Stmt/Id BkToCstmrStmt/Stmt/Acct/Ccy
                BkToCstmrStmt/Stmt/Bal/Tp/CdOrPrtry/Cd BkToCstmrStmt/Stmt/Bal/CdtDbtInd
                BkToCstmrStmt/Stmt/Ntry/Amt BkToCstmrStmt/Stmt/Ntry/Sts/Cd) do
      assert has?(doc, ln(p)), "missing #{p}"
    end

    [op, cl, entry] =
      Regex.scan(~r/<Amt Ccy="USD">([\d.]+)<\/Amt><CdtDbtInd>CRDT/, read("iso20022/camt053.xml"))
      |> Enum.map(fn [_, a] -> String.to_float(a) end)

    assert Float.round(op + entry, 2) == cl
  end

  test "Lithic ASA request/response shapes" do
    req = json("lithic/asa_request.json")

    for k <- ~w(token card_token status created authorization_amount amount currency merchant avs pos),
        do: assert(Map.has_key?(req, k), "request missing #{k}")

    assert req["status"] == "AUTHORIZATION"
    assert is_integer(req["amount"]) and req["amount"] > 0
    assert Map.has_key?(req["merchant"], "mcc")

    ok = json("lithic/asa_response.json")
    assert ok["token"] == req["token"]
    assert ok["avs_result"] in ~w(MATCH MATCH_ADDRESS_ONLY MATCH_ZIP_ONLY FAIL)

    dec = json("lithic/asa_response_decline.json")
    assert dec["result"] == "DECLINE"
    assert dec["reason"] == "INSUFFICIENT_FUNDS"
  end

  test "Plaid /auth/get request/response shapes" do
    req = json("plaid/auth_get_request.json")
    for k <- ~w(client_id secret access_token), do: assert(Map.has_key?(req, k))
    res = json("plaid/auth_get_response.json")
    for k <- ~w(accounts numbers item request_id), do: assert(Map.has_key?(res, k))
    [acct] = res["accounts"]
    assert acct["subtype"] == "checking" and Map.has_key?(acct["balances"], "iso_currency_code")
    [ach] = res["numbers"]["ach"]
    assert ach["account_id"] == acct["account_id"]
    assert ach["routing"] =~ ~r/^\d{9}$/
    for k <- ~w(ach eft international bacs), do: assert(is_list(res["numbers"][k]))
  end

  describe "smalt treasury module court" do
    test "lib/smalt/treasury present (else loud skip)" do
      root = Path.expand("../../lib/smalt/treasury", __DIR__)

      if File.dir?(root) do
        assert Path.wildcard(Path.join(root, "**/*.ex")) != [],
               "lib/smalt/treasury exists but holds no .ex"
      else
        IO.puts("[SKIP] lib/smalt/treasury absent: Plane 1 module court not run (fixtures validated only)")
      end
    end
  end
end
