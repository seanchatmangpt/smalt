defmodule Smalt.Aoq.Arrow.BundleTest do
  use ExUnit.Case, async: true

  alias Smalt.Aoq.Arrow.Bundle
  alias Smalt.Aoq.Arrow.Court
  alias Smalt.Aoq.Arrow.Schema

  @format_version 1

  # -- default bundle ----------------------------------------------------------

  test "the shipped priv/aoq/arrow_schemas.bundle is an empty lawful bundle" do
    assert {:ok, %{}} = Bundle.decode(Bundle.default_path())
  end

  # -- encoding helpers --------------------------------------------------------

  defp write_bundle!(terms) do
    path = Path.join(System.tmp_dir!(), "aoq-arrow-bundle-test-#{System.unique_integer([:positive])}.terms")

    body =
      Enum.map_join(terms, "\n", fn term ->
        :io_lib.format("~tp.~n", [term]) |> IO.iodata_to_binary()
      end)

    File.write!(path, body)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp schema_term(id) do
    {id, [{"x", {:timestamp, :millisecond, "UTC"}, false, %{"origin" => "test"}}]}
  end

  defp expected_digest(id, fields) do
    fs = Enum.map(fields, fn {n, t, nullable, meta} -> Schema.field(n, t, nullable, meta) end)
    Court.digest(Schema.new(id, fs))
  end

  # -- fail-closed -------------------------------------------------------------

  test "missing file is a typed consult refusal" do
    assert {:error, {:bundle_consult, _path, :enoent}} =
             Bundle.decode("/nonexistent/aoq/arrow_schemas.bundle")
  end

  test "corrupt bytes are a typed consult refusal" do
    path = write_bundle!([])
    File.write!(path, "{aoq_arrow_bundle, 1}. {broken")
    assert {:error, {:bundle_consult, _path, _reason}} = Bundle.decode(path)
  end

  test "wrong or missing magic is refused" do
    path = write_bundle!([{aoq_arrow_bundle, 999}])
    assert {:error, {:bundle_magic, _}} = Bundle.decode(path)

    path2 = write_bundle!([{schema, :s1, []}])
    assert {:error, {:bundle_magic, _}} = Bundle.decode(path2)
  end

  test "unknown record tag is refused" do
    path = write_bundle!([{aoq_arrow_bundle, @format_version}, {widget, :s1}])
    assert {:error, {:bundle_record, {widget, :s1}}} = Bundle.decode(path)
  end

  test "schema record without a digest record is refused" do
    path = write_bundle!([{aoq_arrow_bundle, @format_version}, schema_term(:s1)])
    assert {:error, {:bundle_digest_missing, :s1}} = Bundle.decode(path)
  end

  test "non-32-byte digest record is refused" do
    path =
      write_bundle!([
        {aoq_arrow_bundle, @format_version},
        schema_term(:s1),
        {digest, :s1, <<1, 2, 3>>}
      ])

    assert {:error, {:bundle_bad_digest, :s1, <<1, 2, 3>>}} = Bundle.decode(path)
  end

  test "duplicate schema id inside one bundle is refused" do
    path =
      write_bundle!([
        {aoq_arrow_bundle, @format_version},
        schema_term(:s1),
        schema_term(:s1),
        {digest, :s1, <<0::256>>}
      ])

    assert {:error, {:bundle_duplicate_schema, :s1}} = Bundle.decode(path)
  end

  # -- roundtrip ---------------------------------------------------------------

  test "roundtrip: schema + digest records decode to entry map" do
    {id, fields} = schema_term(:s1)
    digest = expected_digest(id, fields)

    path =
      write_bundle!([
        {aoq_arrow_bundle, @format_version},
        schema_term(:s1),
        {digest, :s1, digest}
      ])

    assert {:ok, %{^id => %{schema: %Schema{} = schema, digest: ^digest}}} = Bundle.decode(path)
    assert [%Schema.Field{name: "x", type: {:timestamp, :millisecond, "UTC"}, nullable: false}] =
             schema.fields

    assert schema.fields |> hd() |> then(& &1.metadata) == %{"origin" => "test"}

    # record order within the file does not matter
    path2 =
      write_bundle!([
        {aoq_arrow_bundle, @format_version},
        {digest, :s1, digest},
        schema_term(:s1)
      ])

    assert {:ok, %{^id => _}} = Bundle.decode(path2)
  end
end
