defmodule Smalt.Twilio.Signature do
  @moduledoc """
  Twilio request signature: base64(HMAC-SHA1(auth_token, url <> sorted(key <> value))).
  Mirror of the arcus TW1 algorithm.
  """

  @spec compute(String.t(), String.t(), %{optional(String.t()) => String.t()}) :: String.t()
  def compute(auth_token, url, params) do
    data =
      params
      |> Enum.sort_by(fn {k, _} -> k end)
      |> Enum.map_join(fn {k, v} -> k <> to_string(v) end)

    :crypto.mac(:hmac, :sha, auth_token, url <> data) |> Base.encode64()
  end

  @spec valid?(String.t(), String.t(), map(), String.t() | nil) :: boolean()
  def valid?(_token, _url, _params, nil), do: false

  def valid?(token, url, params, given) when is_binary(given) do
    Plug.Crypto.secure_compare(compute(token, url, params), given)
  end
end
