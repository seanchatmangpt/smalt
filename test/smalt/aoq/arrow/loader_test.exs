defmodule Smalt.Aoq.Arrow.LoaderTest do
  use ExUnit.Case, async: true

  alias Smalt.Aoq.Arrow.Court
  alias Smalt.Aoq.Arrow.Loader
  alias Smalt.Aoq.Arrow.Schema

  @format_version 1

  defp write_bundle!(terms) do
    path = Path.join(System.tmp_dir!(), "aoq-arrow-loader-test-#{System.unique_integer([:positive])}.terms")

    body =
      Enum.map_join(terms, "\n", fn term ->
        :io_lib.format("~tp.~n", [term]) |> IO.iodata_to_binary()
      end)

    File.write!(path, body)
    on_exit(fn -> File.rm(path) end)
    path
  end

  test "empty bundle is lawful: %{}, byte-identical with the empty registry" do
    path = write_bundle!([{aoq_arrow_bundle, @format_version}])
    assert {:ok, %{}} = Loader.load(path)
  end

  test "roundtrip: bundle schemas pass the court and digest-verify" do
    id = :prices
    fields = [{"sym", :utf8, false, %{}}, {"px", {:decimal128, 18, 4}, false, %{"ccy" => "usd"}}]
    fs = Enum.map(fields, fn {n, t, nullable, meta} -> Schema.field(n, t, nullable, meta) end)
    schema = Schema.new(id, fs)
    digest = Court.digest(schema)

    path =
      write_bundle!([
        {aoq_arrow_bundle, @format_version},
        {schema, id, fields},
        {digest, id, digest}
      ])

    assert {:ok, %{^id => %{schema: ^schema, digest: ^digest}}} = Loader.load(path)
  end

  test "digest-mismatch falsifier: a hand-mutated schema next to the original digest refuses load" do
    id = :s1
    fields = [{"x", :i32, false, %{}}]
    fs = Enum.map(fields, fn {n, t, nullable, meta} -> Schema.field(n, t, nullable, meta) end)
    honest_digest = Court.digest(Schema.new(id, fs))

    # the bundle carries the honest digest but a MUTATED schema (nullable flipped)
    mutated_fields = [{"x", :i32, true, %{}}]

    path =
      write_bundle!([
        {aoq_arrow_bundle, @format_version},
        {schema, id, mutated_fields},
        {digest, id, honest_digest}
      ])

    assert {:error, {:digest_mismatch, ^id, bundled: ^honest_digest, computed: computed}} =
             Loader.load(path)

    assert computed != honest_digest
  end

  test "court refusal at load: schema in bundle fails semantic tier" do
    id = :bad_decimal
    fields = [{"d", {:decimal128, 5, 9}, true, %{}}]
    digest = <<0::256>>

    path =
      write_bundle!([
        {aoq_arrow_bundle, @format_version},
        {schema, id, fields},
        {digest, id, digest}
      ])

    assert {:error, {:semantic, {:scale_exceeds_precision, 5, 9}}} = Loader.load(path)
  end

  test "registry tier at load: two bundles schemas sharing an id are refused" do
    fields = [{"x", :utf8, true, %{}}]

    path =
      write_bundle!([
        {aoq_arrow_bundle, @format_version},
        {schema, :a, fields},
        {schema, :a, fields},
        {digest, :a, <<0::256>>}
      ])

    assert {:error, {:bundle_duplicate_schema, :a}} = Loader.load(path)
  end

  test "missing bundle fails closed" do
    assert {:error, {:bundle_consult, _path, :enoent}} = Loader.load("/nonexistent/bundle")
  end

  test "default load reads the shipped empty priv bundle" do
    assert {:ok, %{}} = Loader.load()
  end
end
