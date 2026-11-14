defmodule Smalt.Twilio.Verify do
  @moduledoc """
  Offline mirror of Twilio Verify v2 (`/v2/Services/{VA}/Verifications`).
  Magic values (shared with TW2): code "123456" approves; any other code
  leaves status "pending"; to=+15005550001 refuses with 60200 invalid
  parameter. Pure; no network. Sids use documented placeholders.
  """

  @sid_hex String.duplicate("0", 32)
  @code "123456"

  def magic, do: %{code: @code, invalid_to: "+15005550001"}

  @spec create(String.t(), map()) :: {:ok, map()} | {:error, map()}
  def create(service_sid, %{"To" => to} = params) do
    channel = Map.get(params, "Channel", "sms")

    cond do
      not service?(service_sid) ->
        err(20404, "The requested resource was not found", 404)

      to == "+15005550001" or not Regex.match?(~r/^\+[1-9]\d{7,14}$/, to) ->
        err(60200, "Invalid parameter `To`: #{to}", 400)

      channel not in ~w(sms call email whatsapp) ->
        err(60200, "Invalid parameter `Channel`: #{channel}", 400)

      true ->
        {:ok, resource(service_sid, to, channel, "pending", false)}
    end
  end

  def create(_, _), do: err(60200, "Missing required parameter `To`", 400)

  @spec check(String.t(), map()) :: {:ok, map()} | {:error, map()}
  def check(service_sid, %{"To" => to, "Code" => code}) do
    if service?(service_sid) do
      ok = code == @code
      {:ok, resource(service_sid, to, "sms", if(ok, do: "approved", else: "pending"), ok)}
    else
      err(20404, "The requested resource was not found", 404)
    end
  end

  def check(_, _), do: err(60200, "Missing required parameter `Code`", 400)

  defp service?("VA" <> hex), do: Regex.match?(~r/^[0-9a-f]{32}$/, hex)
  defp service?(_), do: false

  defp resource(service_sid, to, channel, status, valid) do
    base = "https://verify.twilio.com/v2/Services/" <> service_sid
    sid = "VE" <> @sid_hex

    %{
      "sid" => sid,
      "service_sid" => service_sid,
      "account_sid" => "AC" <> @sid_hex,
      "to" => to,
      "channel" => channel,
      "status" => status,
      "valid" => valid,
      "lookup" => %{"carrier" => nil},
      "amount" => nil,
      "payee" => nil,
      "send_code_attempts" => [],
      "date_created" => "2026-11-14T00:00:00Z",
      "date_updated" => "2026-11-14T00:00:00Z",
      "url" => base <> "/Verifications/" <> sid
    }
  end

  defp err(code, msg, status) do
    {:error,
     %{
       "code" => code,
       "message" => msg,
       "more_info" => "https://www.twilio.com/docs/errors/#{code}",
       "status" => status
     }}
  end
end
