defmodule Smalt.ServengineSim.AiElements.TokenCacheSimTest do
  use ExUnit.Case, async: true

  alias Smalt.ServengineSim.AiElements.TokenCacheSim

  describe "validate_metadata_request/1" do
    test "accepts canonical GCE metadata URL with Metadata-Flavor: Google" do
      req = %{
        url: TokenCacheSim.metadata_url(),
        headers: [{"Metadata-Flavor", "Google"}]
      }

      assert :ok == TokenCacheSim.validate_metadata_request(req)
    end

    test "accepts case-insensitive header key" do
      req = %{
        url: TokenCacheSim.metadata_url(),
        headers: %{"metadata-flavor" => "Google"}
      }

      assert :ok == TokenCacheSim.validate_metadata_request(req)
    end

    test "rejects missing or invalid Metadata-Flavor header" do
      assert {:error, :missing_metadata_flavor} ==
               TokenCacheSim.validate_metadata_request(%{
                 url: TokenCacheSim.metadata_url(),
                 headers: []
               })

      assert {:error, {:invalid_metadata_flavor, "AWS"}} ==
               TokenCacheSim.validate_metadata_request(%{
                 url: TokenCacheSim.metadata_url(),
                 headers: [{"Metadata-Flavor", "AWS"}]
               })
    end

    test "rejects non-GCE metadata URLs" do
      assert {:error, {:invalid_metadata_url, "http://169.254.169.254/latest/meta-data/"}} ==
               TokenCacheSim.validate_metadata_request(%{
                 url: "http://169.254.169.254/latest/meta-data/",
                 headers: [{"Metadata-Flavor", "Google"}]
               })
    end
  end

  describe "caching and pre-expiry refresh" do
    test "fetches once on cold start, serves cache hits until pre-expiry window, then refreshes" do
      {:ok, pid} =
        TokenCacheSim.start_link(
          now_ms: 1_700_000_000_000,
          default_expires_in_sec: 3600,
          refresh_margin_ms: 60_000
        )

      # Cold fetch
      assert {:ok, "ya29.sim-vertex-token-1"} = TokenCacheSim.get_token(pid)
      assert {:ok, "Bearer ya29.sim-vertex-token-1"} = TokenCacheSim.authorization_header(pid)

      # Advance to 1 ms before the pre-expiry refresh window (3600s - 60s = 3540s)
      TokenCacheSim.advance_clock(pid, 3_540_000 - 1)
      assert {:ok, "ya29.sim-vertex-token-1"} = TokenCacheSim.get_token(pid)

      stats = TokenCacheSim.stats(pid)
      assert stats.metadata_fetches == 1
      assert stats.cache_hits == 2
      assert stats.pre_expiry_refreshes == 0

      # Cross into the pre-expiry window (still 60s before actual expiry)
      TokenCacheSim.advance_clock(pid, 1)
      assert {:ok, "ya29.sim-vertex-token-2"} = TokenCacheSim.get_token(pid)

      stats = TokenCacheSim.stats(pid)
      assert stats.metadata_fetches == 2
      assert stats.pre_expiry_refreshes == 1
      assert stats.hard_expiry_refreshes == 0

      # Subsequent call is a cache hit on the refreshed token
      assert {:ok, "ya29.sim-vertex-token-2"} = TokenCacheSim.get_token(pid)
      assert TokenCacheSim.stats(pid).cache_hits == 3
    end

    test "falls back to still-unexpired token on transient pre-expiry refresh error" do
      {:ok, pid} =
        TokenCacheSim.start_link(
          now_ms: 1_700_000_000_000,
          default_expires_in_sec: 600,
          refresh_margin_ms: 60_000,
          stale_on_error?: true
        )

      assert {:ok, "ya29.sim-vertex-token-1"} = TokenCacheSim.get_token(pid)

      # Enter pre-expiry window and simulate transient metadata outage
      TokenCacheSim.advance_clock(pid, 540_000)
      TokenCacheSim.set_fetcher(pid, fn _req -> {:error, :metadata_timeout} end)

      assert {:ok, "ya29.sim-vertex-token-1"} = TokenCacheSim.get_token(pid)

      stats = TokenCacheSim.stats(pid)
      assert stats.errors == 1
      assert stats.stale_fallbacks == 1
      assert stats.pre_expiry_refreshes == 1
    end

    test "refuses to serve hard-expired token when metadata refresh fails, and recovers after" do
      {:ok, pid} =
        TokenCacheSim.start_link(
          now_ms: 1_700_000_000_000,
          default_expires_in_sec: 600,
          refresh_margin_ms: 60_000,
          stale_on_error?: true
        )

      assert {:ok, "ya29.sim-vertex-token-1"} = TokenCacheSim.get_token(pid)

      # Advance past hard expiry (600s) and fail metadata fetch
      TokenCacheSim.advance_clock(pid, 600_000)
      TokenCacheSim.set_fetcher(pid, fn _req -> {:error, :econnrefused} end)

      assert {:error, :econnrefused} = TokenCacheSim.get_token(pid)
      assert TokenCacheSim.cached_token(pid) == nil

      stats = TokenCacheSim.stats(pid)
      assert stats.hard_expiry_refreshes == 1
      assert stats.stale_fallbacks == 0
      assert stats.errors == 1

      # Metadata server recovers
      TokenCacheSim.set_fetcher(pid, fn %{seq: seq} ->
        {:ok, %{"access_token" => "ya29.recovered-#{seq}", "expires_in" => 3600}}
      end)

      assert {:ok, "ya29.recovered-3"} = TokenCacheSim.get_token(pid)
    end

    test "returns error during pre-expiry failure when stale_on_error? is false" do
      {:ok, pid} =
        TokenCacheSim.start_link(
          now_ms: 1_700_000_000_000,
          default_expires_in_sec: 600,
          refresh_margin_ms: 60_000,
          stale_on_error?: false
        )

      assert {:ok, "ya29.sim-vertex-token-1"} = TokenCacheSim.get_token(pid)

      TokenCacheSim.advance_clock(pid, 550_000)
      TokenCacheSim.set_fetcher(pid, fn _req -> {:error, :metadata_503} end)

      assert {:error, :metadata_503} = TokenCacheSim.get_token(pid)
      assert TokenCacheSim.stats(pid).stale_fallbacks == 0
    end
  end

  describe "invalidation, header enforcement, and concurrency" do
    test "invalidate/1 forces a fresh metadata fetch on next get_token/1" do
      {:ok, pid} = TokenCacheSim.start_link(now_ms: 1_700_000_000_000)

      assert {:ok, "ya29.sim-vertex-token-1"} = TokenCacheSim.get_token(pid)
      assert :ok = TokenCacheSim.invalidate(pid)
      assert TokenCacheSim.cached_token(pid) == nil
      assert {:ok, "ya29.sim-vertex-token-2"} = TokenCacheSim.get_token(pid)

      stats = TokenCacheSim.stats(pid)
      assert stats.invalidations == 1
      assert stats.metadata_fetches == 2
    end

    test "fails closed if configured without Metadata-Flavor: Google header" do
      {:ok, pid} = TokenCacheSim.start_link(headers: [])
      assert {:error, :missing_metadata_flavor} = TokenCacheSim.get_token(pid)
    end

    test "rejects malformed token payloads from metadata server" do
      {:ok, pid} =
        TokenCacheSim.start_link(
          fetcher: fn _req -> {:ok, %{"access_token" => "", "expires_in" => 0}} end
        )

      assert {:error, {:invalid_token_payload, _}} = TokenCacheSim.get_token(pid)
    end

    test "concurrent callers on a cold cache trigger only a single metadata fetch" do
      {:ok, pid} = TokenCacheSim.start_link(now_ms: 1_700_000_000_000)

      results =
        1..16
        |> Task.async_stream(fn _ -> TokenCacheSim.get_token(pid) end, max_concurrency: 16)
        |> Enum.map(fn {:ok, res} -> res end)

      assert Enum.all?(results, &(&1 == {:ok, "ya29.sim-vertex-token-1"}))

      stats = TokenCacheSim.stats(pid)
      assert stats.metadata_fetches == 1
      assert stats.cache_hits == 15
    end
  end
end
