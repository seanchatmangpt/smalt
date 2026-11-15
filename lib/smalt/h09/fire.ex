defmodule Smalt.H09.Fire do
  @moduledoc """
  1099 e-file planes. FIRE: fixed-width 750-byte T/A/B/C/F records for 1099-NEC (Pub 1220
  layout; B-record offsets: year 2-5, TIN type 11, TIN 12-20, amount1 55-66, amount4 91-102,
  name 248-287, sequence 500-507). IRIS: JSON submission with stateful duplicate detection.
  Integer cents only.
  """
  alias Smalt.H09.{Vocab, State}

  @tin ~r/\A\d{9}\z/

  def build_file(%{"year" => y, "transmitter_tin" => ttin, "transmitter_control" => tcc, "payer" => p, "payees" => ps})
      when is_integer(y) and is_binary(ttin) and is_binary(tcc) and is_map(p) and is_list(ps) and ps != [] do
    with :ok <- tin_ok(ttin),
         :ok <- tin_ok(p["tin"]),
         :ok <- name_ok(p["name"]),
         {:ok, payees} <- payees(ps) do
      n = length(payees)
      sum1 = payees |> Enum.map(& &1.nec) |> Enum.sum()
      sum4 = payees |> Enum.map(& &1.withheld) |> Enum.sum()

      t = rec("T", 750, [{2, num(y, 4)}, {7, ttin}, {16, pad(tcc, 5)}, {500, num(1, 8)}])
      a = rec("A", 750, [{2, num(y, 4)}, {12, p["tin"]}, {21, name_control(p["name"])}, {26, "NE"}, {28, "14"}, {41, pad(p["name"], 40)}, {500, num(2, 8)}])

      bs =
        payees
        |> Enum.with_index(3)
        |> Enum.map(fn {x, seq} ->
          rec("B", 750, [
            {2, num(y, 4)},
            {7, name_control(x.name)},
            {11, "2"},
            {12, x.tin},
            {21, pad(x.account, 20)},
            {55, num(x.nec, 12)},
            {91, num(x.withheld, 12)},
            {248, pad(x.name, 40)},
            {500, num(seq, 8)}
          ])
        end)

      cseq = n + 3
      c = rec("C", 750, [{2, num(n, 8)}, {16, num(sum1, 18)}, {70, num(sum4, 18)}, {500, num(cseq, 8)}])
      f = rec("F", 750, [{2, num(1, 8)}, {10, String.duplicate("0", 21)}, {50, num(n, 8)}, {500, num(cseq + 1, 8)}])
      records = [t, a] ++ bs ++ [c, f]

      {:ok,
       %{
         record_length: Vocab.fire_record_len(),
         record_count: length(records),
         payee_count: n,
         control_total_amount1_cents: sum1,
         control_total_amount4_cents: sum4,
         records: records
       }}
    end
  end

  def build_file(_), do: {:error, {Vocab.err(:invalid), [:year, :transmitter_tin, :transmitter_control, :payer, :payees]}}

  @doc "Parse a B-record back to fields (round-trip witness)."
  def parse_b(<<"B", _::binary>> = r) when byte_size(r) == 750 do
    %{
      year: slice(r, 2, 4),
      tin: slice(r, 12, 9),
      amount1_cents: slice(r, 55, 12) |> String.to_integer(),
      amount4_cents: slice(r, 91, 12) |> String.to_integer(),
      name: slice(r, 248, 40) |> String.trim_trailing(),
      sequence: slice(r, 500, 8) |> String.to_integer()
    }
  end

  defp slice(r, start, len), do: binary_part(r, start - 1, len)

  defp payees(ps) do
    Enum.reduce_while(ps, {:ok, []}, fn x, {:ok, acc} ->
      with %{} <- x,
           :ok <- tin_ok(x["tin"]),
           :ok <- name_ok(x["name"]),
           nec when is_integer(nec) and nec >= 0 <- x["nonemployee_comp_cents"],
           w when is_integer(w) and w >= 0 and w <= nec <- Map.get(x, "federal_withheld_cents", 0) do
        {:cont, {:ok, acc ++ [%{tin: x["tin"], name: x["name"], nec: nec, withheld: w, account: x["account"] || ""}]}}
      else
        _ -> {:halt, {:error, {Vocab.err(:invalid), [:payees]}}}
      end
    end)
  end

  defp tin_ok(t) when is_binary(t), do: if(Regex.match?(@tin, t), do: :ok, else: {:error, {Vocab.err(:invalid), [:tin]}})
  defp tin_ok(_), do: {:error, {Vocab.err(:invalid), [:tin]}}
  defp name_ok(n) when is_binary(n) and n != "", do: :ok
  defp name_ok(_), do: {:error, {Vocab.err(:invalid), [:name]}}

  defp name_control(n) do
    n |> String.upcase() |> String.replace(~r/[^A-Z0-9]/, "") |> String.slice(0, 4) |> pad(4)
  end

  defp num(n, w), do: n |> Integer.to_string() |> String.pad_leading(w, "0") |> String.slice(-w, w)
  defp pad(s, w), do: s |> String.slice(0, w) |> String.pad_trailing(w, " ")

  defp rec(type, len, fields) do
    base = String.duplicate(" ", len)
    base = place(base, 1, type)
    Enum.reduce(fields, base, fn {start, val}, acc -> place(acc, start, val) end)
  end

  defp place(bin, start, val) do
    pre = binary_part(bin, 0, start - 1)
    post_from = start - 1 + byte_size(val)
    post = binary_part(bin, post_from, byte_size(bin) - post_from)
    pre <> val <> post
  end

  # ---------------- IRIS ----------------

  def iris_submit(%{"year" => y, "form" => "1099-NEC", "payer_tin" => ptin, "payee_tin" => rtin, "amount_cents" => amt} = b)
      when is_integer(y) and is_integer(amt) and amt >= 0 do
    with :ok <- tin_ok(ptin), :ok <- tin_ok(rtin) do
      key = {y, "1099-NEC", ptin, rtin, Map.get(b, "corrected", false)}

      State.update(fn s ->
        case Map.get(s.filings, key) do
          nil ->
            id = :crypto.hash(:sha256, :erlang.term_to_binary(key)) |> Base.encode16(case: :lower) |> binary_part(0, 16)
            rec = %{id: id, status: "ACCEPTED", year: y, form: "1099-NEC", payer_tin: ptin, payee_tin: rtin, amount_cents: amt}
            {{:ok, rec}, %{s | filings: Map.put(s.filings, key, rec)}}

          _ ->
            {{:error, {Vocab.err(:duplicate), key |> Tuple.to_list() |> Enum.take(4)}}, s}
        end
      end)
    end
  end

  def iris_submit(_), do: {:error, {Vocab.err(:invalid), [:year, :form, :payer_tin, :payee_tin, :amount_cents]}}

  def iris_get(id) do
    State.get(fn s -> Enum.find_value(s.filings, fn {_k, v} -> if v.id == id, do: v end) end)
    |> case do
      nil -> {:error, Vocab.err(:not_found)}
      r -> {:ok, r}
    end
  end
end
