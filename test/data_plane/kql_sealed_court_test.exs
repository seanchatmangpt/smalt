# W3 (v26.10.22): KQL vectorized operators over SEALED journal segments.
# Corpus law: the query corpus is discover_sealed_segments output — active
# (unsealed) segments are sealed via the real JournalSink frame codec.
# Chicago-style: real sealed segments on a real temp dir, assert on final
# query state; no mocks.
#
# Operators under court: bin(TimeGenerated, binsize) summarize keys,
# countif/sumif, in / in~, dcount. Falsifier: the same query over the WRONG
# segment returns different counts (corpus bound); an unsealed segment never
# enters the corpus; unknown operators still fail typed (fail-closed ratchet).
defmodule DataPlane.KqlSealedCourtTest do
  use ExUnit.Case, async: false

  alias Smalt.DataPlane.KQL
  alias Smalt.Storage.JournalReader
  alias Smalt.Storage.JournalSink

  @event_type 1
  @table_id 7

  setup do
    dir = Path.join(System.tmp_dir!(), "w3-kql-sealed-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "sealed"))
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  # Seal a real segment via the JournalSink frame codec: JSON payloads
  # %{"TimeGenerated" => iso, "severity" => n, "device" => "dN"}.
  defp seal_events(dir, events) do
    # Monotonic name counter: :erlang.unique_integer/1 is unique but NOT
    # monotonic across schedulers — name-ordered discovery could hand
    # [seg_a, seg_b] in creation order only by luck (C5 falsifier flake:
    # the 2-event segment sometimes sorted AFTER the 4-event one).
    n =
      max(System.system_time(:native), Process.get(:kql_seg_seq, 0) + 1)
      |> tap(&Process.put(:kql_seg_seq, &1))

    seg =
      Path.join([
        dir,
        "sealed",
        "seg-#{n |> Integer.to_string() |> String.pad_leading(20, "0")}.journal"
      ])

    {:ok, io} = File.open(seg, [:write, :binary])

    Enum.each(Enum.with_index(events), fn {ev, i0} ->
      i = i0 + 1

      payload =
        Jason.encode!(%{
          "TimeGenerated" => iso(ev.ts_ms),
          "severity" => ev.sev,
          "device" => ev.dev
        })

      {frame, _size, _seq} =
        JournalSink.encode_frame(i, ev.ts_ms, @event_type, @table_id, "kql-w3", payload)

      IO.binwrite(io, frame)
    end)

    File.close(io)
    bytes = File.read!(seg)
    count = length(events)

    File.write!(
      seg <> ".meta.json",
      Jason.encode!(%{
        "segment" => Path.basename(seg),
        "bytes" => byte_size(bytes),
        "frames" => count,
        "first_seq" => 1,
        "last_seq" => count,
        "sha256" => Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
      })
    )

    File.write!(seg <> ".seal", "")
    seg
  end

  defp iso(ms), do: DateTime.to_iso8601(DateTime.from_unix!(ms, :millisecond))

  # Real corpus: discover + read every sealed segment, decode payloads to
  # KQL row maps. Active (unsealed) segments never enter these rows.
  defp corpus(dir) do
    {:ok, segs} = JournalReader.discover_sealed_segments(dir)

    Enum.flat_map(segs, fn seg ->
      {:ok, frames} = JournalReader.read_sealed_segment(seg)

      Enum.map(frames, fn f ->
        p = Jason.decode!(f.payload)

        %{
          "TimeGenerated" => p["TimeGenerated"],
          "severity" => p["severity"],
          "device" => p["device"]
        }
      end)
    end)
  end

  # -- C1: bin() time binning over sealed corpus -------------------------------

  test "C1 bin(TimeGenerated, 1h): summarize count() by bin -> correct per-hour rows", %{
    dir: dir
  } do
    # hour-aligned base (bin floors to the top of the containing hour)
    h0 = div(1_760_000_000_000, 3_600_000) * 3_600_000
    h1 = h0 + 3_600_000
    h2 = h0 + 7_200_000

    seal_events(dir, [
      %{ts_ms: h0, sev: 1, dev: "d1"},
      %{ts_ms: h0 + 60_000, sev: 2, dev: "d2"},
      %{ts_ms: h0 + 120_000, sev: 3, dev: "d1"},
      %{ts_ms: h1, sev: 4, dev: "d3"}
    ])

    # active (unsealed) segment: same codec, NO seal sentinel / manifest —
    # must be excluded from the corpus by discover_sealed_segments
    unsealed = Path.join([dir, "sealed", "seg-999.journal"])
    {frame, _s, _q} = JournalSink.encode_frame(1, h2, @event_type, @table_id, "kql-w3", "x")
    File.write!(unsealed, frame)

    rows = corpus(dir)

    assert {:ok,
            [
              %{"TimeGenerated" => t0, "count_" => 3},
              %{"TimeGenerated" => t1, "count_" => 1}
            ]} =
             KQL.run(rows, "| summarize count() by bin(TimeGenerated, 1h)")

    assert DateTime.to_unix(t0, :millisecond) == h0
    assert DateTime.to_unix(t1, :millisecond) == h1
    refute Map.has_key?(List.first(rows) || %{}, "seq_id")
    assert length(rows) == 4
  end

  # -- C2: countif + dcount (and sumif) over the sealed corpus -----------------

  test "C2 where severity > 2 | summarize countif(severity > 3), dcount(device)", %{dir: dir} do
    h0 = 1_760_000_000_000

    seal_events(dir, [
      %{ts_ms: h0, sev: 1, dev: "d1"},
      %{ts_ms: h0 + 1_000, sev: 3, dev: "d2"},
      %{ts_ms: h0 + 2_000, sev: 4, dev: "d1"},
      %{ts_ms: h0 + 3_000, sev: 5, dev: "d3"},
      %{ts_ms: h0 + 4_000, sev: 4, dev: "d3"}
    ])

    rows = corpus(dir)

    assert {:ok, [%{"countif_" => 3, "dcount_device" => 3}]} =
             KQL.run(
               rows,
               "| where severity > 2 | summarize countif(severity > 3), dcount(device)"
             )

    assert {:ok, [%{"sumif_" => 13}]} =
             KQL.run(rows, "| summarize sumif(severity, severity > 3)")
  end

  # -- C3: in / in~ membership --------------------------------------------------

  test "C3 in / in~ filters over sealed corpus", %{dir: dir} do
    h0 = 1_760_000_000_000

    seal_events(dir, [
      %{ts_ms: h0, sev: 1, dev: "alpha"},
      %{ts_ms: h0 + 1_000, sev: 2, dev: "beta"},
      %{ts_ms: h0 + 2_000, sev: 3, dev: "gamma"},
      %{ts_ms: h0 + 3_000, sev: 4, dev: "ALPHA"}
    ])

    rows = corpus(dir)

    assert {:ok, rows_in} =
             KQL.run(rows, "| where device in (\"alpha\", \"gamma\")")

    assert length(rows_in) == 2
    assert Enum.all?(rows_in, &(&1["device"] in ["alpha", "gamma"]))

    assert {:ok, rows_ci} =
             KQL.run(rows, "| where device in~ (\"ALPHA\", \"GAMMA\")")

    assert length(rows_ci) == 3
  end

  # -- C4: fail-closed ratchet (unknown operators still typed errors) ----------

  test "C4 unknown operator/function/aggregate still fail typed", %{dir: dir} do
    seal_events(dir, [%{ts_ms: 1_760_000_000_000, sev: 1, dev: "d1"}])
    rows = corpus(dir)

    assert {:error, {:parse, "SYN0004: unknown pipeline operator " <> _}} =
             KQL.run(rows, "| frobnicate")

    assert {:error, {:parse, "SYN0004: unknown function " <> _}} =
             KQL.run(rows, "| extend X = mvfy(device, 1h)")

    assert {:error, {:parse, "SYN0004: unknown aggregate function " <> _}} =
             KQL.run(rows, "| summarize weirdif(severity)")

    # bin in a predicate position is not a comparison operator — typed refusal
    assert {:error, {:parse, _}} = KQL.run(rows, "| where severity inx (1, 2)")
  end

  # -- C5: falsifier — corpus bound (wrong segment -> different counts) --------

  test "C5 falsifier: same query over the wrong segment returns different counts", %{dir: dir} do
    h0 = 1_760_000_000_000

    seal_events(dir, [
      %{ts_ms: h0, sev: 3, dev: "x1"},
      %{ts_ms: h0 + 1_000, sev: 3, dev: "x2"}
    ])

    # a second, disjoint sealed segment: 4 events, severities all > 2
    seal_events(dir, [
      %{ts_ms: h0 + 10_000, sev: 4, dev: "y1"},
      %{ts_ms: h0 + 11_000, sev: 5, dev: "y2"},
      %{ts_ms: h0 + 12_000, sev: 4, dev: "y3"},
      %{ts_ms: h0 + 13_000, sev: 5, dev: "y4"}
    ])

    {:ok, segs} = JournalReader.discover_sealed_segments(dir)
    assert length(segs) == 2
    [seg_a, seg_b] = segs

    seg_rows = fn seg ->
      {:ok, frames} = JournalReader.read_sealed_segment(seg)

      Enum.map(frames, fn f ->
        p = Jason.decode!(f.payload)

        %{
          "severity" => p["severity"],
          "device" => p["device"],
          "TimeGenerated" => p["TimeGenerated"]
        }
      end)
    end

    q = "| where severity > 2 | summarize countif(severity > 3), dcount(device)"

    assert {:ok, [%{"countif_" => 0, "dcount_device" => 2}]} = KQL.run(seg_rows.(seg_a), q)

    assert {:ok, [%{"countif_" => 4, "dcount_device" => 4}]} = KQL.run(seg_rows.(seg_b), q)

    # combined corpus differs from either segment alone
    assert {:ok, [%{"countif_" => 4, "dcount_device" => 6}]} = KQL.run(corpus(dir), q)
  end
end
