defmodule Smalt.Aoq.Arrow.CourtTest do
  use ExUnit.Case, async: true

  alias Smalt.Aoq.Arrow.Court
  alias Smalt.Aoq.Arrow.Schema

  # -- tier 1: grammar (exhaustive clause match, typed refusals) --------------

  test "lawful leaf types pass the grammar" do
    atoms = [
      :bool, :i8, :i16, :i32, :i64, :u8, :u16, :u32, :u64,
      :f16, :f32, :f64, :utf8, :large_utf8, :binary, :large_binary,
      :date32, :date64
    ]

    for t <- atoms do
      assert Court.grammar_check(t) == :ok
    end

    assert Court.grammar_check({:time, :millisecond}) == :ok
    assert Court.grammar_check({:timestamp, :microsecond, nil}) == :ok
    assert Court.grammar_check({:timestamp, :second, "UTC"}) == :ok
    assert Court.grammar_check({:decimal128, 38, 18}) == :ok
    assert Court.grammar_check({:interval, :month_day_nano}) == :ok
    assert Court.grammar_check({:list, :i32, true}) == :ok
    assert Court.grammar_check({:fixed_size_list, :f32, 3}) == :ok

    assert Court.grammar_check(
             {:struct, [Schema.field("a", :utf8, false), Schema.field("b", :i64, true)]}
           ) == :ok

    assert Court.grammar_check({:map, :utf8, :i32, false}) == :ok
    assert Court.grammar_check({:dictionary, :i32, :utf8}) == :ok
  end

  test "unknown type shapes are typed grammar refusals" do
    bad = [
      :int32,
      :float,
      {:time, :fortnight},
      {:decimal128, 38},
      {:list, :i32},
      {:map, :utf8, :i32, false, :extra},
      {:interval, :fortnight},
      {:time32, :second},
      "utf8",
      42
    ]

    for t <- bad do
      assert {:error, {:grammar, _reason}} = Court.validate(Schema.new(:s, [Schema.field("x", t, true)]))
    end
  end

  test "bad dictionary index type is a grammar refusal" do
    schema = Schema.new(:s, [Schema.field("d", {:dictionary, :utf8, :i32}, true)])
    assert {:error, {:grammar, {:bad_index_type, :utf8}}} = Court.validate(schema)
  end

  test "depth cap 32: lawful at 31 nested lists, refusal at 33" do
    deep = fn n ->
      Enum.reduce(1..n // 1, :i32, fn _, t -> {:list, t, true} end)
    end

    schema_at_cap = Schema.new(:s, [Schema.field("x", deep.(Schema.depth_cap() - 1), true)])
    assert Court.validate(schema_at_cap) == :ok

    schema_over_cap = Schema.new(:s, [Schema.field("x", deep.(Schema.depth_cap() + 1), true)])
    assert {:error, {:grammar, {:depth_exceeded, _}}} = Court.validate(schema_over_cap)
  end

  # -- tier 2: semantic --------------------------------------------------------

  test "decimal scale must not exceed precision; precision in 1..38" do
    ok = Schema.new(:s, [Schema.field("d", {:decimal128, 38, 38}, true)])
    assert Court.validate(ok) == :ok

    bad_scale = Schema.new(:s, [Schema.field("d", {:decimal128, 10, 11}, true)])
    assert {:error, {:semantic, {:scale_exceeds_precision, 10, 11}}} = Court.validate(bad_scale)

    bad_precision = Schema.new(:s, [Schema.field("d", {:decimal128, 39, 2}, true)])
    assert {:error, {:semantic, {:precision_out_of_range, 39}}} = Court.validate(bad_precision)
  end

  test "timezone must be nil or nonempty" do
    bad = Schema.new(:s, [Schema.field("t", {:timestamp, :second, ""}, true)])
    assert {:error, {:semantic, {:empty_timezone, ""}}} = Court.validate(bad)
  end

  test "fixed_size_list n must be >= 1" do
    bad = Schema.new(:s, [Schema.field("f", {:fixed_size_list, :i32, 0}, true)])
    assert {:error, {:semantic, {:fixed_size_list_n, 0}}} = Court.validate(bad)
  end

  test "map keys must not be nested containers" do
    bad = Schema.new(:s, [Schema.field("m", {:map, {:list, :i32, true}, :utf8, false}, true)])
    assert {:error, {:semantic, {:nested_map_key, {:list, :i32, true}}}} = Court.validate(bad)
  end

  test "nested dictionary is refused" do
    bad = Schema.new(:s, [Schema.field("d", {:dictionary, :i32, {:dictionary, :i32, :utf8}}, true)])
    assert {:error, {:semantic, {:nested_dictionary, {:dictionary, :i32, :utf8}}}} = Court.validate(bad)
  end

  test "semantic checks recurse into containers" do
    bad =
      Schema.new(:s, [
        Schema.field("l", {:list, {:decimal128, 10, 12}, true}, true)
      ])

    assert {:error, {:semantic, {:scale_exceeds_precision, 10, 12}}} = Court.validate(bad)
  end

  # -- tier 3: digest ----------------------------------------------------------

  test "digest is 32 bytes and deterministic" do
    s = Schema.new(:s1, [Schema.field("x", {:timestamp, :millisecond, "UTC"}, false)])
    d1 = Court.digest(s)
    d2 = Court.digest(s)
    assert byte_size(d1) == 32
    assert d1 == d2
  end

  test "hand-mutated schema re-derives a DIFFERENT digest (falsifier)" do
    s = Schema.new(:s1, [Schema.field("x", :i32, false)])
    good_digest = Court.digest(s)

    # mutate the pinned schema by hand: nullable flips + field renamed
    mutated = %{s | fields: [Schema.field("y", :i32, true)]}
    assert Court.digest(mutated) != good_digest

    # each individual mutation flips the digest too
    assert Court.digest(Schema.new(:s1, [Schema.field("y", :i32, false)])) != good_digest
    assert Court.digest(Schema.new(:s1, [Schema.field("x", :i64, false)])) != good_digest
    assert Court.digest(Schema.new(:s2, [Schema.field("x", :i32, false)])) != good_digest
  end

  # -- tier 4: registry --------------------------------------------------------

  test "unique-id law: duplicate schema ids refused at registry tier" do
    s = fn id -> Schema.new(id, [Schema.field("x", :i32, false)]) end

    assert Court.validate_registry([s.(:a), s.(:b)]) == :ok
    assert {:error, {:registry, {:duplicate_schema_id, :a}}} =
             Court.validate_registry([s.(:a), s.(:a)])
  end

  test "registry ladder still checks grammar/semantic of every member" do
    bad = Schema.new(:a, [Schema.field("x", {:decimal128, 5, 9}, true)])
    assert {:error, {:semantic, {:scale_exceeds_precision, 5, 9}}} =
             Court.validate_registry([Schema.new(:b, [Schema.field("y", :utf8, true)]), bad])
  end
end
