defmodule Smalt.Aoq.Epoch do
  @moduledoc """
  Closed `aoq:Epoch` key-epoch enum (landed ontology
  `ggen-marketplace/packs/aoq-pack/ontology.ttl`, u16 wire value at
  header offset 6) — the Elixir twin of cgap-aoq's `header::Epoch`.

  - `:genesis` = 0 — first epoch; `key_id 0` is valid only here
  - `:rotated_1` = 1 — first key rotation
  - `:rotated_2` = 2 — second key rotation
  - `:retired` = 65_535 — reserved read-only sentinel (u16 max):
    admits on decode, never lawful on a newly written frame
    (`to_wire/1` refuses it)
  """

  @typedoc "One of the four closed `aoq:Epoch` values."
  @type t :: :genesis | :rotated_1 | :rotated_2 | :retired

  @typedoc "Raw u16 wire value carried in the header."
  @type raw :: 0 | 1 | 2 | 65_535

  @wire_values %{
    genesis: 0,
    rotated_1: 1,
    rotated_2: 2,
    retired: 65_535
  }

  @enum_raws [0, 1, 2, 65_535]

  @doc "Wire u16 value for an epoch atom."
  @spec to_wire(t()) :: raw()
  def to_wire(epoch), do: Map.fetch!(@wire_values, epoch)

  @doc """
  Wire value for encode paths: refuses `:retired` — the retirement
  sentinel is read-only; a newly written frame must never carry it.
  """
  @spec to_wire_for_encode(t()) :: {:ok, raw()} | {:error, :retired_epoch_not_encodable}
  def to_wire_for_encode(:retired), do: {:error, :retired_epoch_not_encodable}
  def to_wire_for_encode(epoch), do: {:ok, to_wire(epoch)}

  @doc "Epoch atom for a raw wire value; `{:error, {:unknown_epoch, raw}}` otherwise."
  @spec from_wire(non_neg_integer()) :: {:ok, t()} | {:error, {:unknown_epoch, non_neg_integer()}}
  def from_wire(raw) when raw in @enum_raws, do: {:ok, atom_for(raw)}
  def from_wire(raw), do: {:error, {:unknown_epoch, raw}}

  @doc "Guard-friendly: `true` when `raw` is one of the closed enum wire values."
  @spec valid_raw?(non_neg_integer()) :: boolean()
  def valid_raw?(raw) when raw in @enum_raws, do: true
  def valid_raw?(_), do: false

  @doc "True when the raw value is the read-only `:retired` sentinel (u16 max)."
  @spec retired?(non_neg_integer()) :: boolean()
  def retired?(65_535), do: true
  def retired?(_), do: false

  # Guard-friendly helper clauses behind from_wire/1.
  defp atom_for(0), do: :genesis
  defp atom_for(1), do: :rotated_1
  defp atom_for(2), do: :rotated_2
  defp atom_for(65_535), do: :retired
end
