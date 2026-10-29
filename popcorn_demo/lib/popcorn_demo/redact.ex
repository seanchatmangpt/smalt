defmodule PopcornDemo.Redact do
  @moduledoc """
  Shared receipt-redaction for popcorn_demo surfaces.

  One canonical implementation of the receipt-hygiene law: JWT-shaped
  substrings (`eyJ…`) collapse to `eyJ<redacted>`, non-binary inputs are
  inspected first, and the final fragment is capped at 120 chars — so
  bearer tokens never reach receipts/logs even when a FAIL path embeds a
  response body or a raw token.
  """

  @jwt_pattern ~r/eyJ[A-Za-z0-9_-]{10,}/
  @max 120

  @doc """
  Redacts JWT-shaped substrings and caps the fragment at #{@max} chars.
  Non-binary input is `inspect/1`-ed first, so any term can be passed safely.
  """
  def fragment(term)

  def fragment(str) when is_binary(str) do
    str
    |> String.replace(@jwt_pattern, "eyJ<redacted>")
    |> String.slice(0, @max)
  end

  def fragment(other), do: other |> inspect() |> fragment()
end
