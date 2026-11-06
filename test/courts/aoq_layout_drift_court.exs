defmodule AoqLayoutDriftCourt do
  @moduledoc """
  R1-I S1 drift court: the graph is the spec.

  Parses the landed ontology TTL
  (`ggen-marketplace/packs/aoq-pack/ontology.ttl`) and asserts
  field-by-field equality with the generated twin
  `Smalt.Aoq.GeneratedAoqHeaderLayout.header_fields/0` — the same law
  cgap-aoq's `tests/aoq1_layout_drift_court.rs` enforces on the Rust
  side. Anti-vacuity legs mutate a COPY of the TTL (offset drift,
  wireKind drift, version drift) and demand a RED: a court that cannot
  flip is FAIL.
  """

  use ExUnit.Case, async: true

  alias Smalt.Aoq.GeneratedAoqHeaderLayout

  @ontology_path "/Users/sac/ggen-marketplace/packs/aoq-pack/ontology.ttl"

  # ── graph-vs-twin equality ──────────────────────────────────────────

  test "landed ontology field table == generated twin, field by field" do
    ttl = File.read!(@ontology_path)
    graph_fields = parse_header_fields!(ttl)

    twin_fields =
      GeneratedAoqHeaderLayout.header_fields()
      |> Enum.map(&%{rust_name: &1.rust_name, offset: &1.offset, size_bytes: &1.size_bytes, wire_kind: to_string(&1.wire_kind) |> String.replace("_", "-")})

    assert graph_fields == twin_fields,
           "ontology vs generated twin drift: graph=#{inspect(graph_fields)} twin=#{inspect(twin_fields)}"

    assert GeneratedAoqHeaderLayout.contiguity_verified?()
    assert GeneratedAoqHeaderLayout.size_bytes() == 64
    assert GeneratedAoqHeaderLayout.magic() == 0x414F_5131
    assert GeneratedAoqHeaderLayout.version() == 3
    assert GeneratedAoqHeaderLayout.digest_span() == {0, 60}
  end

  # ── anti-vacuity: mutated TTL copies must RED ───────────────────────

  test "anti-vacuity: offset mutation in the graph flips the court" do
    ttl = mutate_ttl("aoq:offset 60 ; aoq:sizeBytes 4 ; aoq:wireKind \"fnv1a32\"", "aoq:offset 59 ; aoq:sizeBytes 4 ; aoq:wireKind \"fnv1a32\"")

    assert {graph, twin} = diff_pair(ttl)
    assert graph != twin, "mutated digest offset (60→59) MUST flip the court, never silent-pass"
  end

  test "anti-vacuity: wireKind mutation in the graph flips the court" do
    ttl = mutate_ttl("aoq:wireKind \"reserved-zero\"", "aoq:wireKind \"u32\"")

    assert {graph, twin} = diff_pair(ttl)
    assert graph != twin, "mutated wireKind (reserved-zero→u32) MUST flip the court"
  end

  test "anti-vacuity: sizeBytes mutation in the graph flips the court" do
    ttl = mutate_ttl("aoq:offset 8 ; aoq:sizeBytes 8", "aoq:offset 8 ; aoq:sizeBytes 16")

    assert {graph, twin} = diff_pair(ttl)
    assert graph != twin, "mutated key_id sizeBytes (8→16) MUST flip the court"
  end

  test "anti-vacuity: version value mutation in the graph flips the court" do
    ttl = mutate_ttl(~S{aoq:value 3 ;}, ~S{aoq:value 2 ;})

    assert parsed_version(ttl) == {:ok, 2},
           "mutated version (3→2) MUST flip the court"
    assert parsed_version(@ontology_path |> File.read!()) == {:ok, 3}
  end

  # ── helpers ─────────────────────────────────────────────────────────

  defp diff_pair(ttl) do
    graph =
      parse_header_fields!(ttl)
      |> Enum.map(&{&1.rust_name, &1.offset, &1.size_bytes, &1.wire_kind})

    twin =
      GeneratedAoqHeaderLayout.header_fields()
      |> Enum.map(&{&1.rust_name, &1.offset, &1.size_bytes, to_string(&1.wire_kind)})

    {graph, twin}
  end

  defp mutate_ttl(old, new) do
    ttl = File.read!(@ontology_path)
    unless String.contains?(ttl, old), do: raise("anti-vacuity needle not found in TTL: #{old}")
    String.replace(ttl, old, new)
  end

  defp parsed_version(ttl) do
    case Regex.run(~r/aoq:hf-version a aoq:HeaderField ;.*?aoq:value\s+(\d+)\s*;/s, ttl) do
      [_, v] -> {:ok, String.to_integer(v)}
      nil -> :error
    end
  end

  @field_block ~r/aoq:hf-([a-z0-9-]+) a aoq:HeaderField ;(.*?)\.\n/s

  defp parse_header_fields!(ttl) do
    @field_block
    |> Regex.scan(ttl)
    |> Enum.map(fn [_, label, body] ->
      name = field_name(label)

      offset = int_of!(body, ~r/aoq:offset\s+(\d+)/)
      size = int_of!(body, ~r/aoq:sizeBytes\s+(\d+)/)
      kind = string_of!(body, ~r/aoq:wireKind\s+"([a-z0-9-]+)"/)

      %{rust_name: name, offset: offset, size_bytes: size, wire_kind: kind}
    end)
    |> Enum.sort_by(& &1.offset)
  end

  defp field_name(label) do
    case label do
      "magic" -> "MAGIC"
      "version" -> "VERSION"
      "epoch" -> "EPOCH"
      "key-id" -> "KEY_ID"
      "frame-ordinal" -> "FRAME_ORDINAL"
      "seq" -> "SEQ"
      "reserved" -> "RESERVED"
      "header-digest" -> "HEADER_DIGEST"
      other -> raise "unknown header field label in TTL: #{other}"
    end
  end

  defp int_of!(body, re) do
    case Regex.run(re, body) do
      [_, v] -> String.to_integer(v)
      nil -> raise "missing numeric fact (#{inspect(re.source)}) in header-field block"
    end
  end

  defp string_of!(body, re) do
    case Regex.run(re, body) do
      [_, v] -> v
      nil -> raise "missing string fact (#{inspect(re.source)}) in header-field block"
    end
  end
end
