defmodule Smalt.Auth.BodyCache do
  @moduledoc """
  `Plug.Parsers` `:body_reader` that caches the raw request body in
  `conn.private[:smalt_raw_body]` so the STS token endpoint can detect
  DUPLICATE `grant_type` parameters — the one key it fences (Plug's form
  decoding is last-wins, which would let an attacker overwrite it; OAuth 2.1
  draft + real AAD refuse duplicates with `invalid_request`). Other
  duplicated parameters fall through to Plug's last-wins decoding.

  Fail-closed: any read error passes through unchanged; the duplicate check
  degrades to the old last-wins behaviour when no raw body is cached.

  `:body_reader` is an MFA `{mod, fun, args}`; Plug calls
  `apply(mod, fun, [conn, read_opts | args])`.
  """

  def read_body(conn, read_opts) do
    # Chunked bodies (lens-2 cycle 1): Plug.Parsers loops the body_reader
    # until :ok; caching ONLY the returned fragment overwrote :smalt_raw_body
    # with the last chunk, so a duplicate grant_type= split across chunks
    # evaded the STS duplicate check (fail-open). Accumulate instead: the
    # final cached value is the COMPLETE raw body, byte-identical.
    already = conn.private[:smalt_raw_body] || ""

    case Plug.Conn.read_body(conn, read_opts) do
      {:ok, body, conn} ->
        {:ok, body, Plug.Conn.put_private(conn, :smalt_raw_body, already <> body)}

      {:more, chunk, conn} ->
        {:more, chunk,
         Plug.Conn.put_private(conn, :smalt_raw_body, already <> chunk)}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
