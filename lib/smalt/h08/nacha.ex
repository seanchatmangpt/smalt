defmodule Smalt.H08.Nacha do
  @moduledoc """
  NACHA ACH file builder and validator (94-char fixed-width records, blocking factor 10).
  Computes entry hash, debit/credit totals, trace numbers, block count and 9-fill padding;
  validates ABA routing check digits, service class vs transaction codes, and recomputes
  every control field when validating a file.
  """
  alias Smalt.H08.Vocab

  def aba_valid?(r) when is_binary(r) do
    case Regex.run(~r/\A\d{9}\z/, r) do
      nil ->
        false

      _ ->
        d = r |> String.graphemes() |> Enum.map(&String.to_integer/1)
        w = [3, 7, 1, 3, 7, 1, 3, 7, 1]
        rem(d |> Enum.zip(w) |> Enum.map(fn {a, b} -> a * b end) |> Enum.sum(), 10) == 0
    end
  end

  def aba_valid?(_), do: false

  defp t(v, n), do: v |> to_string() |> String.upcase() |> String.slice(0, n) |> String.pad_trailing(n)
  defp n(v, w), do: v |> Integer.to_string() |> String.pad_leading(w, "0")

  defp yymmdd(<<_::binary-size(2), y::binary-size(2), "-", m::binary-size(2), "-", d::binary-size(2)>>), do: y <> m <> d
  defp yymmdd(_), do: nil

  @doc "Returns {:ok, text} | {:error, [issue_string]}."
  def build(%{} = f) do
    batches = f["batches"] || []
    errs = file_errors(f) ++ Enum.flat_map(Enum.with_index(batches, 1), fn {b, i} -> batch_errors(b, i) end)

    if errs != [] or batches == [] do
      {:error, if(batches == [], do: ["NO_BATCHES" | errs], else: errs)}
    else
      {bl, tot} =
        batches
        |> Enum.with_index(1)
        |> Enum.map_reduce(%{entries: 0, hash: 0, debit: 0, credit: 0, records: 0}, fn {b, i}, acc ->
          {lines, c} = batch_lines(b, i)
          acc = %{entries: acc.entries + c.entries, hash: acc.hash + c.hash, debit: acc.debit + c.debit,
                  credit: acc.credit + c.credit, records: acc.records + length(lines)}
          {lines, acc}
        end)

      records = 2 + tot.records
      bf = Vocab.nacha_blocking_factor()
      blocks = div(records + bf - 1, bf)

      fc =
        "9" <> n(length(batches), 6) <> n(blocks, 6) <> n(tot.entries, 8) <> n(rem(tot.hash, 10_000_000_000), 10) <>
          n(tot.debit, 12) <> n(tot.credit, 12) <> String.duplicate(" ", 39)

      pad = List.duplicate(String.duplicate("9", Vocab.nacha_record_len()), blocks * bf - records)
      {:ok, Enum.join([header(f)] ++ List.flatten(bl) ++ [fc] ++ pad, "\n") <> "\n"}
    end
  end

  defp file_errors(f) do
    [
      {aba_valid?(f["immediate_destination"]), "BAD_IMMEDIATE_DESTINATION"},
      {is_binary(f["immediate_origin"]) and Regex.match?(~r/\A\d{9,10}\z/, f["immediate_origin"]), "BAD_IMMEDIATE_ORIGIN"},
      {yymmdd(f["file_date"] || "") != nil, "BAD_FILE_DATE"},
      {is_binary(f["file_time"]) and Regex.match?(~r/\A\d{4}\z/, f["file_time"]), "BAD_FILE_TIME"}
    ]
    |> Enum.reject(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  defp batch_errors(b, i) do
    codes = Vocab.nacha_codes()
    es = b["entries"] || []
    dirs = for e <- es, c = codes[e["transaction_code"]], do: c

    shape =
      [
        {b["service_class"] in Vocab.nacha_service_classes(), "BATCH#{i}_BAD_SERVICE_CLASS"},
        {b["sec"] in Vocab.nacha_secs(), "BATCH#{i}_BAD_SEC"},
        {is_binary(b["odfi"]) and Regex.match?(~r/\A\d{8}\z/, b["odfi"]), "BATCH#{i}_BAD_ODFI"},
        {yymmdd(b["effective_date"] || "") != nil, "BATCH#{i}_BAD_EFFECTIVE_DATE"},
        {es != [], "BATCH#{i}_NO_ENTRIES"},
        {length(dirs) == length(es), "BATCH#{i}_BAD_TRANSACTION_CODE"},
        {class_ok?(b["service_class"], dirs), "BATCH#{i}_SERVICE_CLASS_MISMATCH"}
      ]
      |> Enum.reject(&elem(&1, 0))
      |> Enum.map(&elem(&1, 1))

    shape ++
      Enum.flat_map(Enum.with_index(es, 1), fn {e, j} ->
        [
          {aba_valid?(e["rdfi_routing"]), "BATCH#{i}_ENTRY#{j}_BAD_ROUTING"},
          {is_integer(e["amount_cents"]) and e["amount_cents"] > 0 and e["amount_cents"] <= 9_999_999_999, "BATCH#{i}_ENTRY#{j}_BAD_AMOUNT"},
          {is_binary(e["account"]) and e["account"] != "", "BATCH#{i}_ENTRY#{j}_BAD_ACCOUNT"}
        ]
        |> Enum.reject(&elem(&1, 0))
        |> Enum.map(&elem(&1, 1))
      end)
  end

  defp class_ok?("220", dirs), do: Enum.all?(dirs, &(&1 == :credit))
  defp class_ok?("225", dirs), do: Enum.all?(dirs, &(&1 == :debit))
  defp class_ok?(_, _), do: true

  defp header(f) do
    dest = f["immediate_destination"]
    org = f["immediate_origin"]
    org10 = if byte_size(org) == 9, do: " " <> org, else: org
    mod = (f["file_id_modifier"] || "A") |> to_string() |> String.upcase() |> String.slice(0, 1)

    "101" <> " " <> dest <> org10 <> yymmdd(f["file_date"]) <> f["file_time"] <> mod <> "094" <> "10" <> "1" <>
      t(f["destination_name"] || "", 23) <> t(f["origin_name"] || "", 23) <> t(f["reference_code"] || "", 8)
  end

  defp batch_lines(b, i) do
    codes = Vocab.nacha_codes()
    odfi = b["odfi"]
    bn = b["batch_number"] || i

    bh =
      "5" <> b["service_class"] <> t(b["company_name"] || "", 16) <> t(b["discretionary"] || "", 20) <>
        t(b["company_id"] || "", 10) <> b["sec"] <> t(b["entry_description"] || "", 10) <> t(b["descriptive_date"] || "", 6) <>
        yymmdd(b["effective_date"]) <> "   " <> "1" <> odfi <> n(bn, 7)

    {elines, c} =
      b["entries"]
      |> Enum.with_index(1)
      |> Enum.map_reduce(%{entries: 0, hash: 0, debit: 0, credit: 0}, fn {e, j}, acc ->
        r = e["rdfi_routing"]
        {r8, chk} = String.split_at(r, 8)
        amt = e["amount_cents"]
        dir = codes[e["transaction_code"]]

        line =
          "6" <> e["transaction_code"] <> r8 <> chk <> t(e["account"], 17) <> n(amt, 10) <> t(e["individual_id"] || "", 15) <>
            t(e["individual_name"] || "", 22) <> "  " <> "0" <> odfi <> n(j, 7)

        {line,
         %{entries: acc.entries + 1, hash: acc.hash + String.to_integer(r8),
           debit: acc.debit + if(dir == :debit, do: amt, else: 0), credit: acc.credit + if(dir == :credit, do: amt, else: 0)}}
      end)

    bc =
      "8" <> b["service_class"] <> n(c.entries, 6) <> n(rem(c.hash, 10_000_000_000), 10) <> n(c.debit, 12) <> n(c.credit, 12) <>
        t(b["company_id"] || "", 10) <> String.duplicate(" ", 19) <> String.duplicate(" ", 6) <> odfi <> n(bn, 7)

    {[bh] ++ elines ++ [bc], c}
  end

  @doc "Validate a NACHA file text; {:ok, summary} | {:error, [issue_string]}."
  def validate(text) when is_binary(text) do
    lines = text |> String.split(~r/\r?\n/, trim: true)
    len = Vocab.nacha_record_len()
    bf = Vocab.nacha_blocking_factor()

    cond do
      lines == [] -> {:error, ["EMPTY_FILE"]}
      Enum.any?(lines, &(String.length(&1) != len)) -> {:error, ["BAD_RECORD_LENGTH"]}
      rem(length(lines), bf) != 0 -> {:error, ["BAD_BLOCK_COUNT"]}
      true -> check(lines)
    end
  end

  def validate(_), do: {:error, ["EMPTY_FILE"]}

  defp check(lines) do
    body = Enum.reject(lines, &String.starts_with?(&1, "999999999999"))
    body = Enum.reject(body, &(&1 == String.duplicate("9", Vocab.nacha_record_len())))
    [first | _] = body
    last = List.last(body)

    if not String.starts_with?(first, "1") or not String.starts_with?(last, "9") do
      {:error, ["BAD_FILE_FRAMING"]}
    else
      inner = body |> Enum.drop(1) |> Enum.drop(-1)
      {batches, errs} = group(inner, [], nil, [])
      errs = errs ++ Enum.flat_map(batches, &verify_batch/1) ++ verify_file(last, batches, length(lines))

      if errs == [],
        do: {:ok, %{"batches" => length(batches), "entries" => Enum.sum(for b <- batches, do: length(b.entries)), "records" => length(lines)}},
        else: {:error, errs}
    end
  end

  defp group([], acc, nil, errs), do: {Enum.reverse(acc), errs}
  defp group([], acc, _open, errs), do: {Enum.reverse(acc), errs ++ ["UNCLOSED_BATCH"]}

  defp group([l | rest], acc, cur, errs) do
    case {String.first(l), cur} do
      {"5", nil} -> group(rest, acc, %{header: l, entries: []}, errs)
      {"6", %{} = c} -> group(rest, acc, %{c | entries: c.entries ++ [l]}, errs)
      {"8", %{} = c} -> group(rest, [Map.put(c, :control, l) | acc], nil, errs)
      _ -> group(rest, acc, cur, errs ++ ["BAD_RECORD_SEQUENCE"])
    end
  end

  defp verify_batch(%{header: _h, entries: es, control: c}) do
    hash = es |> Enum.map(&String.to_integer(String.slice(&1, 3, 8))) |> Enum.sum() |> rem(10_000_000_000)
    codes = Vocab.nacha_codes()
    amt = fn l -> String.to_integer(String.slice(l, 29, 10)) end
    sum = fn dir -> es |> Enum.filter(&(codes[String.slice(&1, 1, 2)] == dir)) |> Enum.map(amt) |> Enum.sum() end

    aba =
      es
      |> Enum.reject(&aba_valid?(String.slice(&1, 3, 9)))
      |> Enum.map(fn _ -> "BAD_ROUTING_CHECK_DIGIT" end)

    [
      {String.to_integer(String.slice(c, 4, 6)) == length(es), "BATCH_ENTRY_COUNT_MISMATCH"},
      {String.to_integer(String.slice(c, 10, 10)) == hash, "BATCH_ENTRY_HASH_MISMATCH"},
      {String.to_integer(String.slice(c, 20, 12)) == sum.(:debit), "BATCH_DEBIT_TOTAL_MISMATCH"},
      {String.to_integer(String.slice(c, 32, 12)) == sum.(:credit), "BATCH_CREDIT_TOTAL_MISMATCH"}
    ]
    |> Enum.reject(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
    |> Kernel.++(aba)
  end

  defp verify_file(fc, batches, total_lines) do
    entries = Enum.sum(for b <- batches, do: length(b.entries))
    hash = batches |> Enum.map(&String.to_integer(String.slice(&1.control, 10, 10))) |> Enum.sum() |> rem(10_000_000_000)
    deb = batches |> Enum.map(&String.to_integer(String.slice(&1.control, 20, 12))) |> Enum.sum()
    cred = batches |> Enum.map(&String.to_integer(String.slice(&1.control, 32, 12))) |> Enum.sum()
    bf = Vocab.nacha_blocking_factor()

    [
      {String.to_integer(String.slice(fc, 1, 6)) == length(batches), "FILE_BATCH_COUNT_MISMATCH"},
      {String.to_integer(String.slice(fc, 7, 6)) == div(total_lines, bf), "FILE_BLOCK_COUNT_MISMATCH"},
      {String.to_integer(String.slice(fc, 13, 8)) == entries, "FILE_ENTRY_COUNT_MISMATCH"},
      {String.to_integer(String.slice(fc, 21, 10)) == hash, "FILE_ENTRY_HASH_MISMATCH"},
      {String.to_integer(String.slice(fc, 31, 12)) == deb, "FILE_DEBIT_TOTAL_MISMATCH"},
      {String.to_integer(String.slice(fc, 43, 12)) == cred, "FILE_CREDIT_TOTAL_MISMATCH"}
    ]
    |> Enum.reject(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end
end
