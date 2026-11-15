defmodule Smalt.H08.Pain001 do
  @moduledoc """
  ISO 20022 pain.001.001.09 customer credit transfer initiation: builder, parser and a
  stateful executor that debits the debtor account in the ledger (credits the creditor
  when it is a known internal account) and returns a pain.002-style status report.
  Insufficient funds rejects the transaction with external reason AM04.
  """
  alias Smalt.H08.{Ledger, Vocab}
  alias Smalt.Treasury.Iso20022

  @ns "urn:iso:std:iso:20022:tech:xsd:pain.001.001.09"

  @doc "p: msg_id, created_at, exec_date, initiator, debtor{name,account,routing}, payments[%{end_to_end_id, amount_cents, creditor{name,account,routing}}]"
  def build(p) do
    cur = Vocab.currency()
    total = Enum.sum(Enum.map(p.payments, & &1.amount_cents))

    txs =
      Enum.map_join(p.payments, "", fn t ->
        "<CdtTrfTxInf><PmtId><EndToEndId>#{Iso20022.esc(t.end_to_end_id)}</EndToEndId></PmtId><Amt><InstdAmt Ccy=\"#{cur}\">#{Iso20022.amt(t.amount_cents)}</InstdAmt></Amt><CdtrAgt><FinInstnId><ClrSysMmbId><MmbId>#{Iso20022.esc(t.creditor.routing)}</MmbId></ClrSysMmbId></FinInstnId></CdtrAgt><Cdtr><Nm>#{Iso20022.esc(t.creditor.name)}</Nm></Cdtr><CdtrAcct><Id><Othr><Id>#{Iso20022.esc(t.creditor.account)}</Id></Othr></Id></CdtrAcct></CdtTrfTxInf>"
      end)

    d = p.debtor

    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Document xmlns=\"#{@ns}\"><CstmrCdtTrfInitn><GrpHdr><MsgId>#{Iso20022.esc(p.msg_id)}</MsgId><CreDtTm>#{Iso20022.esc(p.created_at)}</CreDtTm><NbOfTxs>#{length(p.payments)}</NbOfTxs><CtrlSum>#{Iso20022.amt(total)}</CtrlSum><InitgPty><Nm>#{Iso20022.esc(p.initiator)}</Nm></InitgPty></GrpHdr><PmtInf><PmtInfId>#{Iso20022.esc(p.msg_id)}-1</PmtInfId><PmtMtd>TRF</PmtMtd><ReqdExctnDt><Dt>#{Iso20022.esc(p.exec_date)}</Dt></ReqdExctnDt><Dbtr><Nm>#{Iso20022.esc(d.name)}</Nm></Dbtr><DbtrAcct><Id><Othr><Id>#{Iso20022.esc(d.account)}</Id></Othr></Id></DbtrAcct><DbtrAgt><FinInstnId><ClrSysMmbId><MmbId>#{Iso20022.esc(d.routing)}</MmbId></ClrSysMmbId></FinInstnId></DbtrAgt>#{txs}</PmtInf></CstmrCdtTrfInitn></Document>"
  end

  @doc "Returns {:ok, parsed} or {:error, {:missing, tag} | {:bad_amount, e2e}}."
  def parse(xml) when is_binary(xml) do
    with {:ok, msg} <- tag(xml, "MsgId"),
         {:ok, nb} <- tag(xml, "NbOfTxs"),
         {:ok, dacct} <- tag(inner(xml, "DbtrAcct"), "Id"),
         {:ok, dname} <- tag(inner(xml, "Dbtr"), "Nm"),
         {:ok, txs} <- txs(xml) do
      {:ok,
       %{msg_id: msg, created_at: opt(xml, "CreDtTm"), nb_of_txs: nb, ctrl_sum: opt(inner(xml, "GrpHdr"), "CtrlSum"),
         exec_date: opt(inner(xml, "ReqdExctnDt"), "Dt"), debtor: %{name: dname, account: dacct}, txs: txs}}
    end
  end

  def parse(_), do: {:error, {:missing, "Document"}}

  defp txs(xml) do
    found = Regex.scan(~r{<CdtTrfTxInf>(.*?)</CdtTrfTxInf>}s, xml)

    if found == [] do
      {:error, {:missing, "CdtTrfTxInf"}}
    else
      Enum.reduce_while(found, {:ok, []}, fn [_, t], {:ok, acc} ->
        with {:ok, e2e} <- tag(t, "EndToEndId"),
             {:ok, cur, amt} <- instd(t),
             {:ok, cname} <- tag(inner(t, "Cdtr"), "Nm"),
             {:ok, cacct} <- tag(inner(t, "CdtrAcct"), "Id") do
          {:cont, {:ok, acc ++ [%{end_to_end_id: e2e, currency: cur, amount_cents: amt, creditor: %{name: cname, account: cacct}}]}}
        else
          {:error, _} = e -> {:halt, e}
        end
      end)
    end
  end

  defp instd(t) do
    case Regex.run(~r|<InstdAmt Ccy="([A-Z]{3})">([0-9]+(?:\.[0-9]{1,2})?)</InstdAmt>|, t) do
      [_, cur, v] ->
        c =
          case String.split(v, ".") do
            [w] -> String.to_integer(w) * 100
            [w, f] -> String.to_integer(w) * 100 + String.to_integer(String.pad_trailing(f, 2, "0"))
          end

        {:ok, cur, c}

      _ ->
        {:error, {:missing, "InstdAmt"}}
    end
  end

  @doc "Execute a parsed initiation against the ledger; returns the pain.002-style report map."
  def execute(%{} = p) do
    count = length(p.txs)
    sum = Enum.sum(Enum.map(p.txs, & &1.amount_cents))
    booked = p.exec_date || String.slice(p.created_at || "", 0, 10)

    cond do
      Ledger.seen_msg?(p.msg_id) ->
        report(p, Vocab.group_rejected(), Vocab.reason_duplicate(), [])

      p.nb_of_txs != Integer.to_string(count) or (p.ctrl_sum != nil and p.ctrl_sum != Iso20022.amt(sum)) ->
        report(p, Vocab.group_rejected(), Vocab.reason_file_format(), [])

      true ->
        Ledger.mark_msg(p.msg_id)
        results = Enum.map(p.txs, &run_tx(p, &1, booked))
        ok = Enum.count(results, &(&1["status"] == Vocab.tx_settled()))

        g =
          cond do
            ok == count -> Vocab.group_accepted()
            ok == 0 -> Vocab.group_rejected()
            true -> Vocab.group_partial()
          end

        report(p, g, nil, results)
    end
  end

  defp run_tx(p, t, booked) do
    cond do
      t.currency != Vocab.currency() -> rej(t, Vocab.reason_not_allowed_currency())
      true ->
        case Ledger.post(p.debtor.account, :debit, t.amount_cents, %{end_to_end_id: t.end_to_end_id, booked: booked, name: t.creditor.name}) do
          {:ok, _} ->
            if Ledger.account(t.creditor.account) do
              Ledger.post(t.creditor.account, :credit, t.amount_cents, %{end_to_end_id: t.end_to_end_id, booked: booked, name: p.debtor.name})
            end

            %{"end_to_end_id" => t.end_to_end_id, "status" => Vocab.tx_settled(), "reason" => nil, "amount_cents" => t.amount_cents}

          {:error, :insufficient_funds} -> rej(t, Vocab.reason_insufficient_funds())
          {:error, :not_found} -> rej(t, Vocab.reason_incorrect_account())
          {:error, _} -> rej(t, Vocab.reason_not_allowed_amount())
        end
    end
  end

  defp rej(t, reason),
    do: %{"end_to_end_id" => t.end_to_end_id, "status" => Vocab.tx_rejected(), "reason" => reason, "amount_cents" => t.amount_cents}

  defp report(p, status, reason, results) do
    %{"original_msg_id" => p.msg_id, "group_status" => status, "group_reason" => reason,
      "nb_of_txs" => length(p.txs), "accepted" => Enum.count(results, &(&1["status"] == Vocab.tx_settled())),
      "rejected" => Enum.count(results, &(&1["status"] == Vocab.tx_rejected())), "transactions" => results}
  end

  defp inner(xml, t) do
    case Regex.run(~r{<#{t}>(.*?)</#{t}>}s, xml) do
      [_, i] -> i
      _ -> ""
    end
  end

  defp tag(xml, t) do
    case Regex.run(~r{<#{t}>([^<]*)</#{t}>}, xml) do
      [_, v] -> {:ok, Iso20022.unesc(v)}
      _ -> {:error, {:missing, t}}
    end
  end

  defp opt(xml, t) do
    case tag(xml, t) do
      {:ok, v} -> v
      _ -> nil
    end
  end
end
