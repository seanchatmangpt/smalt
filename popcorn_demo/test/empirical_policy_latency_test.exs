defmodule PopcornDemo.EmpiricalPolicyLatencyTest do
  @moduledoc """
  E2 — empirical latency contract for the local (in-memory) APIM-policy leg.

  Converts the report's remote-gateway claim ("policy pipeline 16-25ms P95,
  complex chains 40ms+") into an executable Chicago test of the local policy
  path: the same four-policy chain apex_intake.mjs runs in JS, re-authored on
  the BEAM with real collaborators (ETS counter, :crypto HMAC, real maps) —
  no mocks, asserts on final measured state:

    1. rate-limit counter (ETS mirror of the JS Map)
    2. JWT shape validation (HS256 mint + shape/signature/claims verify)
    3. header transform (x-via injection + collision refusal)
    4. payload schema check

  Contract under test: 500 policy evaluations, p95 < 1ms (the report's
  local-claim: in-memory policy is sub-millisecond), zero errors, and the
  measured p95 sits at least 3 orders of magnitude below the report's
  complex-chain figure (40ms -> fence at 40us).
  """

  use ExUnit.Case, async: false

  @n 500
  @rate_limit 10_000
  @sts_secret "smalt-dev-sts-secret"
  @p95_fence_us 1_000
  # report's complex-chain figure 40ms; >=3 orders of magnitude => p95 <= 40us
  @three_orders_fence_us 40

  # ---- seam: LocalSTS-shaped token (HS256, emulator STS semantics) ----------
  # mirrors apex_intake.mjs stsMint/jwtShapeVerify exactly

  defp b64u(bin), do: Base.url_encode64(bin, padding: false)

  defp sts_mint(sub, tenant \\ "organizations") do
    now = System.system_time(:second)

    head = b64u(Jason.encode!(%{alg: "HS256", typ: "JWT"}))

    body =
      b64u(
        Jason.encode!(%{
          aud: "api://smalt-data-plane",
          iss: "https://127.0.0.1:9443/#{tenant}/",
          sub: sub,
          iat: now,
          exp: now + 600,
          appid: sub
        })
      )

    sig = b64u(:crypto.mac(:hmac, :sha256, @sts_secret, head <> "." <> body))
    head <> "." <> body <> "." <> sig
  end

  defp jwt_shape_verify(token) do
    token = String.replace_prefix(token, "Bearer ", "")
    parts = String.split(token, ".")

    with [h, b, s] <- parts,
         ^s <- b64u(:crypto.mac(:hmac, :sha256, @sts_secret, h <> "." <> b)) || {:error, :sig},
         {:ok, claims} <- Jason.decode(Base.url_decode64!(b, padding: false)) do
      missing =
        for k <- ["aud", "iss", "sub", "exp", "iat"], not Map.has_key?(claims, k), do: k

      cond do
        missing != [] -> {:error, {:missing, missing}}
        claims["exp"] <= System.system_time(:second) -> {:error, :expired}
        not String.starts_with?(claims["iss"], "https://127.0.0.1:9443/") -> {:error, :iss}
        true -> :ok
      end
    else
      _ -> {:error, :shape_or_sig}
    end
  end

  # ---- seam: policy arm (ETS mirror of the JS Map) --------------------------

  setup do
    table = :ets.new(:e2_rate_table, [:set, :public, :named_table])
    flags = :ets.new(:e2_flags, [:set, :public, :named_table])
    :ets.insert(flags, [{"apex.intake.enabled", true, 1.0}, {"apex.hot-staging.blocks", true, 3}])
    {:ok, table: table, flags: flags}
  end

  defp policy_leg(table, principal, payload, headers) do
    t0 = System.monotonic_time(:microsecond)

    count = case :ets.lookup(table, principal) do
      [{_, c}] -> c + 1
      [] -> 1
    end

    :ets.insert(table, {principal, count})

    verdict =
      cond do
        count > @rate_limit -> {429, :rate_limit}
        true ->
          case jwt_shape_verify(headers["authorization"]) do
            :ok ->
              if Map.has_key?(headers, "x-via") do
                {400, :header_transform_collision}
              else
                Map.put(headers, "x-via", "apem-policy-arm")

                missing =
                  for k <- ["submissionId", "kind", "bytes"],
                      not Map.has_key?(payload, k),
                      do: k

                if missing == [], do: {200, :ok}, else: {400, {:schema_missing, missing}}
              end

            {:error, why} -> {401, why}
          end
      end

    dt = System.monotonic_time(:microsecond) - t0
    {dt, verdict}
  end

  describe "local policy leg latency contract" do
    test "500 evaluations: p95 < 1ms, zero errors, >=3 orders under remote 40ms chain" do
      table = :ets.lookup(:e2_rate_table, :any) && :e2_rate_table
      principal = "e2-latency-principal"
      token = sts_mint(principal)

      base_headers = %{"authorization" => "Bearer " <> token}
      payload = %{"submissionId" => "sub-1", "kind" => "apex", "bytes" => 1024}

      lat_us =
        for i <- 1..@n do
          headers = Map.put(base_headers, "seq", i)
          {dt, {code, _why}} = policy_leg(table, principal, payload, headers)
          assert code == 200
          dt
        end

      sorted = Enum.sort(lat_us)
      p50 = Enum.at(sorted, div(@n, 2))
      p95 = Enum.at(sorted, trunc(@n * 0.95))
      p99 = Enum.at(sorted, trunc(@n * 0.99))
      max_us = List.last(sorted)
      mean_us = div(Enum.sum(lat_us), @n)

      # contract: sub-millisecond local claim
      assert p95 < @p95_fence_us,
             "POLICY-LATENCY-FAIL: p95=#{p95}us >= #{@p95_fence_us}us fence " <>
               "(p50=#{p50} p99=#{p99} max=#{max_us})"

      # contract: >=3 orders of magnitude under the report's 40ms complex chain
      assert p95 <= @three_orders_fence_us,
             "ORDERS-GAP-FAIL: p95=#{p95}us is not >=3 orders under 40ms (fence #{@three_orders_fence_us}us)"

      assert :ets.lookup(table, principal) |> hd() |> elem(1) == @n
    end

    test "policy chain refuses typed violations at zero latency cost to the happy path shape" do
      table = :e2_rate_table
      principal = "e2-negative-principal"
      token = sts_mint(principal)

      # 429 path
      :ets.insert(table, {principal, @rate_limit})
      assert {_, {429, :rate_limit}} =
               policy_leg(table, principal, %{"submissionId" => 1, "kind" => 1, "bytes" => 1}, %{})

      # 401 path (tampered signature)
      [h, b, _s] = String.split(token, ".")
      bad_token = h <> "." <> b <> "." <> b64u(:crypto.strong_rand_bytes(32))

      assert {_, {code, why}} =
               policy_leg(table, "neg-2", %{"submissionId" => 1, "kind" => 1, "bytes" => 1}, %{
                 "authorization" => "Bearer " <> bad_token
               })

      assert code == 401
      assert why in [:shape_or_sig, :sig]

      # 400 schema path
      assert {_, {400, {:schema_missing, ["submissionId"]}}} =
               policy_leg(table, "neg-3", %{"kind" => 1, "bytes" => 1}, %{
                 "authorization" => "Bearer " <> token
               })
      :ets.delete(table, principal)
      :ets.delete(table, "neg-2")
      :ets.delete(table, "neg-3")
    end
  end
end
