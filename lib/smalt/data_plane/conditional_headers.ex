defmodule Smalt.DataPlane.ConditionalHeaders do
  @moduledoc """
  Shared If-Match / If-None-Match precondition evaluator.

  `evaluate/2` inspects a request header map (string keys, case-insensitive)
  against the current entity tag and returns:

    * `:proceed`
    * `{:halt, 412}` — If-Match present and does not match
    * `{:halt, 304}` — If-None-Match present and matches (GET semantics)
  """

  @spec evaluate(map(), String.t() | nil) :: :proceed | {:halt, 412 | 304}
  def evaluate(headers, current_etag)

  def evaluate(headers, current_etag) when is_map(headers) do
    if_match = header(headers, "if-match")
    if_none_match = header(headers, "if-none-match")

    cond do
      if_match != nil ->
        if etag_matches?(if_match, current_etag), do: :proceed, else: {:halt, 412}

      if_none_match != nil ->
        if etag_matches?(if_none_match, current_etag), do: {:halt, 304}, else: :proceed

      true ->
        :proceed
    end
  end

  def evaluate(_headers, _current_etag), do: :proceed

  @doc """
  Case-insensitive header lookup over a plain string-keyed map.
  """
  @spec header(map(), String.t()) :: String.t() | nil
  def header(headers, name) when is_map(headers) and is_binary(name) do
    lower = String.downcase(name)

    Enum.find_value(headers, fn {k, v} ->
      if is_binary(k) and String.downcase(k) == lower, do: to_string(v)
    end)
  end

  defp etag_matches?(header_value, current_etag) do
    header_value
    |> to_string()
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.any?(fn candidate ->
      candidate == "*" or candidate == current_etag or
        candidate == strip_quotes(current_etag)
    end)
  end

  defp strip_quotes(nil), do: nil
  defp strip_quotes(etag), do: String.trim(etag, "\"")
end
