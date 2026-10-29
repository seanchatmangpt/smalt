defmodule Smalt.WebPubSub.Token do
  @moduledoc """
  Client access token mint/verify for the Web PubSub face (AZ-5).

  Real Azure Web PubSub client access URLs carry a JWT whose claims encode
  the principal (`sub` = userId) and its permissions as role claims
  (`webpubsub.role`: `webpubsub.joinLeaveGroup.<group>`,
  `webpubsub.sendToGroup.<group>`, or the all-groups wildcards
  `webpubsub.joinLeaveGroup` / `webpubsub.sendToGroup`) — cite
  https://learn.microsoft.com/rest/api/webpubsub/ (GetClientAccessToken /
  generateToken) and
  https://learn.microsoft.com/azure/azure-web-pubsub/websocket-client-protocol
  (permission model). The emulator mints HS256 (dev access key from config,
  same class as the real service's connection-string access key).

  `# KD-COVERS: KD-166` — token mint/verify is in-module for the Web PubSub
  face; the subprotocol divergence the row registers is covered in
  `Smalt.WebPubSub.Socket`.
  """

  @audience_prefix "/webpubsub/hubs/"
  @role_claim "webpubsub.role"

  # EXPL-4 F1: claims whose PRESENCE is mandatory — verify/2 fails closed
  # when any is absent (joken skips validation for absent claims).
  @essential_claims ["aud", "nbf", "exp", "sub"]

  @doc """
  Mints an HS256 client access JWT for `hub` as `user_id` with `roles`.
  Real-shape claims: `aud` = hub client path, `sub` = userId,
  `webpubsub.role` = roles list. `exp` 1h (real service default).
  """
  @spec mint(String.t(), String.t(), [String.t()]) :: String.t()
  def mint(hub, user_id, roles) when is_binary(hub) and is_list(roles) do
    now = System.system_time(:second)

    claims = %{
      "aud" => @audience_prefix <> hub,
      "sub" => user_id,
      @role_claim => roles,
      "exp" => now + 3_600,
      "nbf" => now - 60
    }

    {:ok, token} = Joken.Signer.sign(claims, Joken.Signer.create("HS256", access_key()))
    token
  end

  @doc "Verifies a client access JWT; returns {:ok, user_id, roles} | :error."
  @spec verify(String.t(), String.t()) :: {:ok, String.t(), [String.t()]} | :error
  def verify(hub, token) when is_binary(hub) and is_binary(token) do
    signer = Joken.Signer.create("HS256", access_key())

    with {:ok, claims} <-
           Joken.verify_and_validate(
             build_config(hub),
             token,
             signer
           ),
           # joken 2.7 has no `essential` option on %Joken.Claim{} — absence
           # fail-closed is enforced here instead (EXPL-4 F1 semantics kept:
           # no-aud/no-exp/no-nbf/no-sub JWTs are refused, never defaulted).
           true <- Enum.all?(@essential_claims, &Map.has_key?(claims, &1)) do
      # EXPL-4 F1: `sub` is essential (build_config/1) — presence here is
      # guaranteed, never an empty-string fallback.
      {:ok, claims["sub"], normalize_roles(claims[@role_claim])}
    else
      _ -> :error
    end
  end

  # Joken token config: plain map of claim => %Joken.Claim{validate: fn}.
  # EXPL-4 F1 (fail-closed): aud/exp/nbf/sub are ALL essential — Joken skips
  # validation for claims ABSENT from the token, so a no-aud/no-exp JWT
  # verified for any hub and never expired (witnessed: expl4-wirefronts-errc).
  # Presence is enforced by the @essential_claims check after
  # verify_and_validate/3 (joken 2.7 has no essential option); `sub`
  # additionally refuses empty-string principals.
  defp build_config(hub) do
    aud = hub_audience(hub)

    %{
      "aud" => %Joken.Claim{validate: fn val, _claims, _ctx -> val == aud end},
      "nbf" => %Joken.Claim{
        validate: fn val, _c, _ctx -> is_integer(val) and val <= now_sec() end
      },
      "exp" => %Joken.Claim{
        validate: fn val, _c, _ctx -> is_integer(val) and val > now_sec() end
      },
      "sub" => %Joken.Claim{
        validate: fn val, _c, _ctx -> is_binary(val) and val != "" end
      }
    }
  end

  defp hub_audience(hub), do: @audience_prefix <> hub

  defp now_sec, do: System.system_time(:second)

  defp normalize_roles(roles) when is_list(roles), do: Enum.filter(roles, &is_binary/1)
  defp normalize_roles(_), do: []

  defp access_key do
    Application.get_env(:smalt, :web_pubsub_access_key, "smalt-wps-dev-access-key")
  end
end
