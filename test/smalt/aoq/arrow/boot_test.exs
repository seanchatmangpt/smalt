defmodule Smalt.Aoq.Arrow.BootTest do
  # Tables are global :persistent_term — structural sync, never async.
  use ExUnit.Case, async: false

  alias Smalt.Aoq.Arrow.Boot
  alias Smalt.Aoq.Arrow.Court
  alias Smalt.Aoq.Arrow.Schema
  alias Smalt.Aoq.Tables

  @format_version 1

  setup do
    # Every leg re-boots from a clean slate; the teardown restores the
    # compile-time registry so no state leaks across suites.
    Tables.boot()

    on_exit(fn -> Tables.boot() end)
    :ok
  end

  defp write_bundle!(terms) do
    path =
      Path.join(System.tmp_dir!(), "aoq-arrow-boot-test-#{System.unique_integer([:positive])}.terms")

    body =
      terms
      |> Enum.map_join("\n", fn term ->
        :io_lib.format("~tp.~n", [term]) |> IO.iodata_to_binary()
      end)

    File.write!(path, body)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp bundle_schema(id) do
    fields = [
      Schema.field("sym", :utf8, false),
      Schema.field("px", {:decimal128, 18, 4}, false, %{"ccy" => "usd"})
    ]

    Schema.new(id, fields)
  end

  # ── Leg 1: real bundle file → registry holds the bundle's schemas ──

  test "leg 1: a real bundle file boots into the Tables hot path" do
    id = :l52_prices
    schema = bundle_schema(id)
    digest = Court.digest(schema)

    path =
      write_bundle!([
        {:aoq_arrow_bundle, @format_version},
        {:schema, id, [{"sym", :utf8, false, %{}}, {"px", {:decimal128, 18, 4}, false, %{"ccy" => "usd"}}]},
        {:digest, id, digest}
      ])

    registry = Boot.registry(path)

    assert %{^id => %{schema: ^schema, digest: ^digest}} = registry

    # The real boot write path: Tables.boot/1 with the Boot-returned
    # registry — exactly what the supervisor init executes.
    :ok = Tables.boot(arrow_schemas: registry)
    assert Tables.arrow_schemas() == registry
    assert Tables.sealed?()
  end

  # ── Leg 2: corrupt bundle → typed refusal, loud log, fallback, plane still boots ──

  @tag :capture_log
  test "leg 2: corrupt bundle refuses typed, logs loudly, boots with the fallback" do
    corrupt = Path.join(System.tmp_dir!(), "aoq-arrow-boot-corrupt-#{System.unique_integer([:positive])}")
    File.write!(corrupt, <<0xDE, 0xAD, 0xBE, 0xEF, "not an erlang terms file at all">>)
    on_exit(fn -> File.rm(corrupt) end)

    fallback = Tables.fallback_arrow_schemas()

    {registry, logged} = ExUnit.CaptureLog.with_log(fn -> Boot.registry(corrupt) end)

    # Typed refusal upstream (the reason carried into the log)…
    assert {:error, {:bundle_consult, ^corrupt, _reason}} = Smalt.Aoq.Arrow.Loader.load(corrupt)
    # …fallback registry handed back…
    assert registry == fallback
    # …and the refusal is LOUD, not silent.
    assert logged =~ "REFUSED at boot"

    # The plane still boots: the fallback write path is lawful and the
    # hot read returns the fallback registry.
    :ok = Tables.boot(arrow_schemas: Boot.registry(corrupt))
    assert Tables.arrow_schemas() == fallback
    assert Tables.sealed?()
  end

  # ── Leg 3: no bundle → compile-time fallback unchanged ──

  test "leg 3: missing bundle falls back; a bare boot is byte-identical with the compile-time registry" do
    missing = Path.join(System.tmp_dir!(), "aoq-arrow-boot-missing-#{System.unique_integer([:positive])}")

    assert Boot.registry(missing) == Tables.fallback_arrow_schemas()

    # Bare Tables.boot/1 (the pre-bundle shape) still writes the
    # compile-time registry — unchanged default.
    :ok = Tables.boot()
    assert Tables.arrow_schemas() == Tables.fallback_arrow_schemas()
    assert Tables.arrow_schemas() == %{}
  end

  test "default path is the shipped priv bundle and loads empty" do
    path = Smalt.Aoq.Arrow.Bundle.default_path()
    assert File.exists?(path)
    assert Boot.registry() == %{}
  end
end
