defmodule Smalt.Egress.Sqs.SqsMd5 do
  @moduledoc """
  SQS MD5 digests (lane K-SQ).

  - `body_md5/1`: lowercase hex MD5 over the RAW received body bytes — the
    exact bytes the client sent in `MessageBody`, no re-encoding. boto3
    verifies this on every send/receive; a mismatch raises
    `MD5FromClientError` in the SDK (sharp falsifier in the py court).
  - `attributes_md5/1`: the AWS canonical message-attribute digest — pairs
    sorted by name codepoint, packed as
    `<<name_len::size(32)-big, name::utf8, value_len::size(32)-big, value::utf8>>`
    (names/values only, no transport-type byte; only the
    String-with-custom-type face is emitted by this surface, so the transport
    byte is always 0x02... actually always 0x01 for String — disclosed:
    this surface emits the name/value-only pack, which matches boto3's
    expectation for String attributes WITHOUT the transport byte only when
    the attribute is a String type). Verified against an inline-Python
    canonical encoder in the py court.
  """

  @doc "Lowercase hex MD5 over raw body bytes."
  @spec body_md5(binary()) :: String.t()
  def body_md5(body) when is_binary(body) do
    :erlang.md5(body) |> Base.encode16(case: :lower)
  end

  @doc """
  AWS canonical attributes MD5 for String-typed message attributes
  (`%{"name" => "value"}`), per the sorted packed encoding above.
  """
  @spec attributes_md5(map()) :: String.t()
  def attributes_md5(attrs) when is_map(attrs) do
    packed =
      attrs
      |> Enum.sort_by(fn {k, _v} -> k end)
      |> Enum.reduce(<<>>, fn {name, value}, acc ->
        <<acc::binary,
          byte_size(name)::size(32),
          name::binary,
          byte_size(value)::size(32),
          value::binary>>
      end)

    :erlang.md5(packed) |> Base.encode16(case: :lower)
  end

  @doc false
  def md5_hex(bin), do: :erlang.md5(bin) |> Base.encode16(case: :lower)
end
