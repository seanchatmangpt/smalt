defmodule Smalt.Messaging.Kafka.Wire do
  @moduledoc """
  AZ-1 — Kafka binary protocol wire codec (AZ-1 minimal real face).

  Terminates the Kafka wire protocol directly (no PaaS wrapper). Protocol
  reference: Kafka protocol guide —
  https://kafka.apache.org/protocol#The_Messaging_Protocol (request header:
  int32 size | int16 api_key | int16 api_version | int32 correlation_id |
  client_id nullable string; response header: int32 size | int32
  correlation_id | body). All integers big-endian.

  Version matrix (AZ-1 scope, honest): we ADVERTISE only the versions this
  face serves. Flexible versions (KIP-482 compact types + tag sections)
  begin at ApiVersions v3 / Metadata v9 / Produce v9 / Fetch v12 — we cap
  every API strictly below its flexible threshold, so the whole served
  surface is classic fixed-width framing (no compact strings, no tags).

  Served matrix:

  | api | key | versions served | flexible from |
  |---|---|---|---|
  | Produce | 0 | 0..2 | v9 |
  | Fetch | 1 | 0..0 | v12 |
  | ListOffsets | 2 | 0..1 | v7 |
  | Metadata | 3 | 0..1 | v9 |
  | ApiVersions | 18 | 0..0 | v3 |

  Everything outside the matrix — transactions, compaction, ACLs, groups,
  compact/flexible encodings, unknown api_keys — gets the crash-only face:
  typed log + connection killed, socket closed. Named falsifier: a raw-TCP
  probe sending Produce (api 0) v9 (first flexible version) must be
  disconnected, never answered with a parse guess.
  """

  import Bitwise

  @typedoc "Kafka error codes this face emits (protocol guide §2, Error Codes)."
  @type error :: :none | :corrupt_message | :unknown_topic_or_partition | :policy_violation

  @doc "api_key numbers per the protocol guide."
  @spec api_keys() :: %{
          required(:produce) => 0,
          required(:fetch) => 1,
          required(:list_offsets) => 2,
          required(:metadata) => 3
        }
  def api_keys do
    %{
      produce: 0,
      fetch: 1,
      list_offsets: 2,
      metadata: 3,
      api_versions: 18
    }
  end

  @doc "Advertised {min, max} per api_key — exactly the served surface, nothing more."
  @spec version_matrix() :: %{non_neg_integer() => {non_neg_integer(), non_neg_integer()}}
  def version_matrix do
    %{
      0 => {0, 2},
      1 => {0, 2},
      2 => {0, 1},
      3 => {0, 1},
      18 => {0, 0}
    }
  end

  @doc "Kafka error codes used by this face."
  @spec error_code(atom()) :: non_neg_integer()
  def error_code(:none), do: 0
  def error_code(:corrupt_message), do: 2
  def error_code(:unknown_topic_or_partition), do: 3
  def error_code(:policy_violation), do: 44

  @doc """
  CRC32C (Castagnoli, poly 0x1EDC6F41 reflected = 0x82F63B78) — the Kafka
  RecordBatch magic-2 CRC, computed over the batch bytes from the
  `attributes` field to the end of the batch. Table-driven, no NIF.
  """
  @spec crc32c(binary()) :: non_neg_integer()
  def crc32c(data) when is_binary(data) do
    bxor(crc32c_loop(data, crc32c_table(), 0xFFFF_FFFF), 0xFFFF_FFFF)
  end

  defp crc32c_loop(<<>>, _table, crc), do: crc

  defp crc32c_loop(<<b, rest::binary>>, table, crc) do
    crc32c_loop(rest, table, bxor(band(crc >>> 8, 0x00FF_FFFF), elem(table, band(bxor(crc, b), 0xFF))))
  end

  defp crc32c_table do
    :persistent_term.get({__MODULE__, :crc32c_table}, nil) || build_crc32c_table()
  end

  defp build_crc32c_table do
    poly = 0x82F6_3B78

    table =
      for i <- 0..255 do
        Enum.reduce(1..8, i, fn _, acc ->
          if band(acc, 1) == 1, do: bxor(acc >>> 1, poly), else: acc >>> 1
        end)
      end

    table = List.to_tuple(table)
    :persistent_term.put({__MODULE__, :crc32c_table}, table)
    table
  end
end
