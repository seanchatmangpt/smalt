defmodule Smalt.H09.Ofac do
  @moduledoc """
  SDN-style screening: normalization, Jaro-Winkler on the full string and on token-sorted
  form, best over name+aliases. Scores are integer basis points (deterministic).
  """
  alias Smalt.H09.Vocab

  def screen(name, list, threshold_bps \\ Vocab.screen_default_threshold_bps())
      when is_binary(name) do
    q = normalize(name)

    hits =
      for e <- list,
          score = best(q, e),
          score >= threshold_bps do
        %{id: e.id, name: e.name, program: e.program, score_bps: score}
      end
      |> Enum.sort_by(&{-&1.score_bps, &1.id})

    %{status: if(hits == [], do: "clear", else: "potential_match"), hits: hits}
  end

  defp best(q, e) do
    [e.name | e[:aliases] || []]
    |> Enum.map(fn n ->
      c = normalize(n)
      round(max(jw(q, c), jw(sort_tokens(q), sort_tokens(c))) * 10_000)
    end)
    |> Enum.max()
  end

  def normalize(s) do
    s
    |> String.normalize(:nfd)
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.upcase()
    |> String.replace(~r/[^A-Z0-9 ]/, " ")
    |> String.split(" ", trim: true)
    |> Enum.join(" ")
  end

  defp sort_tokens(s), do: s |> String.split(" ", trim: true) |> Enum.sort() |> Enum.join(" ")

  def jaro("", _), do: 0.0
  def jaro(_, ""), do: 0.0
  def jaro(s, s), do: 1.0

  def jaro(s1, s2) do
    a = String.graphemes(s1) |> List.to_tuple()
    b = String.graphemes(s2) |> List.to_tuple()
    la = tuple_size(a)
    lb = tuple_size(b)
    w = max(div(max(la, lb), 2) - 1, 0)

    {used, a_idx} =
      Enum.reduce(0..(la - 1), {MapSet.new(), []}, fn i, {used, acc} ->
        lo = max(0, i - w)
        hi = min(i + w, lb - 1)

        found =
          if lo > hi,
            do: nil,
            else: Enum.find(lo..hi, fn j -> not MapSet.member?(used, j) and elem(b, j) == elem(a, i) end)

        case found do
          nil -> {used, acc}
          j -> {MapSet.put(used, j), [i | acc]}
        end
      end)

    m = MapSet.size(used)

    if m == 0 do
      0.0
    else
      am = a_idx |> Enum.reverse() |> Enum.map(&elem(a, &1))
      bm = used |> Enum.sort() |> Enum.map(&elem(b, &1))
      t = am |> Enum.zip(bm) |> Enum.count(fn {x, y} -> x != y end) |> div(2)
      (m / la + m / lb + (m - t) / m) / 3
    end
  end

  def jw(s1, s2) do
    j = jaro(s1, s2)

    if j > 0.7 do
      l =
        Enum.zip(String.graphemes(s1), String.graphemes(s2))
        |> Enum.take(4)
        |> Enum.take_while(fn {x, y} -> x == y end)
        |> length()

      j + l * 0.1 * (1 - j)
    else
      j
    end
  end
end
