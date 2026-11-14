defmodule Smalt.Treasury.Iso20022 do
  @moduledoc "ISO 20022 pacs.008.001.08 initiation and camt.053.001.08 report (deterministic XML)."

  @pacs "urn:iso:std:iso:20022:tech:xsd:pacs.008.001.08"
  @camt "urn:iso:std:iso:20022:tech:xsd:camt.053.001.08"

  def esc(v),
    do:
      v
      |> to_string()
      |> String.replace("&", "&amp;")
      |> String.replace("<", "&lt;")
      |> String.replace(">", "&gt;")
      |> String.replace("\"", "&quot;")
      |> String.replace("'", "&apos;")

  def unesc(v) do
    v
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&apos;", "'")
    |> String.replace("&amp;", "&")
  end

  def amt(cents) when is_integer(cents) and cents >= 0,
    do: "#{div(cents, 100)}.#{cents |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")}"

  def parse_amt(s) do
    case String.split(s, ".") do
      [w] -> String.to_integer(w) * 100
      [w, f] when byte_size(f) == 2 -> String.to_integer(w) * 100 + String.to_integer(f)
    end
  end

  @doc "p: msg_id, created_at, debtor{name,account,routing}, creditor{...}, amount_cents, end_to_end_id, currency"
  def pacs008(p) do
    cur = Map.get(p, :currency, "USD")

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <Document xmlns="#{@pacs}"><FIToFICstmrCdtTrf><GrpHdr><MsgId>#{esc(p.msg_id)}</MsgId><CreDtTm>#{esc(p.created_at)}</CreDtTm><NbOfTxs>1</NbOfTxs><TtlIntrBkSttlmAmt Ccy="#{cur}">#{amt(p.amount_cents)}</TtlIntrBkSttlmAmt><SttlmInf><SttlmMtd>CLRG</SttlmMtd></SttlmInf></GrpHdr><CdtTrfTxInf><PmtId><EndToEndId>#{esc(p.end_to_end_id)}</EndToEndId></PmtId><IntrBkSttlmAmt Ccy="#{cur}">#{amt(p.amount_cents)}</IntrBkSttlmAmt><ChrgBr>SLEV</ChrgBr><Dbtr><Nm>#{esc(p.debtor.name)}</Nm></Dbtr><DbtrAcct><Id><Othr><Id>#{esc(p.debtor.account)}</Id></Othr></Id></DbtrAcct><DbtrAgt><FinInstnId><ClrSysMmbId><MmbId>#{esc(p.debtor.routing)}</MmbId></ClrSysMmbId></FinInstnId></DbtrAgt><CdtrAgt><FinInstnId><ClrSysMmbId><MmbId>#{esc(p.creditor.routing)}</MmbId></ClrSysMmbId></FinInstnId></CdtrAgt><Cdtr><Nm>#{esc(p.creditor.name)}</Nm></Cdtr><CdtrAcct><Id><Othr><Id>#{esc(p.creditor.account)}</Id></Othr></Id></CdtrAcct></CdtTrfTxInf></FIToFICstmrCdtTrf></Document>
    """
    |> String.trim_trailing()
  end

  def parse_pacs008(xml) do
    with {:ok, msg} <- tag(xml, "MsgId"),
         {:ok, e2e} <- tag(xml, "EndToEndId"),
         {:ok, a} <- attr_amt(xml, "IntrBkSttlmAmt"),
         {:ok, dn} <- tag(inner(xml, "Dbtr"), "Nm"),
         {:ok, cn} <- tag(inner(xml, "Cdtr"), "Nm"),
         {:ok, dr} <- tag(inner(xml, "DbtrAgt"), "MmbId"),
         {:ok, cr} <- tag(inner(xml, "CdtrAgt"), "MmbId") do
      {:ok,
       %{msg_id: msg, end_to_end_id: e2e, amount_cents: a, debtor_name: dn, creditor_name: cn,
         debtor_routing: dr, creditor_routing: cr}}
    end
  end

  @doc "entries: [%{amount_cents, direction: :credit|:debit, end_to_end_id, booked: date}]"
  def camt053(%{} = r) do
    cur = Map.get(r, :currency, "USD")
    ents = Enum.map_join(r.entries, "", fn e ->
      ind = if e.direction == :credit, do: "CRDT", else: "DBIT"
      "<Ntry><Amt Ccy=\"#{cur}\">#{amt(e.amount_cents)}</Amt><CdtDbtInd>#{ind}</CdtDbtInd><Sts><Cd>BOOK</Cd></Sts><BookgDt><Dt>#{esc(e.booked)}</Dt></BookgDt><NtryDtls><TxDtls><Refs><EndToEndId>#{esc(e.end_to_end_id)}</EndToEndId></Refs></TxDtls></NtryDtls></Ntry>"
    end)
    net = Enum.reduce(r.entries, 0, fn e, a -> if e.direction == :credit, do: a + e.amount_cents, else: a - e.amount_cents end)
    closing = r.opening_cents + net
    bal = fn code, c ->
      ind = if c < 0, do: "DBIT", else: "CRDT"
      "<Bal><Tp><CdOrPrtry><Cd>#{code}</Cd></CdOrPrtry></Tp><Amt Ccy=\"#{cur}\">#{amt(abs(c))}</Amt><CdtDbtInd>#{ind}</CdtDbtInd></Bal>"
    end

    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Document xmlns=\"#{@camt}\"><BkToCstmrStmt><GrpHdr><MsgId>#{esc(r.msg_id)}</MsgId><CreDtTm>#{esc(r.created_at)}</CreDtTm></GrpHdr><Stmt><Id>#{esc(r.msg_id)}</Id><Acct><Id><Othr><Id>#{esc(r.account)}</Id></Othr></Id></Acct>#{bal.("OPBD", r.opening_cents)}#{bal.("CLBD", closing)}#{ents}</Stmt></BkToCstmrStmt></Document>"
  end

  def parse_camt053(xml) do
    Regex.scan(~r{<Ntry>(.*?)</Ntry>}s, xml)
    |> Enum.reduce_while({:ok, []}, fn [_, n], {:ok, acc} ->
      with {:ok, a} <- attr_amt(n, "Amt"),
           {:ok, ind} <- tag(n, "CdtDbtInd"),
           {:ok, e2e} <- tag(n, "EndToEndId") do
        e = %{amount_cents: a, direction: if(ind == "CRDT", do: :credit, else: :debit), end_to_end_id: e2e}
        {:cont, {:ok, [e | acc]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, %{entries: Enum.reverse(entries)}}
      {:error, _} = e -> e
    end
  end

  defp inner(xml, t) do
    case Regex.run(~r{<#{t}>(.*?)</#{t}>}s, xml) do
      [_, i] -> i
      _ -> ""
    end
  end

  defp tag(xml, t) do
    case Regex.run(~r{<#{t}>([^<]*)</#{t}>}, xml) do
      [_, v] -> {:ok, unesc(v)}
      _ -> {:error, {:missing, t}}
    end
  end

  defp attr_amt(xml, t) do
    case Regex.run(~r|<#{t} Ccy="[A-Z]{3}">([0-9]+\.[0-9]{2})</#{t}>|, xml) do
      [_, v] -> {:ok, parse_amt(v)}
      _ -> {:error, {:missing, t}}
    end
  end
end
