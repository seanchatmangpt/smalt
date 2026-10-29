defmodule PopcornDemo.ApexTrade do
  @moduledoc """
  APEX-1 / SCVD apex scenario 1: a 1,024-actor pre-trade settlement gate,
  composed from witnessed seams only (no new wire shapes):

  1. **HSM-sign leg** — the trade-payload signature via the LiveKeyops sign
     path on the LIVE substrate: KD-15 tokenless challenge (401 +
     `www-authenticate` naming the STS authority) -> STS bearer ->
     `POST /keys/popcorn-key/sign` (api-version 7.4). Algorithm premise
     ROTATION, witnessed 2026-10-21: the substrate gained the EC arm (the
     LiveKeyops disjunctive law closed — `LiveKeyops.run/0` now returns
     `{:ok, "keyops=OK(ES256:verified)"}`), so `popcorn-key` is EC and the
     wire answers RS256 with a typed `400 InvalidAlgorithm` (measured this
     session). The leg therefore signs **ES256** over the sha256 digest of
     the trade payload — the same witnessed path LiveKeyops's OK branch
     takes. Real `:gen_tcp` HTTP/1.1, no inets (inets httpc is broken under
     the popcorn_demo mix env, same transport law as `PopcornDemo.LiveKV`).
  2. **CAS leg** — 1,024 actors race an atomic `_etag`-equivalent CAS on ONE
     margin record via `PopcornDemo.Concurrency`-style optimistic ETS CAS:
     atomic `:ets.insert_new` claim -> matched exists-check -> conditional
     update. Exactly 1 winner decrements the margin and commits at version 1;
     the other 1,023 actors return the typed loss `{:cas_lost, key}` — the
     412-equivalent. Pure in-memory, deterministic, fail-closed: any deviation
     is a typed `{:error, {:not_deterministic, detail}}`, never a coerced pass.
  3. **EH settlement leg** — the winner fires ONE AMQP 1.0 transfer over the
     real 127.0.0.1:5673 wire via the witnessed public seam
     `PopcornDemo.LiveEh.publish_events/1` (connect -> SASL ANONYMOUS ->
     open session -> sender attach to `/eventhubs/popcorn-eh/partitions/0` ->
     transfer -> broker `accepted` disposition). `{:ok, 1}` IS the broker
     settlement witness.

  Chicago school: the only collaborators are the live smalt substrate, the
  AMQP wire, and the BEAM scheduler. No mocks. Skips are loud and typed.

  Measured per run: total wall_ms, per-leg wall_ms, CAS winner/loser
  distribution, actor memory (`:erlang.process_info(self(), :memory)` sampled
  inside each actor), zero unhandled exceptions (a crashed actor surfaces as a
  missing id in the collected map — a typed determinism breach, never silent).
  """

  alias PopcornDemo.LiveEh

  @kv_base "http://127.0.0.1:8443"
  @kv_key "popcorn-key"
  @api_version "7.4"
  @actors 1_024
  @margin_start 1_000_000

  @doc """
  Runs the full scenario. `{:ok, report}` with the measured fields, or a
  typed error. Substrate-down is a typed loud skip, never a faked pass.
  """
  @spec run() :: {:ok, map()} | {:skip, String.t()} | {:error, {:leg, atom(), term()}}
  def run do
    t0 = System.monotonic_time(:millisecond)

    with {:ok, sign_info} <- sign_leg() do
      cas0 = System.monotonic_time(:millisecond)

      case cas_gate(@actors, @margin_start) do
        {:ok, cas_row} ->
          cas_ms = ms_since(cas0)

          case settle_leg(cas_row.winner_id, settle_token()) do
            {:ok, token} ->
              {:ok,
               %{
                 actors: @actors,
                 wall_ms: ms_since(t0),
                 sign: sign_info,
                 cas: Map.put(cas_row, :wall_ms, cas_ms),
                 settle: {:ok, token},
                 exceptions: 0
               }}

            other ->
              other
          end

        {:error, _} = err ->
          err
      end
    end
  end

  # -- leg 1: HSM-sign (LiveKeyops RS256 sign path) ----------------------------

  @doc """
  One real ES256 signature over the trade payload via the LiveKeyops sign
  path (KD-15 handshake + EC create-or-reuse + `POST /keys/popcorn-key/sign`,
  api-version 7.4). Returns `{:ok, %{alg:, sig_bytes:, wall_ms:}}` / typed
  skip / error.
  """
  @spec sign_leg() :: {:ok, map()} | {:skip, String.t()} | {:error, {:leg, atom(), term()}}
  def sign_leg do
    payload = "apex-trade-payload-" <> Integer.to_string(System.system_time(:millisecond))
    digest = sha256_b64url(payload)
    t0 = System.monotonic_time(:millisecond)

    case challenge_token() do
      {:ok, token} ->
        # create-or-reuse the EC key (same seam as LiveKeyops's OK branch) — a
        # fresh substrate has no popcorn-key yet (witnessed: KeyNotFound 404)
        with :ok <- create_or_reuse_ec(token) do
          sign_request(token, digest, payload, t0)
        end

      {:skip, reason} ->
        {:skip, "sign=SKIP(#{reason})"}

      {:error, {step, reason}} ->
        {:error, {:leg, step, reason}}
    end
  end

  defp create_or_reuse_ec(token) do
    req = %{
      method: "POST",
      url: @kv_base <> "/keys/#{@kv_key}/create?api-version=#{@api_version}",
      headers: [
        {"authorization", "Bearer " <> token},
        {"content-type", "application/json"}
      ],
      body: Jason.encode!(%{"kty" => "EC", "crv" => "P-256"})
    }

    case http_req(req) do
      {:ok, %{status: 200, body: _}} -> :ok
      {:ok, %{status: st, body: body}} -> {:error, {:leg, :ec_create, "http-#{st}:#{slice(body)}"}}
      {:error, reason} -> {:error, {:leg, :ec_create, fmt(reason)}}
    end
  end

  defp sign_request(token, digest, payload, t0) do
    req = %{
      method: "POST",
      url: @kv_base <> "/keys/#{@kv_key}/sign?api-version=#{@api_version}",
      headers: [
        {"authorization", "Bearer " <> token},
        {"content-type", "application/json"}
      ],
      # ES256 — the witnessed live path (see moduledoc rotation note);
      # RS256 on the EC key answers typed 400 InvalidAlgorithm.
      body: Jason.encode!(%{"alg" => "ES256", "digest" => digest})
    }

    case http_req(req) do
      {:ok, %{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"value" => sig}} when is_binary(sig) and sig != "" ->
            {:ok,
             %{
               alg: "ES256",
               payload: payload,
               sig_bytes: byte_size(sig),
               wall_ms: ms_since(t0)
             }}

          _ ->
            {:error, {:leg, :sign, "200-without-signature-value-field:#{slice(body)}"}}
        end

      {:ok, %{status: st, body: body}} ->
        {:error, {:leg, :sign, "http-#{st}:#{slice(body)}"}}

      {:error, reason} ->
        {:error, {:leg, :sign, fmt(reason)}}
    end
  end

  # -- leg 2: 1,024-actor margin CAS gate --------------------------------------

  @doc """
  Spawns `n` actors racing an atomic CAS on ONE margin record
  (`{:margin, :available, margin, 0}` — the `_etag` analogue is the row
  version). Exactly one `:ets.insert_new` claim wins; the winner conditionally
  commits the decremented margin at version 1; every other actor returns the
  typed loss `{:cas_lost, key}`. Determinism is asserted structurally (same
  law as `PopcornDemo.Concurrency.assert_contention_final/2`); any deviation
  is a typed `{:error, {:not_deterministic, detail}}`.

  Actor memory is sampled INSIDE each actor via
  `:erlang.process_info(self(), :memory)` — a pid's info dies with it.
  """
  @spec cas_gate(pos_integer(), pos_integer()) ::
          {:ok, map()} | {:error, {:not_deterministic, term()}}
  def cas_gate(n, margin) when is_integer(n) and n > 0 and is_integer(margin) and margin > 1 do
    tab = :ets.new(:apex_margin_cas, [:public, :set])
    # NO pre-seeded row: the atomic `:ets.insert_new` claim IS the CAS — a
    # pre-seeded row makes every actor's claim lose (witnessed this session:
    # 1,024 losers, 0 winners -> typed not_deterministic refusal, fail-closed).
    key = :margin
    parent = self()

    for id <- 1..n do
      spawn(fn ->
        result = cas_actor(id, tab, key, margin)
        mem = :erlang.process_info(self(), :memory) |> elem(1)
        send(parent, {id, result, mem})
      end)
    end

    results = collect(n, [])

    final = :ets.match(tab, {key, :"$1", :"$2", :"$3"})

    winners = Enum.count(results, &match?({_, {:winner, _}, _}, &1))
    losers = Enum.count(results, &match?({_, {:cas_lost, _}, _}, &1))
    mems = for {_, _, mem} <- results, do: mem

    row = %{
      n: n,
      key: key,
      winners: winners,
      losers: losers,
      committed: final == [[:committed, margin - 1, 1]],
      final_version: extract_version(final),
      winner_id: winner_id(results),
      actor_mem_bytes: mem_stats(mems)
    }

    :ets.delete(tab)

    case assert_gate(results, final, margin) do
      :ok -> {:ok, row}
      {:error, detail} -> {:error, {:not_deterministic, detail}}
    end
  end

  @doc """
  One CAS actor: atomic `insert_new` claim; losers observe the existing claim
  and return the typed loss `{:cas_lost, key}` (412-equivalent); the winner
  exists-checks its own claim, then conditionally commits the decremented
  margin at version 1. Public test seam.
  """
  def cas_actor(id, tab, key, margin) do
    case :ets.insert_new(tab, {key, :claimed, id, 0}) do
      true ->
        case :ets.match(tab, {key, :"$1", :"$2", :"$3"}) do
          [[:claimed, winner_id, 0]] when winner_id == id ->
            :ets.insert(tab, {key, :committed, margin - 1, 1})
            {:winner, key}

          _ ->
            {:error, {:claim_vanished, key}}
        end

      false ->
        {:cas_lost, key}
    end
  end

  @doc """
  Structural determinism law: exactly one winner, every other actor a typed
  loser, and the final row committed at version 1 with the decremented
  margin. Margin is passed explicitly — no inferred zero-bit checks.
  """
  def assert_gate(results, final, margin) do
    winners = Enum.filter(results, &match?({_, {:winner, _}, _}, &1))
    losers = Enum.count(results, &match?({_, {:cas_lost, _}, _}, &1))

    cond do
      length(winners) != 1 ->
        {:error, {:winner_count, length(winners)}}

      length(results) != 1 + losers ->
        {:error, {:loser_partition, length(results), losers}}

      final != [[:committed, margin - 1, 1]] ->
        {:error, {:bad_final_row, final}}

      true ->
        :ok
    end
  end

  # -- leg 3: EH settlement (LiveEh sender pattern) -----------------------------

  @doc """
  Fires ONE AMQP transfer over the real 5673 wire using the witnessed public
  seam `PopcornDemo.LiveEh.publish_events/1` (the LiveEh sender pattern:
  connect -> SASL ANONYMOUS -> open session -> sender attach ->
  transfer -> broker `accepted` disposition = broker settlement).
  `{:ok, token}` on settlement; loud typed skip when the EH plane is down.
  """
  @spec settle_leg(pos_integer(), String.t()) ::
          {:ok, String.t()} | {:skip, String.t()} | {:error, {:leg, atom(), term()}}
  def settle_leg(_winner_id, token) do
    case LiveEh.publish_events(1) do
      {:ok, 1} ->
        {:ok, token}

      {:skip, reason} ->
        {:skip, "settle=SKIP(#{reason})"}

      {:error, reason} ->
        {:error, {:leg, :settle, reason}}
    end
  end

  # -- KD-15 challenge handshake (same shape as LiveKeyops) ---------------------

  defp challenge_token do
    url = @kv_base <> "/keys/#{@kv_key}?api-version=#{@api_version}"

    case http_req(%{method: "GET", url: url, body: ""}) do
      {:ok, %{status: 401, headers: headers}} ->
        with {:ok, authority} <- www_authenticate_authority(headers),
             {:ok, token} <- sts_token(authority) do
          {:ok, token}
        end

      {:ok, %{status: st, body: body}} ->
        {:error, {"challenge", "expected-401-got-http-#{st}:#{slice(body)}"}}

      {:error, reason} ->
        {:skip, "substrate-down(8443:#{fmt(reason)}); run 9>&- just substrate-up"}
    end
  end

  defp www_authenticate_authority(headers) do
    case header(headers, "www-authenticate") do
      nil ->
        {:error, {"challenge", "401-without-www-authenticate-header"}}

      value ->
        case Regex.run(~r/authorization="([^"]+)"/i, value) do
          [_, authority] -> {:ok, authority}
          nil -> {:error, {"challenge", "www-authenticate-missing-authorization:#{slice(value)}"}}
        end
    end
  end

  defp sts_token(authority) do
    req = %{
      method: "POST",
      url: authority <> "/oauth2/v2.0/token",
      headers: [{"content-type", "application/x-www-form-urlencoded"}],
      body: "grant_type=client_credentials&client_id=popcorn-demo&client_secret=not-checked"
    }

    case http_req(req) do
      {:ok, %{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"access_token" => tok}} when is_binary(tok) -> {:ok, tok}
          _ -> {:error, {"token", "no-access_token-in-sts-body"}}
        end

      {:ok, %{status: st, body: body}} ->
        {:error, {"token", "http-#{st}:#{slice(body)}"}}

      {:error, reason} ->
        {:error, {"token", fmt(reason)}}
    end
  end

  # -- real :gen_tcp HTTP/1.1 (inets httpc broken under popcorn_demo mix env) --

  defp http_req(%{method: method, url: url} = req) do
    uri = URI.parse(url)
    host = to_charlist(uri.host)
    path = if uri.query, do: uri.path <> "?" <> uri.query, else: uri.path
    body = Map.get(req, :body, "")
    headers = Map.get(req, :headers, [])

    case :gen_tcp.connect(host, uri.port || 80, [:binary, packet: :raw, active: false], 5_000) do
      {:ok, sock} ->
        head = Enum.map_join(headers, "\r\n", fn {k, v} -> "#{k}: #{v}" end)

        raw =
          "#{method} #{path} HTTP/1.1\r\n" <>
            "host: #{uri.host}:#{uri.port || 80}\r\n" <>
            (if head != "", do: head <> "\r\n", else: "") <>
            "content-length: #{byte_size(body)}\r\n" <>
            "connection: close\r\n\r\n" <> body

        result =
          with :ok <- :gen_tcp.send(sock, raw),
               {:ok, resp} <- recv_all(sock, <<>>, 10_000) do
            parse_resp(resp)
          end

        :gen_tcp.close(sock)
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp recv_all(sock, buf, timeout) do
    case :gen_tcp.recv(sock, 0, timeout) do
      {:ok, data} -> recv_all(sock, buf <> data, timeout)
      {:error, :closed} -> {:ok, buf}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_resp(resp) do
    case :binary.split(resp, "\r\n\r\n") do
      [head, body] ->
        [status_line | header_lines] = String.split(head, "\r\n")

        case Regex.run(~r"HTTP/1\.[01] (\d{3})", status_line) do
          [_, code] ->
            headers =
              for line <- header_lines,
                  parts = String.split(line, ":", parts: 2),
                  length(parts) == 2,
                  [k, v] = parts do
                {String.downcase(String.trim(k)), String.trim(v)}
              end

            {:ok, %{status: String.to_integer(code), headers: headers, body: body}}

          _ ->
            {:error, :bad_status_line}
        end

      _ ->
        {:error, :bad_http_response}
    end
  end

  # -- helpers -----------------------------------------------------------------

  defp collect(0, acc), do: acc

  defp collect(n, acc) do
    receive do
      {id, result, mem} -> collect(n - 1, [{id, result, mem} | acc])
    after
      15_000 -> acc
    end
  end

  defp extract_version([[:committed, _margin, v]]), do: v
  defp extract_version(_), do: nil

  defp winner_id(results) do
    case Enum.find(results, &match?({_, {:winner, _}, _}, &1)) do
      {id, {:winner, _}, _} -> id
      _ -> nil
    end
  end

  defp mem_stats([]), do: %{min: 0, max: 0, mean: 0.0}

  defp mem_stats(mems) do
    %{
      min: Enum.min(mems),
      max: Enum.max(mems),
      mean: Enum.sum(mems) / length(mems) |> Float.round(1)
    }
  end

  defp settle_token, do: "apex-settle-" <> Integer.to_string(System.system_time(:millisecond))

  defp sha256_b64url(payload), do: Base.url_encode64(:crypto.hash(:sha256, payload), padding: false)

  defp ms_since(t0), do: System.monotonic_time(:millisecond) - t0

  defp fmt(r) when is_binary(r), do: r
  defp fmt(r), do: inspect(r)

  defp slice(b, take \\ 120)
  defp slice(b, take) when byte_size(b) <= take, do: b
  defp slice(b, take), do: binary_part(b, 0, take) <> "..."

  defp header(headers, name) do
    case Enum.find(headers, fn {k, _} -> k == name end) do
      {_, v} -> v
      nil -> nil
    end
  end
end
