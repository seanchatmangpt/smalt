defmodule Smalt.H08.Statements do
  @moduledoc "camt.053 (end-of-day statement) and camt.054 (debit/credit notification) from ledger state."
  alias Smalt.H08.{Ledger, Vocab}
  alias Smalt.Treasury.Iso20022

  @camt054 "urn:iso:std:iso:20022:tech:xsd:camt.054.001.08"

  defp stamp(entries, override) do
    cond do
      is_binary(override) and override != "" -> override
      entries != [] -> List.last(entries).booked <> "T00:00:00"
      true -> Vocab.epoch_stamp()
    end
  end

  def camt053(id, created_at \\ nil) do
    case Ledger.account(id) do
      nil ->
        {:error, :not_found}

      a ->
        es = Ledger.entries(id)

        {:ok,
         Iso20022.camt053(%{msg_id: "CAMT053-#{id}-#{length(es)}", created_at: stamp(es, created_at), account: a.account,
                            opening_cents: Ledger.opening_cents(id), entries: es, currency: Vocab.currency()})}
    end
  end

  def camt054(id, since_seq \\ 0, created_at \\ nil) do
    case Ledger.account(id) do
      nil ->
        {:error, :not_found}

      a ->
        all = Ledger.entries(id)
        es = Enum.filter(all, &(&1.seq > since_seq))
        cur = Vocab.currency()

        ents =
          Enum.map_join(es, "", fn e ->
            ind = if e.direction == :credit, do: "CRDT", else: "DBIT"
            "<Ntry><NtryRef>#{e.seq}</NtryRef><Amt Ccy=\"#{cur}\">#{Iso20022.amt(e.amount_cents)}</Amt><CdtDbtInd>#{ind}</CdtDbtInd><Sts><Cd>BOOK</Cd></Sts><BookgDt><Dt>#{Iso20022.esc(e.booked)}</Dt></BookgDt><NtryDtls><TxDtls><Refs><EndToEndId>#{Iso20022.esc(e.end_to_end_id)}</EndToEndId></Refs></TxDtls></NtryDtls></Ntry>"
          end)

        mid = "CAMT054-#{id}-#{since_seq}-#{length(all)}"

        {:ok,
         "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Document xmlns=\"#{@camt054}\"><BkToCstmrDbtCdtNtfctn><GrpHdr><MsgId>#{mid}</MsgId><CreDtTm>#{Iso20022.esc(stamp(all, created_at))}</CreDtTm></GrpHdr><Ntfctn><Id>#{mid}</Id><Acct><Id><Othr><Id>#{Iso20022.esc(a.account)}</Id></Othr></Id></Acct>#{ents}</Ntfctn></BkToCstmrDbtCdtNtfctn></Document>"}
    end
  end
end
