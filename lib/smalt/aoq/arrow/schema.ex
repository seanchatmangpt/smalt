defmodule Smalt.Aoq.Arrow.Schema do
  @moduledoc """
  AOQ Arrow schema data model (NIF-free v1).

  A schema is `%Smalt.Aoq.Arrow.Schema{}` with a unique `schema_id`
  and a list of `%Smalt.Aoq.Arrow.Schema.Field{}`s. Field types are a
  closed grammar (`t:arrow_type/0`) — validation lives in
  `Smalt.Aoq.Arrow.Court` (grammar → semantic → digest → registry).

  ## Arrow-type mapping table (v2 NIF seam doc)

  When the Rust Arrow NIF lands (v2), each `arrow_type` maps 1:1 to a
  `arrow::datatypes::DataType`. This table IS the seam contract — the
  NIF accepts exactly these terms and nothing else:

  | Elixir term                          | Arrow `DataType`                            |
  |--------------------------------------|---------------------------------------------|
  | `:bool`                              | `Boolean`                                   |
  | `:i8`/`:i16`/`:i32`/`:i64`           | `Int8`/`Int16`/`Int32`/`Int64`              |
  | `:u8`/`:u16`/`:u32`/`:u64`           | `UInt8`/`UInt16`/`UInt32`/`UInt64`          |
  | `:f16`/`:f32`/`:f64`                 | `Float16`/`Float32`/`Float64`               |
  | `:utf8`/`:large_utf8`                | `Utf8`/`LargeUtf8`                          |
  | `:binary`/`:large_binary`            | `Binary`/`LargeBinary`                      |
  | `:date32`/`:date64`                  | `Date32`/`Date64`                           |
  | `{:time, u}`                         | `Time32(u)` or `Time64(u)` (unit-sized)     |
  | `{:timestamp, u, tz}`                | `Timestamp(u, tz)` (tz nil = no timezone)   |
  | `{:decimal128, p, s}`                | `Decimal128(p, s)` (1 ≤ p ≤ 38, s ≤ p)      |
  | `{:interval, k}`                     | `Interval(k)` (year_month/day_time/month_day_nano) |
  | `{:list, t, nullable}`               | `List(Field("", t, nullable))`              |
  | `{:fixed_size_list, t, n}`           | `FixedSizeList(Field("", t, true), n)`      |
  | `{:struct, fields}`                  | `Struct(fields)`                            |
  | `{:map, k, v, sorted}`               | `Map(Field("entries", Struct[{k,v}]), sorted)` |
  | `{:dictionary, idx, value}`          | `Dictionary(idx, value)` (idx = integer type) |
  """

  alias __MODULE__.Field

  @enforce_keys [:schema_id, :fields]
  defstruct [:schema_id, :fields]

  @typedoc """
  Schema id. Must be unique within a registry (court tier 4).
  """
  @type schema_id :: atom() | binary()

  @typedoc """
  Closed Arrow type grammar. No catch-all `term()` — every lawful
  shape is enumerated; anything else is a typed grammar refusal.
  Depth cap 32 (see `Smalt.Aoq.Arrow.Court`), no nested dictionary.
  """
  @type arrow_type ::
          :bool
          | :i8 | :i16 | :i32 | :i64
          | :u8 | :u16 | :u32 | :u64
          | :f16 | :f32 | :f64
          | :utf8 | :large_utf8 | :binary | :large_binary
          | :date32 | :date64
          | {:time, time_unit()}
          | {:timestamp, time_unit(), tz()}
          | {:decimal128, precision(), scale()}
          | {:interval, interval_kind()}
          | {:list, arrow_type(), boolean()}
          | {:fixed_size_list, arrow_type(), pos_integer()}
          | {:struct, [Field.t()]}
          | {:map, arrow_type(), arrow_type(), boolean()}
          | {:dictionary, index_type(), arrow_type()}

  @type time_unit :: :second | :millisecond | :microsecond | :nanosecond
  @type tz :: nil | String.t()
  @type precision :: 1..38
  @type scale :: integer()
  @type interval_kind :: :year_month | :day_time | :month_day_nano
  @typedoc "Dictionary index types: the integer-width family."
  @type index_type :: :i8 | :i16 | :i32 | :i64 | :u8 | :u16 | :u32 | :u64

  @depth_cap 32
  def depth_cap, do: @depth_cap

  @typedoc "A named, typed column."
  @type field :: %Field{}

  @type t :: %__MODULE__{schema_id: schema_id(), fields: [field()]}

  defmodule Field do
    @moduledoc """
    One Arrow column: `name` (binary), `type` (`t:arrow_type/0`),
    `nullable` flag, and free-form `metadata` (map, default `%{}`).
    """

    @enforce_keys [:name, :type, :nullable]
    defstruct [:name, :type, :nullable, metadata: %{}]

    @type t :: %__MODULE__{
            name: String.t(),
            type: Smalt.Aoq.Arrow.Schema.arrow_type(),
            nullable: boolean(),
            metadata: map()
          }
  end

  @doc """
  Convenience constructor: builds a `%Field{}` (metadata defaults to
  an empty map).
  """
  @spec field(String.t(), arrow_type(), boolean(), map()) :: Field.t()
  def field(name, type, nullable, metadata \\ %{}) do
    %Field{name: name, type: type, nullable: nullable, metadata: metadata}
  end

  @doc """
  Convenience constructor: builds a `%Schema{}`.
  """
  @spec new(schema_id(), [field()]) :: t()
  def new(schema_id, fields), do: %__MODULE__{schema_id: schema_id, fields: fields}
end
