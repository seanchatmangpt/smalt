defmodule Smalt.Aoq.TablesTest do
  use ExUnit.Case, async: false

  alias Smalt.Aoq.Tables

  # persistent_term is node-global: boot is synchronous (structural
  # sync, no sleeps) and each test re-derives its own table contents.
  setup do
    on_exit(fn -> Tables.boot() end)
    :ok
  end

  test "boot writes all three tables and the seal" do
    Tables.boot(
      frame_types: %{0x01 => {Foo, :bar}},
      epochs: %{1 => {:key_ref, 0}},
      arrow_schemas: %{s1: :schema_term}
    )

    assert Tables.frame_types() == %{0x01 => {Foo, :bar}}
    assert Tables.epochs() == %{1 => {:key_ref, 0}}
    assert Tables.arrow_schemas() == %{s1: :schema_term}
    assert Tables.sealed?()
  end

  test "boot defaults come from the static compile-time registry" do
    Tables.boot()

    ft = Tables.frame_types()
    assert Map.has_key?(ft, 0x01)
    assert {m, f} = ft[0x01]
    assert is_atom(m) and is_atom(f)
    assert Tables.epochs() == %{}
    assert Tables.arrow_schemas() == %{}
  end

  test "frame_handler resolves a registered frame type" do
    Tables.boot(frame_types: %{0x42 => {Foo, :baz}})
    assert Tables.frame_handler(0x42) == {Foo, :baz}

    assert_raise KeyError, fn -> Tables.frame_handler(0xFF) end
  end

  test "post-boot mutation attempts raise (refuse-on-mutate guard)" do
    Tables.boot(frame_types: %{0x01 => {Foo, :bar}})

    assert_raise ArgumentError, ~r/sealed at boot/i, fn ->
      Tables.register_frame_type(0x02, {Foo, :qux})
    end

    assert_raise ArgumentError, ~r/sealed at boot/i, fn ->
      Tables.append_epoch(9, {:key_ref, 100})
    end

    assert_raise ArgumentError, ~r/sealed at boot/i, fn ->
      Tables.put_arrow_schema(:s9, :schema)
    end

    # the refused writes left the tables untouched
    assert Tables.frame_types() == %{0x01 => {Foo, :bar}}
    assert Tables.epochs() == %{}
    assert Tables.arrow_schemas() == %{}
  end

  test "mutation before boot refuses (partial-table prevention)" do
    for k <- [:frame_types, :epochs, :arrow_schemas, :sealed] do
      :persistent_term.erase({:aoq, k})
    end

    assert_raise ArgumentError, ~r/not booted/i, fn ->
      Tables.register_frame_type(0x02, {Foo, :qux})
    end

    refute Tables.sealed?()
  end

  test "re-boot legally re-derives the whole map per key" do
    Tables.boot(frame_types: %{0x01 => {Foo, :old}})
    Tables.boot(frame_types: %{0x01 => {Foo, :new}})

    assert Tables.frame_types() == %{0x01 => {Foo, :new}}
  end

  test "reads before boot raise a typed ArgumentError" do
    # persistent_term is node-global: explicitly unboot by erasing the
    # keys so this test is order-independent.
    for k <- [:frame_types, :epochs, :arrow_schemas, :sealed] do
      :persistent_term.erase({:aoq, k})
    end

    assert_raise ArgumentError, fn ->
      Tables.frame_types()
    end
  end
end
