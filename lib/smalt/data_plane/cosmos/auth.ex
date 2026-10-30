defmodule Smalt.DataPlane.Cosmos.Auth do
  # T09 cosmos split (lane L10, v26.10.29 window): master-key string-to-sign
  # moved verbatim from `Smalt.DataPlane.Cosmos` (the authorize / master_key /
  # master_sig / valid_master_sig? / unauthorized closure). The Cosmos engine
  # delegates through `Cosmos.Auth.authorize/4`; wire behavior is
  # byte-identical — same auth_mode gate, same URI-decode, same HMAC over the
  # same five-member string-to-sign.
  @moduledoc """
  Cosmos master-key authorization: the real Cosmos string-to-sign.

  Sig is `Base64(HMAC-SHA256(master_key, string-to-sign))` over
  `verb / resource type / resource link / lowercased x-ms-date / two empty
  members`, newline-joined. Only consulted when `auth_mode == :enforce` AND
  `:cosmos_master_key` is set; non-master Authorization schemes (Bearer) pass
  through untouched.
  """

  alias Smalt.DataPlane.ConditionalHeaders

  @request_charge "1.0"

  # Master-key Authorization validation, :enforce auth_mode only (Bearer and
  # anonymous paths untouched).
  def authorize(verb, resource_type, resource_link, headers) do
    if Application.get_env(:smalt, :auth_mode) == :enforce do
      case master_key() do
        nil ->
          :ok

        key ->
          case ConditionalHeaders.header(headers || %{}, "authorization") do
            nil ->
              :ok

            raw ->
              case master_sig(raw) do
                nil ->
                  :ok

                sig ->
                  if valid_master_sig?(verb, resource_type, resource_link, headers, sig, key),
                    do: :ok,
                    else: {:halt, unauthorized()}
              end
          end
      end
    else
      :ok
    end
  end

  # :cosmos_master_key resolution: non-empty binary only, else nil (auth then
  # passes through — an unset key never authenticates-by-omission).
  def master_key do
    case Application.get_env(:smalt, :cosmos_master_key) do
      key when is_binary(key) and key != "" -> key
      _ -> nil
    end
  end

  # Authorization header wire form is URL-encoded:
  # "type%3dmaster%26ver%3d1.0%26sig%3d<base64>". Returns the sig or nil when
  # the header is not the master-key scheme.
  def master_sig(raw) do
    case URI.decode_query(URI.decode(raw)) do
      %{"type" => "master", "sig" => sig} when is_binary(sig) and sig != "" -> sig
      _ -> nil
    end
  end

  def string_to_sign(verb, resource_type, resource_link, headers) do
    date = ConditionalHeaders.header(headers || %{}, "x-ms-date") || ""
    "#{Atom.to_string(verb)}\n#{resource_type}\n#{resource_link}\n#{String.downcase(date)}\n\n"
  end

  def valid_master_sig?(verb, resource_type, resource_link, headers, sig, key) do
    string_to_sign = string_to_sign(verb, resource_type, resource_link, headers)

    case Base.decode64(sig) do
      {:ok, provided} ->
        expected = :crypto.mac(:hmac, :sha256, key, string_to_sign)
        Plug.Crypto.secure_compare(provided, expected)

      :error ->
        false
    end
  end

  def unauthorized do
    {:ok, 401, %{"x-ms-request-charge" => @request_charge},
     %{
       "code" => "Unauthorized",
       "message" =>
         "The input authorization token can't serve the request. Please check that the expected payload is built as per the documentation."
     }}
  end
end