defmodule Smalt.Auth.Sas do
  @moduledoc """
  Azure Blob service SAS (Shared Access Signature) query-token verification
  (GAP-AUD1-03).

  Verifies a service SAS token presented as query parameters (`sp`, `st`,
  `se`, `spr`, `sv`, `sr`, `sig`) against the storage account key, per the
  real Azure service-SAS string-to-sign (version 2018-11-09 shape):

      sp \n st \n se \n canonicalizedresource \n signedidentifier \n
      sip \n spr \n sv \n sr \n rscc \n rscd \n rsce \n rscl \n rsct

  The canonicalized resource is the lowercased `/blob/{account}/{container}`
  (plus `/{blob}` when the request names a blob) taken from the request
  path — never from the token, so a token minted for one container cannot be
  replayed against another.

  Fail-closed: a missing account key, a bad signature, an unparsable or
  lapsed expiry each refuse. The egress router's `blob_route_guarded/2`
  maps `:bad_signature`/`:no_key`/`:malformed` to 401 with the KD-15-
  enriched `WWW-Authenticate` challenge class, and a live-signature
  permission mismatch to 403 `AuthorizationPermissionMismatch`.
  """

  @valid_permissions ~w(r c w d l a p)

  @doc """
  Verifies the SAS query token on `conn`.

  Returns:

    * `{:ok, permissions}` — signed permission letters; the request is
      admitted with those permissions only (also stored in
      `conn.private[:smalt_sas_permissions]`)
    * `{:error, :not_sas}` — no `sig` query param (caller falls through to
      the x-ms-version guard, behaviour unchanged)
    * `{:error, :no_key}` — no account key configured (fail-closed)
    * `{:error, :bad_signature}`
    * `{:error, :expired}` — signed window refusal: expiry `se` in the past
      or start `st` in the future (both bounds of the signed validity window)
    * `{:error, :bad_signature}` — signature mismatch, or the signed IP
      constraint (`sip`) does not cover the request's remote IP
    * `{:error, :malformed}` — missing required params / bad base64 / bad sp
      / unparsable `st` or `sip`
  """
  @spec verify(Plug.Conn.t()) ::
          {:ok, String.t()}
          | {:error, :not_sas | :no_key | :bad_signature | :expired | :malformed}
  def verify(%Plug.Conn{} = conn) do
    params = conn.query_params

    if is_binary(params["sig"]) and params["sig"] != "" do
      verify_token(params, conn)
    else
      {:error, :not_sas}
    end
  end

  @doc """
  Maps an HTTP method to the SAS permission letter it requires:
  GET/HEAD → `r`, DELETE → `d`, PUT/POST → `w` (`authorized?/2` also accepts
  `c` for a PUT requirement — create implies create, write implies create).
  """
  def required_permission(m) when m in ["GET", "HEAD"], do: "r"
  def required_permission("DELETE"), do: "d"
  def required_permission(m) when m in ["PUT", "POST"], do: "w"

  @doc """
  True when the signed permission string `sp` covers the required letter.
  `w` implies `c` (write grants create on the blob surface).
  """
  def authorized?(sp, required) when is_binary(sp) do
    perms = MapSet.new(String.graphemes(sp))
    MapSet.member?(perms, required) or (required == "c" and MapSet.member?(perms, "w"))
  end

  @doc """
  Independent mint side for tests and tooling: builds the same
  string-to-sign the verification path builds and signs it with the given
  account key, exactly as real Azure client libraries do. Kept public so the
  wire courts can construct tokens without importing the verifier's private
  signer.
  """
  def mint(params, account_key, _opts \\ []) when is_map(params) do
    account = Map.get(params, "account", "")
    container = Map.get(params, "container", "")
    blob = Map.get(params, "blob")

    canonical = "/blob/" <> Enum.join(Enum.reject([account, container, blob], &(&1 in [nil, ""])), "/")

    sp = Map.get(params, "sp", "r")
    st = Map.get(params, "st", "")
    se = Map.get(params, "se") || raise ArgumentError, "params must include se"
    sv = Map.get(params, "sv", "2021-12-02")
    spr = Map.get(params, "spr", "https")
    sr = Map.get(params, "sr", if(container == "", do: "account", else: "c"))
    # sip (signed IP range) — signed, same slot the verifier reads
    sip = Map.get(params, "sip", "")

    string_to_sign =
      Enum.join(
        [
          sp,
          st,
          se,
          String.downcase(canonical),
          "",
          sip,
          spr,
          sv,
          sr,
          "",
          "",
          "",
          "",
          ""
        ],
        "\n"
      )

    :crypto.mac(:hmac, :sha256, account_key, string_to_sign)
    |> Base.encode64()
  end

  # -- internals ------------------------------------------------------------

  # Signature verification happens FIRST (audit A13 #3): window/IP checks only
  # run after a valid HMAC, so timing/error channels never leak window state
  # for an unsigned token.
  defp verify_token(params, conn) do
    with {:ok, key} <- account_key(),
         {:ok, sig} <- decode_sig(params["sig"]),
         :ok <- required_params(params),
         :ok <- verify_signature(key, sig, params, conn),
         :ok <- check_window(params),
         :ok <- check_signed_ip(params, conn) do
      validate_permissions(params)
    end
  end

  defp verify_signature(key, sig, params, conn) do
    canonical = canonical_resource_from_conn(conn)
    string_to_sign = build_string_to_sign(params, canonical)
    expected = Base.encode64(:crypto.mac(:hmac, :sha256, key, string_to_sign))

    if Plug.Crypto.secure_compare(expected, sig) do
      :ok
    else
      {:error, :bad_signature}
    end
  end

  defp build_string_to_sign(params, canonical_resource) do
    Enum.join(
      [
        params["sp"] || "",
        params["st"] || "",
        params["se"],
        canonical_resource,
        # signedIdentifier (container-level ACL policy id) — not modelled
        "",
        # sip (signed IP range) — signed AND enforced post-verify
        # (audit A13 #2)
        params["sip"] || "",
        params["spr"] || "",
        params["sv"] || "",
        params["sr"] || "",
        params["rscc"] || "",
        params["rscd"] || "",
        params["rsce"] || "",
        params["rscl"] || "",
        params["rsct"] || ""
      ],
      "\n"
    )
  end

  defp validate_permissions(params) do
    sp = params["sp"] || ""

    if sp != "" and Enum.all?(String.graphemes(sp), &(&1 in @valid_permissions)) do
      {:ok, sp}
    else
      {:error, :malformed}
    end
  end

  defp decode_sig(sig) do
    case Base.decode64(sig) do
      {:ok, _} -> {:ok, sig}
      :error -> {:error, :malformed}
    end
  end

  defp account_key do
    case Application.get_env(:smalt, :blob_account_key) ||
           System.get_env("SMALT_BLOB_ACCOUNT_KEY") do
      nil -> {:error, :no_key}
      key when is_binary(key) -> {:ok, key}
      _ -> {:error, :no_key}
    end
  end

  defp required_params(params) do
    if is_binary(params["se"]) and params["se"] != "" do
      :ok
    else
      {:error, :malformed}
    end
  end

  # Enforces BOTH bounds of the signed validity window (audit A13 #1): `se`
  # in the past → :expired, `st` in the future → :expired (same typed shape;
  # the router's 403 AuthorizationFailure covers window refusals either way).
  # An unparsable st is :malformed, fail-closed.
  defp check_window(params) do
    with {:ok, se, _offset} <- parse_iso(params["se"]),
         {:ok, window_start, _offset} <- parse_start(params["st"]) do
      now = DateTime.utc_now()

      if valid_window?(se, window_start, now) do
        :ok
      else
        {:error, :expired}
      end
    end
  end

  defp valid_window?(se, window_start, now) do
    se_ok = DateTime.compare(se, now) != :lt
    st_ok = is_nil(window_start) or DateTime.compare(now, window_start) in [:gt, :eq]
    se_ok and st_ok
  end

  defp parse_iso(value) when is_binary(value) and value != "" do
    case DateTime.from_iso8601(value) do
      {:ok, dt, offset} -> {:ok, dt, offset}
      {:error, _reason} -> {:error, :malformed}
    end
  end

  defp parse_iso(_), do: {:error, :malformed}

  # st is optional (empty == no signed start bound).
  defp parse_start(st) when is_binary(st) and st != "", do: parse_iso(st)
  defp parse_start(_), do: {:ok, nil, 0}

  # Enforces the signed IP constraint `sip` (audit A13 #2) AFTER signature
  # verification. Supported syntax: comma-separated single IPv4 addresses or
  # IPv4 CIDR ranges (a.b.c.d/nn). The signature still folds the RAW `sip`
  # string in, so a token minted with an IPv6 range still fails here on
  # comparison rather than being accepted — limitation documented, no
  # dependencies added.
  defp check_signed_ip(params, conn) do
    case params["sip"] do
      sip when is_binary(sip) and sip != "" ->
        remote = conn.remote_ip

        if Enum.any?(String.split(sip, ","), &(ip_in_range?(remote, &1))) do
          :ok
        else
          {:error, :bad_signature}
        end

      _ ->
        :ok
    end
  end

  defp ip_in_range?(remote, range) do
    range = String.trim(range)

    case String.split(range, "/", parts: 2) do
      [ip] -> parse_ipv4(ip) == {:ok, remote}
      [ip, prefix] -> cidr_match?(remote, ip, prefix)
      _ -> false
    end
  end

  defp parse_ipv4(s) when is_binary(s) do
    case String.split(s, ".") do
      [a, b, c, d] ->
        octets = [a, b, c, d] |> Enum.map(&Integer.parse/1) |> Enum.map(&elem(&1, 0))

        if length(octets) == 4 and Enum.all?(octets, &(&1 in 0..255)) and
             Enum.all?(String.split(s, "."), &(Regex.match?(~r/^\d+$/, &1))) do
          {:ok, List.to_tuple(octets)}
        else
          :error
        end

      _ ->
        :error
    end
  end

  defp parse_ipv4(_), do: :error

  defp cidr_match?(remote, ip, prefix) do
    with {:ok, base} <- parse_ipv4(ip),
         {p, ""} <- Integer.parse(prefix),
         true <- p in 0..32,
         {:ok, mask} <- cidr_mask(p) do
      :erlang.band(ipv4_to_int(base), mask) == :erlang.band(ipv4_to_int(remote), mask)
    else
      _ -> false
    end
  end

  defp cidr_mask(0), do: {:ok, 0}
  defp cidr_mask(p) when p in 1..32, do: {:ok, :erlang.band(:erlang.bsl(0xFFFFFFFF, 32 - p), 0xFFFFFFFF)}
  defp ipv4_to_int({a, b, c, d}), do: a * 16_777_216 + b * 65_536 + c * 256 + d

  defp canonical_resource_from_conn(conn) do
    "/blob/" <>
      (conn.path_info |> Enum.map(&(&1 |> URI.decode() |> String.downcase())) |> Enum.join("/"))
  end
end
