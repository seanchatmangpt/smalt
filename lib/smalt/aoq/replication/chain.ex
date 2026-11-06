defmodule Smalt.Aoq.Replication.Chain do
  @moduledoc """
  S21 cross-cloud replication chain law (L11 retarget lineage).

  Each replicated entry rides an AoQ data frame whose payload is an
  s21 segment: `<<seq::u64-BE, prev::binary-32, link::binary-32,
  src_len::u16-BE, source_id::binary, body::binary>>`. The link digest is

      BLAKE3("SMALT/S21-REPL/v1" || raw32(prev) || seq::u64-BE ||
             raw32(blake3(body)) || source_id)

  — the L11 `SMALT/AOQ-LINK/v2` shape (domain ‖ raw32(prev) ‖ seq ‖
  raw32(data_hash) ‖ sub-ledger id) re-domained for the replication
  fabric, binding the `s21.src.` source namespace into every link AND
  carrying it on the wire, so a link transplanted from another node
  refuses typed `:source_unbound` before any local re-derivation runs.

  Spoliation law: BLAKE3 chain continuity across nodes must be provable.
  A chain that breaks silently IS spoliation. Every discontinuity —
  sequence gap, prev-hash break, link re-derivation mismatch, frame
  digest failure, or a segment that does not parse as an s21 segment —
  refuses typed as `{:spoliation, reason}`; nothing is applied past a
  break, and the refusal is never swallowed.
  """

  alias Smalt.Posh.Blake3

  @link_domain "SMALT/S21-REPL/v1"
  @zero :binary.copy(<<0>>, 32)

  @typedoc "Source namespace id, e.g. `\"s21.src.node-a\"`."
  @type source_id :: String.t()

  @typedoc """
  Typed spoliation refusal reasons. Every discontinuity refuses typed;
  nothing applies past a break.
  """
  @type spoliation ::
          {:spoliation,
           :malformed_segment
           | {:chain_gap, non_neg_integer(), non_neg_integer()}
           | {:prev_hash_discontinuity, binary(), binary()}
           | {:link_mismatch, binary(), binary()}
           | {:frame_digest, term()}
           | :source_unbound}

  @doc "Link-law domain string (`SMALT/S21-REPL/v1`)."
  @spec link_domain() :: String.t()
  def link_domain, do: @link_domain

  @doc "Genesis prev hash (32 zero bytes)."
  @spec zero() :: <<_::256>>
  def zero, do: @zero

  @doc "BLAKE3 data hash of a segment body (raw 32 bytes)."
  @spec data_hash(binary()) :: <<_::256>>
  def data_hash(body) when is_binary(body), do: Blake3.digest(body)

  @doc """
  S21 chain link digest (raw 32 bytes):

      BLAKE3("SMALT/S21-REPL/v1" || raw32(prev) || seq::u64-BE ||
             raw32(data_hash) || source_id)

  `prev` and `data_hash` enter RAW — folding the hex/text form instead is
  the canonical mutant class (same as the L11 hex-fold shim court).
  """
  @spec link(<<_::256>>, non_neg_integer(), <<_::256>>, source_id()) :: <<_::256>>
  def link(prev, seq, data_hash, source_id)
      when is_binary(prev) and byte_size(prev) == 32 and is_integer(seq) and seq >= 0 and
             is_binary(data_hash) and byte_size(data_hash) == 32 and is_binary(source_id) do
    Blake3.digest_prefixed(
      <<@link_domain::binary, prev::binary-size(32), seq::unsigned-big-integer-size(64),
        data_hash::binary-size(32), source_id::binary>>
    )
  end

  @doc """
  Encodes one s21 segment (the payload of an AoQ data frame):
  `<<seq::u64-BE, prev::binary-32, link::binary-32, src_len::u16-BE,
  source_id::binary, body::binary>>` with the link derived under the
  chain law from `prev` and `body`. `body` must be ≥1 byte — an empty
  body admits no data and refuses typed rather than emitting a vacuous
  link.
  """
  @spec segment(non_neg_integer(), <<_::256>>, binary(), source_id()) ::
          {:ok, binary()} | {:error, :empty_body}
  def segment(seq, prev, body, source_id)
      when is_integer(seq) and seq >= 0 and is_binary(source_id) do
    case body do
      <<>> ->
        {:error, :empty_body}

      _ ->
        link = link(prev, seq, data_hash(body), source_id)

        {:ok,
         <<seq::unsigned-big-integer-size(64), prev::binary-size(32), link::binary-size(32),
           byte_size(source_id)::unsigned-big-integer-size(16), source_id::binary, body::binary>>}
    end
  end

  @doc """
  Parses an s21 segment back into `{seq, prev, link, source_id, body}`.
  A segment that does not match the wire shape (header too short, source
  id length lying about its span, zero-length body) refuses
  `:malformed_segment`.
  """
  @spec parse(binary()) ::
          {:ok, {non_neg_integer(), <<_::256>>, <<_::256>>, source_id(), binary()}}
          | {:error, :malformed_segment}
  def parse(
        <<seq::unsigned-big-integer-size(64), prev::binary-size(32), link::binary-size(32),
          src_len::unsigned-big-integer-size(16), source_id::binary-size(src_len), body::binary>>
      )
      when byte_size(body) >= 1 do
    {:ok, {seq, prev, link, source_id, body}}
  end

  def parse(_), do: {:error, :malformed_segment}

  @doc """
  Chain continuity verdict for one incoming segment against the node's
  current chain head `%{last_seq: seq, head: prev}` under the bound
  source namespace `bound_source_id`.

  Refusal order (all typed spoliation): `:source_unbound` (the segment's
  carried source namespace is not the bound source — checked FIRST, so a
  foreign link is never re-derived against the local law), then segment
  shape (`:malformed_segment`), then sequence gap (`{:chain_gap,
  expected, got}`), then prev-hash discontinuity, then link
  re-derivation (`{:link_mismatch, expected, got}`).

  `{:ok, :continuity}` means the segment lawfully continues the chain.
  """
  @spec verify(%{last_seq: non_neg_integer(), head: binary()}, binary(), source_id()) ::
          {:ok, :continuity} | {:error, spoliation()}
  def verify(%{last_seq: last_seq, head: head}, seg, bound_source_id)
      when is_binary(bound_source_id) do
    with {:ok, {seq, prev, link, source_id, body}} <- parse(seg),
         :ok <-
           if(source_id == bound_source_id,
             do: :ok,
             else: {:error, {:spoliation, :source_unbound}}
           ),
         :ok <-
           if(seq == last_seq + 1, do: :ok, else: {:error, {:spoliation, {:chain_gap, last_seq + 1, seq}}}),
         :ok <-
           if(prev == head,
             do: :ok,
             else: {:error, {:spoliation, {:prev_hash_discontinuity, head, prev}}}
           ),
         expected = link(prev, seq, data_hash(body), bound_source_id),
         :ok <-
           if(link == expected, do: :ok, else: {:error, {:spoliation, {:link_mismatch, expected, link}}}) do
      {:ok, :continuity}
    end
  end

  @doc """
  Advances the chain head over a verified segment: returns the new head
  `%{last_seq:, head:}` where `head` is the segment's own link digest
  (each link IS the next chain root — the L11 root-as-head law).
  """
  @spec advance(%{last_seq: non_neg_integer(), head: binary()}, binary()) ::
          {:ok, %{last_seq: non_neg_integer(), head: <<_::256>>}}
  def advance(%{last_seq: last_seq}, seg) do
    {:ok, {seq, _prev, link, _source_id, _body}} = parse(seg)

    {:ok, %{last_seq: seq, head: link}}
  end
end
