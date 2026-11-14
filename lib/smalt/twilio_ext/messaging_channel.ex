defmodule Smalt.TwilioExt.MessagingChannel do
  @moduledoc "RCS / WhatsApp channel-addressed message shape (`whatsapp:+E164`, `rcs:agent_id`)."
  @spec build(map()) :: {:ok, map()} | {:error, map()}
  def build(%{"To" => to, "From" => from} = p) do
    with {:ok, ch} <- channel(to), {:ok, ch2} <- channel(from), :ok <- same(ch, ch2) do
      {:ok, %{"sid" => "SM" <> String.duplicate("0", 32), "channel" => ch, "to" => to, "from" => from,
              "body" => Map.get(p, "Body"), "content_sid" => Map.get(p, "ContentSid"),
              "status" => "queued", "account_sid" => "AC" <> String.duplicate("0", 32)}}
    else
      {:error, m} -> {:error, %{"code" => 21211, "message" => m, "status" => 400}}
    end
  end
  def build(_), do: {:error, %{"code" => 21604, "message" => "Missing To/From", "status" => 400}}

  def channel("whatsapp:+" <> n),
    do: if(Regex.match?(~r/\A[1-9]\d{7,14}\z/, n), do: {:ok, "whatsapp"}, else: {:error, "bad whatsapp number"})
  def channel("rcs:" <> a) when a != "",
    do: if(Regex.match?(~r/[[:cntrl:]]/u, a), do: {:error, "bad rcs agent id"}, else: {:ok, "rcs"})
  def channel(x), do: {:error, "unsupported channel address #{inspect(x)}"}

  defp same(a, a), do: :ok
  defp same(_, _), do: {:error, "To and From channels differ"}
end
