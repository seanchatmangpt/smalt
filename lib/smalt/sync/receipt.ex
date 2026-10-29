defmodule Smalt.Sync.Receipt do
  @moduledoc """
  ATH-1 receipt: the server mirror of the landed client minter
  (`workspace/lib/engine/receipt.ts` `mintReceiptToken` + `merkle.ts`
  `Accumulator`, kind "sha256-chain").

  Chain law (identical algebra both sides): first leaf
  `h = sha256(sha256(frame_bytes))`; every later leaf
  `h = sha256(prev_root <> sha256(frame_bytes))`.

  Receipt layout (320 bytes = 40 x 8-byte words, big-endian):

      bytes  0..3   magic 0x534D4C54 ("SMLT")
      bytes  4..7   version 1
      bytes  8..15  leafCount uint64 BE (frames sealed)
      bytes 16..47  sha256-chain root (32 bytes)
      bytes 48..319 reserved, all zero

  The token is lowercase hex (640 chars). `Smalt.Egress.SyncRoutes` returns
  it as `receiptToken`; the client's `verifyReceipt` recomputes the chain
  over the synced frames and compares.
  """

  @receipt_bytes 320
  @version 1
  @magic 0x534D4C54

  @type chain :: %{root: binary() | nil, count: non_neg_integer()}

  @doc "Receipt size in bytes (320 = 40 words of 8 bytes)."
  def size_bytes, do: @receipt_bytes

  @doc "The empty running chain (no leaves folded)."
  def empty_chain, do: %{root: nil, count: 0}

  @doc "Folds one frame's wire bytes into the running chain."
  @spec absorb(chain(), binary()) :: chain()
  def absorb(%{root: nil}, frame_bytes) do
    leaf = :crypto.hash(:sha256, frame_bytes)
    %{root: :crypto.hash(:sha256, leaf), count: 1}
  end

  def absorb(%{root: root, count: n}, frame_bytes) do
    leaf = :crypto.hash(:sha256, frame_bytes)
    %{root: :crypto.hash(:sha256, root <> leaf), count: n + 1}
  end

  @doc """
  Mints the 320-byte receipt from the chain state and seals it as lowercase
  hex — byte-identical to `mintReceiptToken(leafCount, rootHex)` client-side.
  """
  @spec mint(chain()) :: String.t()
  def mint(%{root: root, count: count}) do
    root_hex = root && Base.encode16(root, case: :lower)

    <<@magic::32, @version::32, count::64,
      root_bytes(root_hex)::binary-size(32), 0::(272 * 8)>>
    |> Base.encode16(case: :lower)
  end

  defp root_bytes(nil), do: <<0::256>>
  defp root_bytes(hex), do: Base.decode16!(hex, case: :lower)
end
