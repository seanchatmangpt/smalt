defmodule Smalt.Aoq.Replication.Replicator do
  @moduledoc """
  Source side of the S21 replication fabric: `replicate/2` turns source
  entries into an AoQ stream of chain-linked frames and pushes them at a
  replication node over real loopback UDP (one AoQ frame per datagram).

  Each entry becomes one AoQ DATA frame (epoch 0, seq = chain seq) whose
  body is the stream prefix `0` (aoq:stream-data) followed by an s21
  segment (`Smalt.Aoq.Replication.Chain.segment/4`). The replicator walks
  the chain itself — genesis `Chain.zero()` prev, then each link's
  digest — so the wire stream is exactly the continuity claim the target
  node verifies.
  """

  alias Smalt.Aoq.Frame
  alias Smalt.Aoq.Replication.Chain

  @doc """
  Replicates `entries` (list of bodies, ≥1 byte each) to the node
  endpoint at `{host, port}`, producing the chain-linked AoQ stream.

  Returns `{:ok, %{source_id:, sent: n, head: raw32}}` — `head` is the
  final chain root the target node's head MUST equal after applying the
  whole stream — or a typed refusal: `{:error, :empty_entries}` for an
  empty list, `{:error, {:empty_body, index}}` when an entry body is
  empty, `{:error, {:send_failed, reason}}` on a datagram send refusal.
  """
  @spec replicate([binary()], {term(), :inet.port_number()}, keyword()) ::
          {:ok, %{source_id: Chain.source_id(), sent: non_neg_integer(), head: <<_::256>>}}
          | {:error,
             :empty_entries
             | {:empty_body, non_neg_integer()}
             | {:send_failed, term()}}
  def replicate(entries, {host, port} = hp, opts \\ []) when is_list(entries) do
    source_id = Keyword.get(opts, :source_id, "s21.src.node-a")

    with {:ok, stream} <- build_stream(entries, source_id),
         {:ok, sock} <- :gen_udp.open(0, [:binary]),
         :ok <- push_stream(sock, stream.frames, hp) do
      :gen_udp.close(sock)
      {:ok, %{source_id: source_id, sent: length(entries), head: stream.head}}
    end
  end

  @doc """
  Builds the chain-linked AoQ stream WITHOUT sending: returns
  `{:ok, %{frames: [iolist], head: raw32, segments: [binary]}}` or a
  typed refusal (`:empty_entries`, `{:empty_body, index}`). Exposed for
  the mutated-byte court: the court takes a lawful frame from the
  stream, flips one byte, and the target node must refuse typed — the
  flip IS the non-vacuity proof.
  """
  @spec build_stream([binary()], Chain.source_id()) ::
          {:ok, %{frames: [iolist()], head: <<_::256>>, segments: [binary()]}}
          | {:error, :empty_entries | {:empty_body, non_neg_integer()}}
  def build_stream(entries, source_id) do
    case entries do
      [] ->
        {:error, :empty_entries}

      _ ->
        case empty_at(entries) do
          nil ->
            {frames, segments, head} =
              Enum.reduce(entries, {[], [], Chain.zero()}, fn body, {fs, segs, prev} ->
                seq = length(segs) + 1
                {:ok, seg} = Chain.segment(seq, prev, body, source_id)
                {:ok, frame} =
                  Frame.encode_frame(%Frame{
                    epoch: 0,
                    key_id: 0,
                    frame_ordinal: seq,
                    seq: seq
                  }, <<0>> <> seg) # AOQ-FENCE-OK: stream-prefix <> segment (egress law)
                {fs ++ [frame], segs ++ [seg], Chain.link(prev, seq, Chain.data_hash(body), source_id)}
              end)

            {:ok, %{frames: frames, head: head, segments: segments}}

          idx ->
            {:error, {:empty_body, idx}}
        end
    end
  end

  @doc """
  Typed spoliation classifier: `{:spoliation, _}` envelopes are
  spoliation, everything else is not. Single shared definition so the
  node endpoint, the tests, and any future gate agree.
  """
  @spec spoliation?(term()) :: boolean()
  def spoliation?({:spoliation, _}), do: true
  def spoliation?(_), do: false

  # ── internals ──────────────────────────────────────────────────────

  defp empty_at(entries), do: empty_at(entries, 0)

  defp empty_at([], _i), do: nil
  defp empty_at([<<>> | _], i), do: i
  defp empty_at([_ | rest], i), do: empty_at(rest, i + 1)

  defp push_stream(sock, frames, {host, port}) do
    Enum.reduce_while(frames, :ok, fn frame, :ok ->
      case :gen_udp.send(sock, host, port, frame) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:send_failed, reason}}}
      end
    end)
  end
end
