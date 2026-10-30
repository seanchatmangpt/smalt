defmodule Smalt.Identity.EntraToken do
  @moduledoc """
  Entra JWT verification for the Azure Cache Entra-ID AUTH path (lane S3,
  r16, task (c)) and for courts proving the MSI/ACA mint
  (`Smalt.Identity.AcaIdentity`).

  The real Azure Cache for Redis Entra mechanism: the client obtains an
  Entra access token for the `https://redis.azure.com/` audience (workload
  identity / managed identity / interactive user), then authenticates the
  redis connection with `AUTH <oid> <token>` (2-arg) — or the combined
  `AUTH <user>=<token>` form. `Smalt.DataPlane.RedisWire.Conn` routes a
  JWT-shaped AUTH password here instead of the legacy access-key path.

  Signature verification is mode-gated through `Smalt.Auth.StsKey.signer/0`
  (RS256 by default, legacy HS256 dev mode respected) — a token is admitted
  only when it verifies under the SAME key/mode the emulator's STS mints
  with. Claims law: `exp` in the future, `nbf` in the past (with clock
  skew), and `aud` covering the required audience.
  """

  @default_skew_seconds 60
  @redis_audience_default "https://redis.azure.com/"
  @redis_audiences_default ["https://redis.azure.com/", "https://redis.azure.com"]

  # ------------------------------------------------------------------
  # Shape test (routing only — NEVER admission)
  # ------------------------------------------------------------------

  @doc """
  True when `token` has the JWT shape: three dot-separated base64url
  segments, each non-empty. ROUTING test for the wire's AUTH clause, not
  admission (admission is `verify/2`).
  """
  def jwt?(token) when is_binary(token) do
    case String.split(token, ".", parts: 3) do
      [h, p, s] -> h != "" and p != "" and s != "" and base64url?(h) and base64url?(p) and base64url?(s)
      _ -> false
    end
  end

  def jwt?(_), do: false

  defp base64url?(seg) do
    case Base.url_decode64(seg, padding: false) do
      {:ok, _} -> true
      :error -> false
    end
  end

  # ------------------------------------------------------------------
  # Verify
  # ------------------------------------------------------------------

  @doc """
  Verifies signature + claims of an Entra-shaped JWT minted by the emulator
  STS. `opts`:
    * `:aud`   - required audience (string or list). No default: callers
      name the resource they admit.
    * `:skew`  - clock-skew seconds for exp/nbf (default 60).
    * `:now`   - override the current unix second (courts).

  Returns `{:ok, claims}` or `{:error, :malformed | :bad_signature |
  :expired | :not_yet_valid | :bad_audience}`.
  """
  def verify(token, opts \\ []) when is_binary(token) do
    now = Keyword.get(opts, :now) || System.system_time(:second)
    skew = Keyword.get(opts, :skew, @default_skew_seconds)

    with {:ok, claims} <- signature_ok?(token),
         :ok <- times_ok?(claims, now, skew),
         :ok <- audience_ok?(claims, Keyword.fetch(opts, :aud)) do
      {:ok, claims}
    end
  end

  # A JWT whose signature does not verify is refused BEFORE any claim
  # reason is surfaced (typed single refusal - the token bytes are
  # attacker-controlled, the reason is not).
  defp signature_ok?(token) do
    case Joken.Signer.verify(token, Smalt.Auth.StsKey.signer()) do
      # Joken.Signer.verify/2 shape varies by Joken generation: accept both.
      {:ok, claims, _jws} -> {:ok, claims}
      {:ok, claims} when is_map(claims) -> {:ok, claims}
      {:error, _reason} -> {:error, :bad_signature}
      :error -> {:error, :bad_signature}
    end
  end

  defp times_ok?(claims, now, skew) do
    cond do
      not time_claim_ok?(claims["exp"], fn exp -> exp > now - skew end) ->
        {:error, :expired}

      not time_claim_ok?(claims["nbf"], fn nbf -> nbf <= now + skew end) ->
        {:error, :not_yet_valid}

      true ->
        :ok
    end
  end

  defp time_claim_ok?(nil, _pred), do: true
  defp time_claim_ok?(exp, pred) when is_integer(exp), do: pred.(exp)
  defp time_claim_ok?(_other, _pred), do: false

  defp audience_ok?(_claims, :error), do: :ok

  defp audience_ok?(claims, {:ok, required}) do
    required_list = List.wrap(required)
    token_auds = claims["aud"] |> List.wrap() |> Enum.map(&to_string/1)

    if Enum.any?(token_auds, &(&1 in required_list)) do
      :ok
    else
      {:error, :bad_audience}
    end
  end

  # ------------------------------------------------------------------
  # Redis AUTH path
  # ------------------------------------------------------------------

  @doc """
  The audiences the redis wire admits for AAD token AUTH (the real Azure
  Cache resource, with and without the trailing slash).
  """
  def redis_audiences do
    cfg = Application.get_env(:smalt, :entra_redis, [])

    case Keyword.get(cfg, :audiences) do
      list when is_list(list) and list != [] -> list
      _ -> @redis_audiences_default
    end
  end

  @doc """
  Verifies an Azure-Cache-style redis AUTH token (`<token>` from either
  AUTH wire form) against the redis audience. Returns `{:ok, claims}` or
  `{:error, reason}` — the wire maps every error class to the real Redis
  WRONGPASS refusal.
  """
  def verify_redis_auth(token, opts \\ []) when is_binary(token) do
    opts = Keyword.put_new(opts, :aud, redis_audiences())
    verify(token, opts)
  end

  @doc "The default redis audience (real Azure Cache resource)."
  def redis_audience_default, do: @redis_audience_default
end
