defmodule Smalt.TrustProfile.JCS do
  @moduledoc """
  RFC 8785 (JCS) canonical JSON -- extracted verbatim from Smalt.TrustProfile
  along the JCS canonicalization fence (T10 tail split, v26.10.29 r10d).
  Wire-pinned: same refusals, same byte output for every input.
  """

  ## JCS canonicalization (RFC 8785 subset) — see moduledoc.

  @doc """
  RFC 8785 (JCS) canonical JSON of a decoded-JSON-shaped value. Refuses,
  typed: integers with `|n| >= 2^53` and non-finite floats.
  """
  @spec jcs(term) ::
          {:ok, String.t()} | {:error, {:non_canonical_number, term} | {:bad_json_value, term}}
  def jcs(value)

  def jcs(nil), do: {:ok, "null"}
  def jcs(true), do: {:ok, "true"}
  def jcs(false), do: {:ok, "false"}
  def jcs(v) when is_integer(v), do: canonical_integer(v)
  def jcs(v) when is_float(v), do: canonical_float(v)

  def jcs(v) when is_binary(v) do
    # JCS input is I-JSON: strings are Unicode. A raw binary with invalid
    # UTF-8 is outside the domain — refuse typed. Silent byte-dropping (the
    # `for <<c::utf8 <- s>>` comprehension skips invalid sequences) produced
    # lossy, non-round-trippable "canonical" output AND a canonicalization
    # collision: two distinct envelopes (e.g. hostile :audience binaries
    # differing only in invalid bytes) signed to identical documents
    # (witnessed: jcs(<<0xFF>>) -> "\"\"", jcs("ok" <> <<0xFF>>) -> "\"ok\"",
    # trust-profile lens-9 cycle-3, tmp/tp_utf8_probe.exs).
    if String.valid?(v) do
      {:ok, escape_string(v)}
    else
      {:error, {:bad_json_value, v}}
    end
  end

  def jcs(v) when is_list(v) do
    with {:ok, parts} <-
           Enum.reduce_while(v, {:ok, []}, fn child, {:ok, acc} ->
             case jcs(child) do
               {:ok, s} -> {:cont, {:ok, [s | acc]}}
               {:error, _} = err -> {:halt, err}
             end
           end) do
      {:ok, "[" <> Enum.join(Enum.reverse(parts), ",") <> "]"}
    end
  end

  def jcs(v) when is_map(v) do
    with {:ok, pairs} <- sorted_pairs(v) do
      {:ok,
       "{" <> Enum.map_join(pairs, ",", fn {k, vj} -> escape_string(k) <> ":" <> vj end) <> "}"}
    end
  end

  def jcs(other), do: {:error, {:bad_json_value, other}}

  defp sorted_pairs(map) do
    entries =
      for {k, val} <- map do
        if is_binary(k) and String.valid?(k) do
          {k, val}
        else
          throw({:bad_json_value, k})
        end
      end

    sorted =
      Enum.sort_by(entries, fn {k, _} -> :unicode.characters_to_binary(k, :utf8, :utf16) end)

    Enum.reduce_while(sorted, {:ok, []}, fn {k, val}, {:ok, acc} ->
      case jcs(val) do
        {:ok, vj} -> {:cont, {:ok, [{k, vj} | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      error -> error
    end
  catch
    {:bad_json_value, k} -> {:error, {:bad_json_value, k}}
  end

  # 2^53 - 1, I-JSON / RFC 8785 §3.2.2.3
  @max_safe_integer 9_007_199_254_740_991

  defp canonical_integer(n) when abs(n) <= @max_safe_integer, do: {:ok, Integer.to_string(n)}
  defp canonical_integer(n), do: {:error, {:non_canonical_number, n}}

  defp canonical_float(f) do
    cond do
      not is_float(f) ->
        {:error, {:non_canonical_number, f}}

      f == 0.0 ->
        {:ok, "0"}

      # ECMAScript fixed notation window: 1e-6 <= |f| < 1e21
      abs(f) < 1.0e21 and abs(f) >= 1.0e-6 ->
        {:ok, shortest_fixed(f)}

      true ->
        {:ok, shortest_scientific(f)}
    end
  end

  # Shortest round-trip digits from Float.to_string/1, re-rendered in the form
  # ECMAScript Number::toString mandates for the fixed window (integral values
  # in plain integer notation — e.g. 1.0e16 -> "10000000000000000", not
  # "1.0e16" — and fractional values point-expanded, e.g. 1.2e-6 -> "0.0000012").
  defp shortest_fixed(f) do
    case Float.to_string(f) do
      fixed when is_binary(fixed) ->
        case String.split(fixed, "e") do
          [mantissa] ->
            trim_integral(mantissa)

          [mantissa, exp] ->
            {digits, int_len, neg} = expand_to_digits(mantissa)
            # strip trailing zeros of the digit string (right of the point):
            # e.g. "1.0e-6" digits "10" -> "1" so the output is "0.000001",
            # never "0.0000010"
            digits = String.trim_trailing(digits, "0")
            digits = if digits == "", do: "0", else: digits

            place_point({digits, int_len, neg}, String.to_integer(exp))
        end
    end
  end

  # ECMAScript scientific form: "1e+21", "1.5e-7", "-2.5e+20" — mantissa has a
  # single nonzero leading digit (no trailing ".0"), explicit sign on exponent.
  defp shortest_scientific(f) do
    case Float.to_string(f) do
      sci when is_binary(sci) ->
        case String.split(sci, "e") do
          [mantissa, exp] ->
            {digits, neg} = split_sign(mantissa)
            {int, frac} = split_dot(digits)
            frac = String.trim_trailing(frac, "0")

            mant =
              if frac == "",
                do: String.trim_leading(int, "0"),
                else: String.trim_leading(int, "0") <> "." <> frac

            expn = String.to_integer(exp)
            sign = if expn < 0, do: "-", else: "+"

            if(neg, do: "-", else: "") <> mant <> "e" <> sign <> Integer.to_string(abs(expn))

          [mantissa] ->
            trim_integral(mantissa)
        end
    end
  end

  defp trim_integral(mantissa) do
    case split_dot(mantissa) do
      {int, "0"} -> int
      {_int, _frac} -> mantissa
    end
  end

  # "1.5" -> {"15", 1}: digit string plus the count of digits left of the mantissa's point
  defp expand_to_digits(mantissa) do
    {digits, neg} = split_sign(mantissa)
    {int, frac} = split_dot(digits)
    {int <> frac, String.length(int), neg}
  end

  # digits * 10^(exp - (int_len-1)); the decimal point sits int_len + exp digits in
  defp place_point({digits, int_len, neg}, exp) do
    point = int_len + exp
    len = String.length(digits)

    body =
      cond do
        point <= 0 -> "0." <> String.duplicate("0", -point) <> digits
        point >= len -> String.pad_trailing(digits, point, "0")
        true -> String.slice(digits, 0, point) <> "." <> String.slice(digits, point, len - point)
      end

    if(neg, do: "-", else: "") <> body
  end

  defp split_sign(m), do: {String.trim_leading(m, "-"), String.starts_with?(m, "-")}
  defp split_dot(digits), do: String.split(digits, ".", parts: 2) |> list_pair()

  defp list_pair([a]), do: {a, ""}
  defp list_pair([a, b]), do: {a, b}

  # JCS string escaping operates on Unicode CODE POINTS (RFC 8785 §3.2.2.2),
  # never graphemes: grapheme clustering merges `"` or `\` with a following
  # combining mark into one grapheme, which used to fall to the catch-all and
  # be emitted RAW — dropping a required escape and yielding non-canonical,
  # even invalid, JSON (lens-2 cycle-3, 10000-doc node-oracle catch).
  defp escape_string(s) when is_binary(s) do
    "\"" <> for(<<c::utf8 <- s>>, into: "", do: escape_codepoint(c)) <> "\""
  end

  defp escape_codepoint(0x22), do: "\\\""
  defp escape_codepoint(0x5C), do: "\\\\"

  defp escape_codepoint(c) when c < 0x20 do
    case c do
      0x08 -> "\\b"
      0x09 -> "\\t"
      0x0A -> "\\n"
      0x0C -> "\\f"
      0x0D -> "\\r"
      _ -> "\\u" <> hex4(c)
    end
  end

  defp escape_codepoint(c), do: <<c::utf8>>

  defp hex4(c) do
    c |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(4, "0")
  end
end
