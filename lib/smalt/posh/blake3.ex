defmodule Smalt.Posh.Blake3 do
  @moduledoc """
  Pure-Elixir BLAKE3 (keyless hash, 32-byte output).

  Faithful transliteration of the reference implementation: 1024-byte
  left-full chunk tree, 7-round compression function with message-word
  permutation applied between rounds, feed-forward `state[i] ^= state[i+8];
  state[i+8] ^= cv[i]`. Output is the standard 32-byte keyless digest,
  byte-identical with `golang.org/x/crypto/blake3` / `lukechampine.com/blake3`
  and verified against the published BLAKE3 known-answer vectors.

  No NIF, no hex dependency — hermetic by construction.
  """

  import Bitwise

  @block_len 64
  @chunk_len 1024

  @chunk_start 1
  @chunk_end 2
  @parent 4
  @root 8

  @iv [
    0x6A09E667,
    0xBB67AE85,
    0x3C6EF372,
    0xA54FF53A,
    0x510E527F,
    0x9B05688C,
    0x1F83D9AB,
    0x5BE0CD19
  ]

  # new[i] = old[perm[i]] (the spec's message-word permutation)
  @permutation [2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8]

  @mask 0xFFFFFFFF

  @doc """
  32-byte keyless BLAKE3 digest of `data`.
  """
  @spec digest(binary()) :: <<_::256>>
  def digest(data) when is_binary(data) do
    subtree_output(data, 0)
    |> root_words()
    |> encode_words()
  end

  @doc """
  Digest over a caller-supplied domain-separation prefix (the exact byte
  string, e.g. `op_utf8 <> <<ts::64-big>> <> payload_body`). No length
  prefixes, no separators — cross-language byte-exact.
  """
  @spec digest_prefixed(binary()) :: <<_::256>>
  def digest_prefixed(data) when is_binary(data), do: digest(data)

  # -- tree (left-full, per the BLAKE3 spec) ----------------------------------

  # Root output of the subtree rooted at `chunk_counter`.
  defp subtree_output(data, ctr) when byte_size(data) <= @chunk_len do
    chunk_output(data, ctr)
  end

  defp subtree_output(data, ctr) do
    split = left_len(byte_size(data))
    {left, right} = :erlang.split_binary(data, split)
    lcv = subtree_output(left, ctr) |> output_cv()
    rcv = subtree_output(right, ctr + div(split, @chunk_len)) |> output_cv()
    parent_output(lcv, rcv)
  end

  # Left-full split: left side takes the largest power-of-two number of
  # chunks that still leaves at least one chunk on the right.
  defp left_len(len) do
    full_chunks = div(len - 1, @chunk_len)
    next_pow2(div(full_chunks, 2) + 1) * @chunk_len
  end

  defp next_pow2(n) when n <= 1, do: 1
  defp next_pow2(n), do: np2(1, n)

  defp np2(p, n) when p >= n, do: p
  defp np2(p, n), do: np2(p * 2, n)

  # -- nodes ------------------------------------------------------------------

  defmodule Output do
    @moduledoc false
    defstruct [:cv, :block, :counter, :block_len, :flags]
  end

  # The final compression of a chunk or parent node, held un-run: a chaining
  # value fed to its parent, or the root of the whole tree — decided by caller.
  defp chunk_output(chunk, ctr) do
    {cv, compressed, rest} = absorb_blocks(Enum.take(@iv, 8), ctr, chunk, 0)

    %Output{
      cv: cv,
      block: words_from_le_bytes(rest),
      counter: ctr,
      block_len: byte_size(rest),
      flags: @chunk_end ||| if(compressed == 0, do: @chunk_start, else: 0)
    }
  end

  defp absorb_blocks(cv, ctr, rest, compressed) do
    if byte_size(rest) > @block_len do
      <<block::bytes-size(64), tail::bytes>> = rest
      flags = if compressed == 0, do: @chunk_start, else: 0
      st16 = compress(cv, words_from_le_bytes(block), ctr, @block_len, flags)
      absorb_blocks(Enum.map(0..7, &elem(st16, &1)), ctr, tail, compressed + 1)
    else
      {cv, compressed, rest}
    end
  end

  defp parent_output(left, right) do
    %Output{cv: Enum.take(@iv, 8), block: left ++ right, counter: 0, block_len: @block_len, flags: @parent}
  end

  defp output_cv(%Output{cv: cv, block: block, counter: counter, block_len: block_len, flags: flags}) do
    st16 = compress(cv, block, counter, block_len, flags)
    Enum.map(0..7, &elem(st16, &1))
  end

  defp root_words(%Output{} = out) do
    compress(out.cv, out.block, out.counter, out.block_len, out.flags ||| @root)
  end

  # -- compression function -----------------------------------------------------

  # cv: 8 words. block: 16 words. Returns the full 16-word state.
  defp compress(cv, block, counter, block_len, flags) do
    state =
      List.to_tuple(
        cv ++ Enum.take(@iv, 4) ++ [counter &&& @mask, counter >>> 32, block_len, flags]
      )

    {state, _} =
      Enum.reduce(1..6, round_first(state, block), fn _, {st, m} ->
        round(st, m)
      end)

    final_xor(state, cv)
  end

  defp round_first(state, m), do: round(state, m)

  defp round(state, m) do
    state
    |> g(0, 4, 8, 12, at(m, 0), at(m, 1))
    |> g(1, 5, 9, 13, at(m, 2), at(m, 3))
    |> g(2, 6, 10, 14, at(m, 4), at(m, 5))
    |> g(3, 7, 11, 15, at(m, 6), at(m, 7))
    |> g(0, 5, 10, 15, at(m, 8), at(m, 9))
    |> g(1, 6, 11, 12, at(m, 10), at(m, 11))
    |> g(2, 7, 8, 13, at(m, 12), at(m, 13))
    |> g(3, 4, 9, 14, at(m, 14), at(m, 15))
    |> then(&{&1, permute(m)})
  end

  defp at(m, i), do: Enum.at(m, i)

  defp permute(m), do: for(i <- 0..15, do: Enum.at(m, Enum.at(@permutation, i)))

  defp g(st, a, b, c, d, mx, my) do
    a0 = elem(st, a)
    b0 = elem(st, b)
    c0 = elem(st, c)
    d0 = elem(st, d)

    t0 = wrap(a0 + b0 + mx)
    d1 = rotr(bxor(d0, t0), 16)
    c1 = wrap(c0 + d1)
    b1 = rotr(bxor(b0, c1), 12)
    t2 = wrap(t0 + b1 + my)
    d2 = rotr(bxor(d1, t2), 8)
    c2 = wrap(c1 + d2)
    b2 = rotr(bxor(b1, c2), 7)

    st
    |> put_elem(a, t2)
    |> put_elem(b, b2)
    |> put_elem(c, c2)
    |> put_elem(d, d2)
  end

  defp final_xor(state, cv) do
    st = Enum.reduce(0..7, state, fn i, acc -> put_elem(acc, i, bxor(elem(acc, i), elem(acc, i + 8))) end)

    Enum.reduce(8..15, st, fn i, acc ->
      put_elem(acc, i, bxor(elem(acc, i), Enum.at(cv, i - 8)))
    end)
  end

  # -- helpers -------------------------------------------------------------

  defp wrap(n), do: rem(n, 0x1_0000_0000)

  defp rotr(x, n) do
    ((x >>> n) ||| (x <<< (32 - n))) &&& @mask
  end

  defp words_from_le_bytes(bin) do
    bin
    |> pad64()
    |> decode_words_le()
  end

  defp decode_words_le(bin) do
    for <<w::32-little <- bin>>, do: w
  end

  defp pad64(block) do
    case byte_size(block) do
      64 -> block
      n -> block <> :binary.copy(<<0>>, @block_len - n)
    end
  end

  defp encode_words(state) do
    Enum.map_join(0..7, fn i -> <<elem(state, i)::32-little>> end)
  end
end
