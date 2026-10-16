defmodule SmaltProxy.Namespace do
  @moduledoc """
  Per-lane prefix algebra (WO v26.10.15/23 §2 contract, standalone copy).

  `<lane> ::= [a-z0-9]{1,8}`; `prefix = "s" <> lane <> "-"`.
  Lane code addresses resources as `prefix <> name` on every stateful surface.
  This module owns the grammar + prefix scans so no caller hand-concatenates.

  Scan semantics mirror `Smalt.Store.list_prefix/2`: a lane's view is exactly
  the keys `k` with `String.starts_with?(k, prefix(lane))`. The grammar
  `[a-z0-9]{1,8}` guarantees lane prefixes are mutually non-ambiguous at the
  `-` delimiter (a lane string never contains `-`, so `s<lane>-` can never be
  a proper prefix of another lane's `s<lane'>-` unless lane == lane').
  """

  @lane_max 8

  @doc "Validates `<lane> ::= [a-z0-9]{1,8}`."
  @spec valid_lane?(term) :: boolean
  def valid_lane?(lane) when is_binary(lane) and byte_size(lane) in 1..@lane_max do
    Regex.match?(~r/\A[a-z0-9]{1,8}\z/, lane)
  end

  def valid_lane?(_), do: false

  @doc "Returns the lane prefix `\"s<lane>-\"` or raises on invalid lane."
  @spec prefix(String.t()) :: String.t()
  def prefix(lane) do
    unless valid_lane?(lane), do: raise(ArgumentError, "invalid lane: #{inspect(lane)}")
    "s" <> lane <> "-"
  end

  @doc """
  Stamps a resource name into the lane namespace: `prefix <> name`.
  Mirrors WO-01 §3 / WO-23 §2 contract (Store keys, SB queues, EH hubs,
  Cosmos db/container, blob containers).
  """
  @spec stamp(String.t(), String.t()) :: String.t()
  def stamp(lane, name) when is_binary(name), do: prefix(lane) <> name

  @doc """
  Exclusive upper bound of the lane's key range (`prefix <> <<0xFF>>`,
  matching the `list_prefix/2` bounded-scan composition).
  """
  @spec scan_bound(String.t()) :: String.t()
  def scan_bound(lane), do: prefix(lane) <> <<0xFF>>

  @doc """
  The predicate `list_prefix(table, prefix(lane))` implements: `key` is in
  lane's view iff it starts with `s<lane>-`.
  """
  @spec owns?(String.t(), String.t()) :: boolean
  def owns?(lane, key) when is_binary(key), do: String.starts_with?(key, prefix(lane))

  @doc """
  True iff two distinct lanes' namespaces are provably disjoint: for valid
  lanes a != b, no key can be in both views. Follows from the `-`-free lane
  grammar (see moduledoc).
  """
  @spec disjoint?(String.t(), String.t()) :: boolean
  def disjoint?(a, b) do
    pa = prefix(a)
    pb = prefix(b)
    pa != pb and not String.starts_with?(pa, pb) and not String.starts_with?(pb, pa)
  end
end
