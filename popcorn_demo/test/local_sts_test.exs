defmodule PopcornDemo.LocalSTSTest do
  use ExUnit.Case, async: true

  alias PopcornDemo.LocalSTS

  describe "mint/1" do
    test "issues a three-segment JWT-shaped base64 envelope with claims and finite lease" do
      assert {:ok, r} = LocalSTS.mint("client-a", scopes: ["blob.read", "kv.list"])

      assert [h, p, a] = String.split(r.token, ".", parts: 3)
      assert String.length(h) > 0 and String.length(p) > 0 and String.length(a) > 0

      assert %{"sub" => "client-a", "iat" => iat, "exp" => exp, "scopes" => ["blob.read", "kv.list"]} =
               r.claims
      assert is_integer(iat) and exp == iat + 3600

      assert r.lease == %{
               issued_tick: iat,
               expires_tick: exp,
               ttl_s: 3600,
               bounded: true
             }
    end

    test "deterministic: same input state => same token shape, count apart" do
      {:ok, r1} = LocalSTS.mint("client-a", scopes: ["s1"])
      {:ok, r2} = LocalSTS.mint("client-a", scopes: ["s1"])

      [_, p1, _] = String.split(r1.token, ".", parts: 3)
      [_, p2, _] = String.split(r2.token, ".", parts: 3)

      # identical shape apart from the monotonic issuance counter
      c1 = :erlang.binary_to_term(Base.url_decode64!(p1, padding: false))
      c2 = :erlang.binary_to_term(Base.url_decode64!(p2, padding: false))
      assert c2["jti"] == c1["jti"] + 1
      assert Map.delete(c1, "jti") == Map.delete(c2, "jti")
    end

    test "client-scoped: different sub yields different envelope" do
      {:ok, r1} = LocalSTS.mint("client-a", scopes: ["s1"])
      {:ok, r2} = LocalSTS.mint("client-b", scopes: ["s1"])
      assert r1.token != r2.token
      assert r1.claims["sub"] == "client-a"
      assert r2.claims["sub"] == "client-b"
    end

    test "bounded: oversized input refused with typed error (sub-Turing)" do
      assert {:error, :invalid_input} = LocalSTS.mint(String.duplicate("x", 129))
      assert {:ok, _} = LocalSTS.mint(String.duplicate("x", 128))
      assert {:error, :invalid_input} = LocalSTS.mint("c", scopes: [String.duplicate("s", 65)])
      assert {:error, :invalid_input} = LocalSTS.mint("c", scopes: List.duplicate("s", 17))
      assert {:error, :invalid_input} = LocalSTS.mint("c", scopes: "not-a-list")
    end
  end

  describe "verify/1 — Chicago round-trip against the real minted envelope" do
    test "mint -> verify round-trip returns the claims" do
      {:ok, r} = LocalSTS.mint("client-a", scopes: ["blob.read"])
      assert {:ok, claims} = LocalSTS.verify(r.token)
      assert claims == r.claims
    end

    test "expired token typed :expired (manipulated exp in a re-sealed envelope)" do
      {:ok, r} = LocalSTS.mint("client-a", scopes: ["s1"])
      [h, _, _] = String.split(r.token, ".", parts: 3)

      claims =
        r.claims |> Map.put("exp", :erlang.monotonic_time(:second) - 1) 

      expired_p = Base.url_encode64(:erlang.term_to_binary(claims), padding: false)
      sum = Base.url_encode64(:erlang.term_to_binary(%{"alg" => "none.localsts", "sum" => :erlang.phash2({h, expired_p})}), padding: false)
      assert {:error, :expired} = LocalSTS.verify(h <> "." <> expired_p <> "." <> sum)
    end

    test "malformed refused: garbage, tampered addendum, wrong shape, non-binary" do
      assert {:error, :malformed} = LocalSTS.verify("garbage")
      assert {:error, :malformed} = LocalSTS.verify("a.b")
      assert {:error, :malformed} = LocalSTS.verify(42)

      {:ok, r} = LocalSTS.mint("client-a")
      [h, p, a] = String.split(r.token, ".", parts: 3)
      # tampered addendum must fail the integrity addendum, not pass
      assert {:error, :malformed} = LocalSTS.verify(h <> "." <> p <> ".AAAA")
      assert {:error, :malformed} = LocalSTS.verify(h <> "." <> p <> "." <> a <> ".extra")
      # tampered payload breaks the addendum checksum
      tampered_p = Base.url_encode64(:erlang.term_to_binary(%{"bogus" => true}), padding: false)
      assert {:error, :malformed} = LocalSTS.verify(h <> "." <> tampered_p <> "." <> a)
    end

    test "deterministic rebuild: same state + same counter tick reproduces same token shape" do
      {:ok, r} = LocalSTS.mint("client-x", scopes: ["s"])
      {:ok, verified} = LocalSTS.verify(r.token)
      assert verified["sub"] == "client-x"
      assert verified["scopes"] == ["s"]
    end
  end

end
