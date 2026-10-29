# GLD-5FIX — value-exact round-trip + injection court (real duckdb CLI).
#
# Closes GLD-5's kill list (receipt: docs/jira/v26.10.21/receipts/gld5-ingestion-skeptic.md):
#   * F1 regression pin: a malformed COPY header is refused
#     `{:error, {:injection_token, first_token}}` — the exact flip GLD-5
#     witnessed mid-audit, now fenced so it cannot silently revert.
#   * F2: NULL (`\N`) vs empty string are DISTINCT on the CSV wire
#     (`\N` bare vs `""` quoted) and survive a real duckdb
#     `read_csv(..., nullstr='\N')` load with zero row loss.
#   * F3: formula-injection neutralization (`'` prefix on leading
#     `=`/`+`/`-`/`@`, numeric literals exempt) is asserted on the wire.
#   * P7: a correctness court finally drives `SqlIngest.to_csv` end-to-end.
#
# Chicago discipline: real collaborators only — the real
# `Smalt.SqlIngest` parse/serialize, the real `/opt/homebrew/bin/duckdb`
# CLI process, assertions on duckdb-resident state. No mocks, no sleeps,
# stdlib only (no Jason).
#
# Run: elixir test/integration/gld5fix_roundtrip_court.exs
# Context: solo

defmodule Gld5fix.Court do
  @duckdb "/opt/homebrew/bin/duckdb"
  @dir Path.expand("tmp/gld5fix", File.cwd!())
  @csv Path.join(@dir, "hostile.csv")
  @db Path.join(@dir, "duck.db")

  alias Smalt.SqlIngest

  # Hostile corpus. Every row distinct. Fields deliberately include the
  # exact payloads from the GLD-5 receipt (F2 probe, F3 payloads) plus
  # the round-trip fidelity classes the wave lacked a court for:
  # NULL vs empty vs space, literal-backslash-N value, floats
  # (-0.0 / NaN / 3.10 / 1e-3 / +1), leading zeros, NFD unicode +
  # U+202E RTL override, quotes, commas, embedded newline, tab, and
  # lone `-`/`@` leading chars.
  @rows [
    [:null, "abc", "007", "-0.0", "=cmd|'/c no'!A1", "tail"],
    ["", "x,y", "3.10", "NaN", "+1+1", "tail"],
    [" ", "quote\"inside", "1e-3", "+1", "-1+1", "tail"],
    ["\\N", String.normalize("café", :nfd), "0", "-1", "@SUM(1)", "tail"],
    ["line1\nline2", "\t", "-", "12.5", "=1+1", "tail"],
    ["\u202Eoverlay", "end", "999999999999999999", "-.5", "@x", "tail"]
  ]

  @cols ["c0", "c1", "c2", "c3", "c4", "c5"]

  def run do
    File.rm_rf!(@dir)
    File.mkdir_p!(@dir)

    # — Leg 1: F1 regression pin (the GLD-5 witnessed flip) —
    poison_header = "COPY public.t; DROP TABLE secrets-- (a) FROM stdin;\n1\t2\n\\.\n"

    {:error, {:injection_token, refused}} = SqlIngest.parse_dump(poison_header)
    "t;" = refused
    IO.puts("leg1 F1 pin: malformed COPY header refused {:injection_token, #{inspect(refused)}}")

    {:error, {:injection_token, refused2}} =
      SqlIngest.parse_dump("COPY \"users; DROP TABLE users; --\" (id) FROM stdin;\n1\n\\.\n")

    "\"users;" = refused2
    IO.puts("leg1b F1 pin: quoted-identifier injection target refused: #{inspect(refused2)} (whole header refused, nothing ingested)")

    # — Leg 2: hostile corpus parse (COPY text, real unescape) —
    dump =
      "COPY hostile (#{@cols |> Enum.join(", ")}) FROM stdin;\n" <>
        Enum.join(Enum.map(@rows, &copy_row/1), "\n") <>
        "\n\\.\n"

    {:ok, %{"hostile" => %{columns: cols, rows: parsed}}} = SqlIngest.parse_dump(dump)
    true = cols == @cols
    true = parsed == @rows

    true = Enum.any?(parsed, fn row -> Enum.any?(row, &(&1 == :null)) end)
    n = length(parsed)
    IO.puts("leg2 hostile corpus: #{n} rows parsed, parse_dump == corpus exactly (incl. :null)")

    # — Leg 3: CSV wire-bytes contract (F2 + F3 on the emitted bytes) —
    csv = IO.iodata_to_binary(SqlIngest.to_csv(@cols, parsed))
    File.write!(@csv, csv)
    lines = String.split(csv, "\n")

    # NULL → bare \N; empty string → quoted ""; literal \N value → quoted "\N"
    null_wire = Enum.at(lines, 1) |> String.split(",", parts: 6) |> hd()
    "\\N" = null_wire

    empty_wire = Enum.at(lines, 2) |> String.split(",", parts: 6) |> hd()
    "\"\"" = empty_wire

    litN_wire = Enum.at(lines, 4) |> String.split(",", parts: 6) |> hd()
    "\"\\N\"" = litN_wire

    # F3: neutralization present on formula payloads…
    true = String.contains?(csv, "'=cmd|'/c no'!A1")
    true = String.contains?(csv, "'+1+1")
    true = String.contains?(csv, "'-1+1")
    true = String.contains?(csv, "'@SUM(1)")
    true = String.contains?(csv, "'=1+1")
    true = String.contains?(csv, "'@x")
    true = String.contains?(csv, "'-,12.5")
    # …absent on numeric literals (value-exact round-trip requirement)…
    true = String.contains?(csv, ",-0.0,")
    true = String.contains?(csv, ",3.10,")
    true = String.contains?(csv, ",1e-3,")
    true = String.contains?(csv, ",+1,")
    # …and non-vacuous: a naive to_csv would have emitted `=cmd` raw.
    true = not String.contains?(csv, ",=cmd")

    IO.puts(
      "leg3 CSV wire: \\N / \"\" / \"\\N\" distinct; formula payloads neutralized ('=cmd, '+1+1, '-1+1, '@SUM); numerics byte-exact (-0.0, 3.10, 1e-3, +1)"
    )

    # — Leg 4: load through the REAL duckdb read_csv (nullstr = '\N') —
    {_load_out, 0} = System.cmd(@duckdb, ["-noheader", "-csv", @db, "-c", load_sql()])

    IO.puts("leg4 duckdb load: read_csv(nullstr='\\N') over #{n}-row hostile.csv, 0 errors")

    # — Leg 5: per-row value-exact assertions INSIDE duckdb (typed state,
    # not a mock): every row's every field, NULL-vs-empty included —
    Enum.with_index(parsed, 1)
    |> Enum.each(fn {row, i} ->
      pred = Enum.with_index(row) |> Enum.map_join(" AND ", fn {v, j} -> cell_pred(transport_value(v), j) end)

      {cnt_out, 0} =
        System.cmd(@duckdb, ["-noheader", "-csv", @db, "-c", "SELECT count(*) FROM hostile WHERE #{pred};"])

      "1\n" = cnt_out
      IO.puts("leg5 row #{i}: value-exact in duckdb (1 unique match, NULL/empty/typed cells)")
    end)

    {cnt, 0} = System.cmd(@duckdb, ["-noheader", "-csv", @db, "-c", "SELECT count(*) FROM hostile;"])
    Integer.parse(String.trim_trailing(cnt, "\n")) |> elem(0) |> then(&(^n = &1))

    IO.puts("")

    IO.puts("""
    GLD5FIX COURT: PASS
    corpus: #{@csv} (#{n} rows x 6 cols), sha256: #{Base.encode16(:crypto.hash(:sha256, csv), case: :lower)}
    nulls: wire-\\N -> duckdb NULL; empties: wire-\"\" -> ''; zero row loss (#{n}/#{n})
    formula neutralization: 7 payloads prefixed, 6 numerics byte-exact
    F1 pin: {:injection_token, "t;"} on malformed header (GLD-5 witnessed flip, fenced)
    """)
  end

  # — corpus COPY-row serializer (postgres COPY text escaping) —

  defp copy_row(row),
    do: row |> Enum.map_join("\t", fn
      :null -> "\\N"
      s -> copy_escape(s)
    end)

  defp copy_escape(s),
    do:
      s
      |> String.replace("\\", "\\\\")
      |> String.replace("\n", "\\n")
      |> String.replace("\t", "\\t")

  # — duckdb —

  defp load_sql do
    types = @cols |> Enum.map(&"'#{&1}': 'VARCHAR'") |> Enum.join(", ")

    """
    DROP TABLE IF EXISTS hostile;
    CREATE TABLE hostile AS
      SELECT * FROM read_csv('#{@csv}', header = true,
        columns = {#{types}}, nullstr = '\\N', allow_quoted_nulls = false, all_varchar = true);
    """
  end

  # Per-cell SQL predicate: NULL typed as NULL, values as exact string
  # equality (single quotes doubled per SQL standard).
  # The value-exact target is the documented transport form: formula
  # payloads carry the spreadsheet-standard `'` prefix after neutralization
  # (leg3 pins the exact bytes), numerics and everything else pass through
  # byte-exact, NULL stays NULL.
  @numeric_regex ~r/^[+-]?(\d+(\.\d*)?|\.\d+)([eE][+-]?\d+)?$/

  defp transport_value(:null), do: :null

  defp transport_value(<<?=, _::binary>> = v), do: prefix(v)
  defp transport_value(<<?+, _::binary>> = v), do: prefix(v)
  defp transport_value(<<?@, _::binary>> = v), do: prefix(v)
  defp transport_value(<<?-, _::binary>> = v), do: prefix(v)
  defp transport_value(v), do: v

  defp prefix(v) do
    case Regex.match?(@numeric_regex, v) do
      true -> v
      false -> "'" <> v
    end
  end

  defp cell_pred(:null, j), do: "c#{j} IS NULL"

  defp cell_pred(value, j) when is_binary(value),
    do: "c#{j} = '#{String.replace(value, "'", "''")}'"
end

Code.compile_file(Path.expand("lib/smalt/sql_ingest.ex", File.cwd!()))
Gld5fix.Court.run()
