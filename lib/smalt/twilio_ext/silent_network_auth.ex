defmodule Smalt.TwilioExt.SilentNetworkAuth do
  @moduledoc """
  Verify Silent Network Authentication (channel "sna"). Magic: to=+15005550001
  refused (60200); to ending in "0" => carrier unsupported (60605);
  otherwise verification is created pending with a carrier url.
  """
  def create("VA" <> hex = svc, %{"To" => to} = p) when byte_size(hex) == 32 do
    cond do
      Map.get(p, "Channel", "sna") != "sna" -> err(60200, "Invalid parameter `Channel`", 400)
      not is_binary(to) or to == "+15005550001" or not Regex.match?(~r/\A\+[1-9]\d{7,14}\z/, to) ->
        err(60200, "Invalid parameter `To`: #{to}", 400)
      String.ends_with?(to, "0") -> err(60605, "Silent network auth unsupported for carrier", 400)
      true ->
        {:ok, %{"sid" => "VE" <> String.duplicate("0", 32), "service_sid" => svc, "to" => to,
                "channel" => "sna", "status" => "pending",
                "sna" => %{"url" => "https://mi.dnlsrv.com/sna/" <> Base.url_encode64(to, padding: false)}}}
    end
  end
  def create(_, _), do: err(20404, "The requested resource was not found", 404)

  def check(%{"status" => "pending"} = v, carrier_result) when carrier_result in [:ok, :fail] do
    {:ok, %{v | "status" => if(carrier_result == :ok, do: "approved", else: "denied")}}
  end

  defp err(code, msg, status), do: {:error, %{"code" => code, "message" => msg, "status" => status}}
end
