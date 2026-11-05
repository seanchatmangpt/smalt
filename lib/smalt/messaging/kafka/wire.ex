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
  | Produce | 0 | 0..3 | v9 |
  | Fetch | 1 | 0..0 | v12 |
  | ListOffsets | 2 | 0..1 | v7 |
  | Metadata | 3 | 0..4 | v9 |
  | ApiVersions | 18 | 0..0 | v3 |
  | SaslHandshake | 17 | 0..0 | v1 |
  | SaslAuthenticate | 36 | 0..1 | v1 |

  Everything outside the matrix — transactions, compaction, ACLs, groups,
  compact/flexible encodings, unknown api_keys — gets the crash-only face:
  typed log + connection killed, socket closed. Named falsifier: a raw-TCP
  probe sending Produce (api 0) v9 (first flexible version) must be
  disconnected, never answered with a parse guess.

  SASL face (SaslHandshake 17 / SaslAuthenticate 36): an UNADVERTISED
  mechanism on SaslHandshake answers error 33 (UNSUPPORTED_SASL_MECHANISM)
  followed by a connection kill — never a parse guess of an unconfigured
  mechanism. Under `sasl_required: true`, any non-SASL api_key before a
  successful SaslAuthenticate is killed typed ({:sasl_required, key}),
  never served. (Falsifier corpus: scripts/az1/kafka_sasl_negative_probe.py.)
  """

  import Bitwise

  @typedoc "Kafka error codes this face emits (protocol guide §2, Error Codes)."
  @type error :: :none | :corrupt_message | :unknown_topic_or_partition | :policy_violation

  @doc "api_key numbers per the protocol guide."
  @spec api_keys() :: %{
          required(:produce) => 0,
          required(:fetch) => 1,
          required(:list_offsets) => 2,
          required(:metadata) => 3,
          required(:offset_commit) => 8,
          required(:offset_fetch) => 9,
          required(:find_coordinator) => 10,
          required(:join_group) => 11,
          required(:heartbeat) => 12,
          required(:leave_group) => 13,
          required(:sync_group) => 14
        }
  def api_keys do
    %{
      produce: 0,
      fetch: 1,
      list_offsets: 2,
      metadata: 3,
      # KD-COVERS: KD-190 — group-family keys, verified against the vendored
      # client's own protocol module (tmp/kafkalib/kafka/protocol/commit.py:
      # OffsetCommit=8 OffsetFetch=9 FindCoordinator=10; group.py:
      # JoinGroup=11 Heartbeat=12 LeaveGroup=13 SyncGroup=14).
      offset_commit: 8,
      offset_fetch: 9,
      find_coordinator: 10,
      join_group: 11,
      heartbeat: 12,
      leave_group: 13,
      sync_group: 14,
      # KD-COVERS: KD-191 — SASL face (SaslHandshake=17, SaslAuthenticate=36
      # per the Kafka protocol guide §4.2/4.3; the vendored kafka-python-ng
      # protocol module carries the same numbers).
      sasl_handshake: 17,
      sasl_authenticate: 36,
      api_versions: 18
    }
  end

  @doc "Advertised {min, max} per api_key — exactly the served surface, nothing more."
  @spec version_matrix() :: %{non_neg_integer() => {non_neg_integer(), non_neg_integer()}}
  def version_matrix do
    %{
      # KD-COVERS: KD-174 — Produce v3 advertised so real clients negotiate
      # magic-2 RecordBatch produce (Produce v3 == v2 wire schema at this
      # face: record_set bytes + throttle-tail response).
      # produce (kafka-python picks broker_max per API from ApiVersions).
      # Request/response shapes for v3 are byte-shape-identical to v2 here
      # (record_set bytes + {partition, err, base_offset, timestamp} block,
      # throttle tail) — see Conn.route(0, ...) and Records magic-2 codec.
      0 => {0, 3},
      # KD-COVERS: KD-190 — Fetch v3 added: the vendored client sends Fetch v3
      # at the (0,10,1) consumer posture (fetcher.py picks v3 for
      # api_version >= (0,10,1) WITHOUT ApiVersions down-negotiation). v3
      # request adds a top-level max_bytes; response shape is v2-identical.
      1 => {0, 3},
      2 => {0, 1},
      # KD-COVERS: KD-174 — Metadata v2..v4 is required for the Produce v3
      # negotiation to be reachable at all: a real 0.11-class client
      # (api_version=(0,11,0), the KD-174D2 probe posture) resolves topics
      # with MetadataRequest[4] before producing, and v2/v3/v4 response
      # shapes are additive over v1 (cluster_id string, throttle head).
      3 => {0, 4},
      # KD-COVERS: KD-190 — consumer-group family. Every cap is strictly
      # below the KIP-482 flexible threshold for its API and is also an
      # api_version the vendored kafka-python-ng actually sends at the
      # (0,10,1) probe posture (checks against tmp/kafkalib class lists:
      # OffsetCommit v0..v3 all real; OffsetFetch v0/v1; FindCoordinator
      # v0/v1; JoinGroup v0/v1/v2 (v5 is the first flexible JoinGroup);
      # Heartbeat v0/v1; LeaveGroup v0/v1 (v2 does not exist in the vendored
      # protocol module — the class list jumps v1 -> v3); SyncGroup v0/v1
      # (v3 is the first flexible SyncGroup)).
      8 => {0, 3},
      9 => {0, 1},
      10 => {0, 1},
      11 => {0, 2},
      12 => {0, 1},
      13 => {0, 1},
      14 => {0, 1},
      # KD-COVERS: KD-191 — SASL face. Handshake v0 only (v1 is the first
      # flexible SaslHandshake). SaslAuthenticate v0..v1: v1's compact
      # string/bytes fields are served explicitly (the API's flexible
      # threshold is v1 for SaslHandshake; SaslAuthenticate goes flexible
      # only at v2, so both advertised versions are classic-width here
      # except v1's own KIP-482 compact fields, parsed and encoded in
      # Conn.route_sasl_authenticate).
      17 => {0, 0},
      36 => {0, 1},
      18 => {0, 0}
    }
  end

  @doc "Kafka error codes used by this face."
  @spec error_code(atom()) :: non_neg_integer()
  def error_code(:none), do: 0
  def error_code(:corrupt_message), do: 2
  def error_code(:unknown_topic_or_partition), do: 3
  def error_code(:policy_violation), do: 44
  # KD-COVERS: KD-191 — SASL error codes (protocol guide §2 Error Codes:
  # 33 UNSUPPORTED_SASL_MECHANISM, 34 ILLEGAL_SASL_STATE,
  # 58 SASL_AUTHENTICATION_FAILED).
  def error_code(:unsupported_sasl_mechanism), do: 33
  def error_code(:illegal_sasl_state), do: 34
  def error_code(:sasl_authentication_failed), do: 58

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
