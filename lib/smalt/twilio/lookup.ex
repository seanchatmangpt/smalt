defmodule Smalt.Twilio.Lookup do
  @moduledoc """
  Offline mirror of Twilio Lookup v2
  (`https://lookups.twilio.com/v2/PhoneNumbers/{n}?Fields=sim_swap`).
  Magic numbers (shared with TW2): +15005550006 valid, +15005550001 invalid,
  +15005550009 valid with recent SIM swap. Pure; no network.
  """

  @valid "+15005550006"
  @invalid "+15005550001"
  @swapped "+15005550009"

  def magic, do: %{valid: @valid, invalid: @invalid, swapped: @swapped}

  @spec fetch(String.t(), String.t() | nil) :: {:ok, map()}
  def fetch(number, fields \\ nil) when is_binary(number) do
    fields = if fields, do: String.split(fields, ",", trim: true), else: []
    url = "https://lookups.twilio.com/v2/PhoneNumbers/" <> URI.encode_www_form(number)

    if number == @invalid or not e164?(number) do
      {:ok,
       base(number, url, false, ["INVALID_NUMBER"])
       |> Map.put("phone_number", nil)
       |> Map.put("national_format", nil)}
    else
      {:ok, base(number, url, true, []) |> add_fields(fields, number)}
    end
  end

  defp e164?(n), do: Regex.match?(~r/^\+[1-9]\d{7,14}$/, n)

  defp base(number, url, valid, errors) do
    %{
      "calling_country_code" => "1",
      "country_code" => "US",
      "phone_number" => number,
      "national_format" => national(number),
      "valid" => valid,
      "validation_errors" => errors,
      "caller_name" => nil,
      "sim_swap" => nil,
      "call_forwarding" => nil,
      "line_status" => nil,
      "line_type_intelligence" => nil,
      "identity_match" => nil,
      "reassigned_number" => nil,
      "sms_pumping_risk" => nil,
      "phone_number_quality_score" => nil,
      "pre_fill" => nil,
      "url" => url
    }
  end

  defp national("+1" <> <<a::binary-size(3), b::binary-size(3), c::binary-size(4)>>),
    do: "(#{a}) #{b}-#{c}"

  defp national(_), do: nil

  defp add_fields(map, fields, number) do
    if "sim_swap" in fields do
      swapped = number == @swapped

      Map.put(map, "sim_swap", %{
        "last_sim_swap" => %{
          "last_sim_swap_date" => if(swapped, do: "2026-11-13T00:00:00Z", else: nil),
          "swapped_period" => if(swapped, do: "PT24H", else: nil),
          "swapped_in_period" => swapped
        },
        "carrier_name" => "Twilio Test Carrier",
        "mobile_country_code" => "310",
        "mobile_network_code" => "410",
        "error_code" => nil
      })
    else
      map
    end
  end
end
