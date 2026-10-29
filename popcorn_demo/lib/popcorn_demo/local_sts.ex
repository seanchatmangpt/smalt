defmodule PopcornDemo.LocalSTS do
  @moduledoc """
  Y1 — Synthetic Identity Authority for the wasm BEAM (PRD: LocalSTS).

  `mint/1` issues a deterministic, ephemeral, client-scoped token entirely
  in-memory — ZERO network, zero `:crypto` (the wasm core runtime has no
  crypto; witnessed 2026-10-21). The token is a plain base64 envelope over a
  JWT-SHAPED payload: three dot-separated segments (header / claims /
  addendum) where the third segment is a NON-cryptographic integrity
  addendum (base64 of a checksum over the first two segments), never a real
  signature. It is an identity envelope, not an auth primitive.

  Claims (PRD shape):

      %{sub: client_scope, iat: monotonic_tick, exp: tick + 3600, scopes: [...]}

  Lease (per-PRD finite envelope):

      %{issued_tick, expires_tick, ttl_s: 3600, bounded: true}

  Determinism: same input state (client scope + scopes + tick + issuance
  counter) => same token shape, count apart. The issuance counter is a
  monotonic `:atomics` counter (in-memory, bounded to the process lifetime).

  Sub-Turing / bounded: scopes are capped at `@max_scopes` and each scope at
  `@max_scope_len` bytes; mint refuses oversized input with a typed error
  rather than truncating silently.

  `verify/1` validates structure + expiry and returns
  `{:ok, claims}` | `{:error, :expired}` | `{:error, :malformed}`.
  Fail-closed: anything that is not a byte-exact envelope round-trip is
  `:malformed`, never coerced.

  Zero-egress by construction: no `:httpc`/`Popcorn.Fetch`/sockets/`:crypto`
  anywhere (grep-verified in the lane receipt).
  """

  @ttl_s 3600
  @max_scopes 16
  @max_scope_len 64
  @max_sub_len 128

  @doc "TTL seconds for every lease (finite envelope per PRD)."
  def ttl_s, do: @ttl_s

  @doc """
  Mint a token for a client scope. `opts[:scopes]` defaults to `[]`.
  Returns `{:ok, %{token: binary, claims: map, lease: map}}` or
  `{:error, :invalid_input}` on oversized/ill-typed input.
  """
  def mint(client_scope, opts \\ []) when is_binary(client_scope) do
    scopes = Keyword.get(opts, :scopes, [])

    cond do
      not is_list(scopes) ->
        {:error, :invalid_input}

      byte_size(client_scope) > @max_sub_len or
          Enum.any?(scopes, &(not is_binary(&1))) or
          length(scopes) > @max_scopes or
          Enum.any?(scopes, &(byte_size(&1) > @max_scope_len)) ->
        {:error, :invalid_input}

      true ->
        do_mint(client_scope, scopes)
    end
  end

  defp do_mint(sub, scopes) do
    tick = :erlang.monotonic_time(:second)
    n = :atomics.add_get(counter_ref(), 1, 1)

    claims = %{
      "sub" => sub,
      "iat" => tick,
      "exp" => tick + @ttl_s,
      "scopes" => scopes,
      "jti" => n
    }

    header = %{"alg" => "none.localsts", "typ" => "JWT-shaped"}
    seg = fn m -> Base.url_encode64(:erlang.term_to_binary(m), padding: false) end

    h = seg.(header)
    p = seg.(claims)
    addendum = seg.(%{"alg" => "none.localsts", "sum" => :erlang.phash2({h, p})})

    token = h <> "." <> p <> "." <> addendum

    {:ok,
     %{
       token: token,
       claims: claims,
       lease: %{
         issued_tick: tick,
         expires_tick: tick + @ttl_s,
         ttl_s: @ttl_s,
         bounded: true
       }
     }}
  end

  @doc """
  Verify a minted token. `{:ok, claims}` on a structurally exact, unexpired
  envelope; `{:error, :expired}` when past `exp`; `{:error, :malformed}`
  otherwise (fail-closed).
  """
  def verify(token)

  def verify(token) when is_binary(token) do
    with [h, p, a] <- String.split(token, ".", parts: 3, trim: true),
         {:ok, hb} <- safe_decode(h),
         {:ok, pb} <- safe_decode(p),
         {:ok, ab} <- safe_decode(a),
         {:ok, header} <- safe_bin_decode(hb),
         {:ok, claims} <- safe_bin_decode(pb),
         {:ok, addendum} <- safe_bin_decode(ab),
         %{"alg" => "none.localsts", "typ" => "JWT-shaped"} <- header,
         %{"alg" => "none.localsts"} <- addendum,
         true <- addendum["sum"] == :erlang.phash2({h, p}),
         claims = %{"sub" => sub, "iat" => _, "exp" => exp, "scopes" => _} when
                   is_binary(sub) and is_integer(exp) <- claims do
      now = :erlang.monotonic_time(:second)

      if now <= exp do
        {:ok, claims}
      else
        {:error, :expired}
      end
    else
      _ -> {:error, :malformed}
    end
  end

  def verify(_), do: {:error, :malformed}

  defp safe_decode(s) do
    case Base.url_decode64(s, padding: false) do
      {:ok, b} -> {:ok, b}
      :error -> {:error, :malformed}
    end
  end

  defp safe_bin_decode(b) do
    try do
      {:ok, :erlang.binary_to_term(b)}
    rescue
      _ -> {:error, :malformed}
    end
  end

  defp counter_ref do
    case :persistent_term.get({__MODULE__, :counter}, :absent) do
      :absent ->
        ref = :atomics.new(1, signed: false)
        :persistent_term.put({__MODULE__, :counter}, ref)
        ref

      ref ->
        ref
    end
  end
end
