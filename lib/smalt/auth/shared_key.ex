defmodule Smalt.Auth.SharedKey do
  @moduledoc """
  Azure Storage SharedKey authorization (KD-114 close, lane W20-B).

  Verifies the real wire form `Authorization: SharedKey <account>:<signature>`
  per the real Azure Blob service SharedKey scheme (2021-12-02 shape, blob
  service StringToSign):

      signature = BASE64(HMAC-SHA256(StringToSign, decoded-account-key))

  The account key is the emulator's single per-account derivation
  (`Smalt.EgressRouter.account_key/1`) — the same key the user-delegation-key
  mint consumes, so a client holding the per-account dev key
  (base64(sha256(account <> "smalt-dev-sb"))) signs validly on this face.

  Scope: the blob/data-plane face. A SharedKey-scheme Authorization header is
  only ever produced by storage clients, so the bearer plug dispatches on the
  scheme prefix; every other Authorization shape takes the unchanged bearer
  path (refuses fail-closed as before).
  """

  @behaviour Plug

  import Plug.Conn

  alias Smalt.EgressRouter

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts), do: verify(conn)

  @doc """
  Verifies the SharedKey Authorization header on `conn`.

  Returns `:ok` when the signature verifies; `{:refuse, code, reason}`
  otherwise (the caller — `Smalt.Auth.Bearer.admission/1` — renders the 401
  with the standard ARM error envelope). Refusal is typed
  `AuthenticationFailed` with the real-Azure MAC-mismatch message for a
  tampered signature and `MalformedSharedKeyHeader` for an unparseable
  SharedKey header shape.

  Fail-closed: a missing or ambiguous (multiple) Authorization header, a
  bad-base64 signature, an undecodable account key, or a signature mismatch
  all refuse. Signature comparison is constant-time
  (`Plug.Crypto.secure_compare/2`).
  """
  @spec verify(Plug.Conn.t()) :: :ok | {:refuse, String.t(), String.t()}
  def verify(%Plug.Conn{} = conn) do
    with {:ok, account, sig} <- extract(conn),
         {:ok, key_b64} <- EgressRouter.account_key(account),
         {:ok, key} <- decode_key(key_b64),
         :ok <- signature_ok?(conn, account, key, sig) do
      :ok
    end
  end

  # -- header extraction -------------------------------------------------------

  # Exactly one Authorization header (same RFC 9110 5.3 discipline as the
  # bearer extractor's M-L5-3 typed decision: Authorization is not
  # list-combinable; ambiguity refuses fail-closed).
  defp extract(conn) do
    case get_req_header(conn, "authorization") do
      [value] ->
        parse_shared_key(value)

      _ ->
        {:refuse, "AuthenticationFailed", "MalformedSharedKeyHeader"}
    end
  end

  # `SharedKey <account>:<base64sig>` — scheme matched case-insensitively
  # (RFC 7235 2.1); account and signature both required non-empty.
  defp parse_shared_key(value) do
    case String.split(value, " ", parts: 2) do
      [scheme, rest] ->
        if String.downcase(String.trim(scheme)) == "sharedkey" do
          case String.split(String.trim(rest), ":", parts: 2) do
            [account, sig] when byte_size(account) > 0 and byte_size(sig) > 0 ->
              {:ok, account, sig}

            _ ->
              {:refuse, "AuthenticationFailed", "MalformedSharedKeyHeader"}
          end
        else
          {:refuse, "AuthenticationFailed", "MalformedSharedKeyHeader"}
        end

      _ ->
        {:refuse, "AuthenticationFailed", "MalformedSharedKeyHeader"}
    end
  end

  # -- key handling ----------------------------------------------------------

  # Real Azure stores the account key base64-encoded; SharedKey clients HMAC
  # with the DECODED key bytes (JS SDK: createHmac('sha256', decodedKey)).
  # An undecodable configured key refuses fail-closed.
  defp decode_key(key_b64) do
    case Base.decode64(key_b64) do
      {:ok, key} -> {:ok, key}
      :error -> {:refuse, "AuthenticationFailed", "AccountKeyMalformed"}
    end
  end

  # -- signature -------------------------------------------------------------

  defp signature_ok?(conn, account, key, sig) do
    sts = string_to_sign(conn, account)
    expected = Base.encode64(:crypto.mac(:hmac, :sha256, key, sts))

    if Plug.Crypto.secure_compare(expected, sig) do
      :ok
    else
      {:refuse, "AuthenticationFailed",
       "The MAC signature found in the HTTP request is not the same as any computed signature."}
    end
  end

  # -- StringToSign (blob service, 2021-12-02 shape) --------------------------

  @doc false
  def string_to_sign(conn, account) do
    standard = [
      conn.method,
      hdr(conn, "content-encoding"),
      hdr(conn, "content-language"),
      content_length(conn),
      hdr(conn, "content-md5"),
      hdr(conn, "content-type"),
      date_part(conn),
      hdr(conn, "if-modified-since"),
      hdr(conn, "if-match"),
      hdr(conn, "if-none-match"),
      hdr(conn, "if-unmodified-since"),
      hdr(conn, "range")
    ]

    Enum.join(standard, "\n") <>
      "\n" <> canonicalized_headers(conn) <> canonicalized_resource(conn, account)
  end

  # Date leg: empty when x-ms-date is present (real-Azure rule); otherwise
  # the Date header. The SDK always sends x-ms-date.
  defp date_part(conn) do
    if hdr(conn, "x-ms-date") == "" do
      hdr(conn, "date")
    else
      ""
    end
  end

  # Content-Length leg: the decimal length when present and non-zero, empty
  # otherwise (real-Azure rule for versions >= 2015-02-21).
  defp content_length(conn) do
    case hdr(conn, "content-length") do
      "" -> ""
      "0" -> ""
      len -> len
    end
  end

  # Canonicalized headers: every x-ms-* header, name lowercased, value
  # trimmed, sorted by name, each rendered "name:value\n".
  defp canonicalized_headers(conn) do
    conn.req_headers
    |> Enum.filter(fn {name, _} -> String.starts_with?(name, "x-ms-") end)
    |> Enum.sort(fn {a, _}, {b, _} -> a <= b end)
    |> Enum.map(fn {name, value} -> "#{name}:#{String.trim(value)}\n" end)
    |> Enum.join()
  end

  # Canonicalized resource: "/<account>/<path...>" + sorted query params as
  # "\n<lowername>:<rawvalue>" (raw values, matching the JS SDK which walks
  # the raw query string; name lowercased per real-Azure rule).
  defp canonicalized_resource(conn, account) do
    "/" <> account <> conn.request_path <> query_part(conn.query_string)
  end

  defp query_part("" = _qs), do: ""
  defp query_part(qs) when is_binary(qs) do
    qs
    |> String.split("&", trim: true)
    |> Enum.map(fn pair ->
      case String.split(pair, "=", parts: 2) do
        [name] -> {name, ""}
        [name, value] -> {name, value}
      end
    end)
    |> Enum.sort(fn {a, _}, {b, _} -> String.downcase(a) <= String.downcase(b) end)
    |> Enum.map(fn {name, value} -> "\n" <> String.downcase(name) <> ":" <> value end)
    |> Enum.join()
  end

  defp hdr(conn, name) do
    case get_req_header(conn, name) do
      [v | _] -> v
      [] -> ""
    end
  end
end
