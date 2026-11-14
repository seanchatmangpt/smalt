defmodule Smalt.Erp.Money do
  @moduledoc "Amount -> integer cents. No float arithmetic on money: floats go via shortest repr."

  @spec to_cents(term()) :: {:ok, integer()} | {:error, :bad_amount}
  def to_cents(n) when is_integer(n), do: {:ok, n * 100}
  def to_cents(n) when is_float(n), do: to_cents(Float.to_string(n))
  def to_cents(nil), do: {:ok, 0}

  def to_cents(s) when is_binary(s) do
    case Regex.run(~r/^(-)?(\d+)(?:\.(\d{1,2}))?$/, String.trim(s)) do
      [_, sign, whole, frac] -> {:ok, signed(sign, whole, frac)}
      [_, sign, whole] -> {:ok, signed(sign, whole, "")}
      _ -> {:error, :bad_amount}
    end
  end

  def to_cents(_), do: {:error, :bad_amount}

  defp signed(sign, whole, frac) do
    c = String.to_integer(whole) * 100 + String.to_integer(String.pad_trailing(frac, 2, "0"))
    if sign == "-", do: -c, else: c
  end

  @spec fmt(integer()) :: String.t()
  def fmt(c) do
    s = if c < 0, do: "-", else: ""
    a = abs(c)
    s <> Integer.to_string(div(a, 100)) <> "." <> String.pad_leading(Integer.to_string(rem(a, 100)), 2, "0")
  end
end
