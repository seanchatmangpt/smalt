defmodule Smalt.Treasury.Rails do
  @moduledoc """
  Rail selection. Limits (cents): FedNow 100_000_000 (default network cap $1M),
  RTP 1_000_000_00 ($1M). Same-day ACH 100_000_000 ($1M). Fedwire unbounded.
  """
  @fednow_max 100_000_000
  @rtp_max 100_000_000
  @sdach_max 100_000_000

  @doc "opts: amount_cents, speed (:instant|:same_day|:standard|:high_value), fednow? rtp? (receiver participation), cutoff_passed?"
  def select(%{amount_cents: a} = o) when is_integer(a) and a > 0 do
    speed = Map.get(o, :speed, :standard)

    cond do
      speed == :instant and a <= @fednow_max and Map.get(o, :fednow?, true) -> {:ok, :fednow}
      speed == :instant and a <= @rtp_max and Map.get(o, :rtp?, true) -> {:ok, :rtp}
      speed in [:instant, :same_day] and a <= @sdach_max and not Map.get(o, :cutoff_passed?, false) and speed == :same_day -> {:ok, :same_day_ach}
      speed in [:instant, :same_day, :high_value] -> {:ok, :fedwire}
      a <= @sdach_max -> {:ok, :ach}
      true -> {:ok, :fedwire}
    end
  end

  def select(_), do: {:error, :invalid_amount}
end
