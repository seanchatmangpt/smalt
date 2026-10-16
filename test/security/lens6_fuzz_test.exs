defmodule Smalt.Security.Lens6FuzzTest do
  use ExUnit.Case, async: false
  alias Smalt.DataPlane.SKR
  alias Smalt.Security.ReceiptSigner
  alias Smalt.Store

  @compliance "azure-compliant-cvm"

  # lens-6 cycle-6: hostile-input fuzz of the SKR release entry point — the
  # public entry lens-5's fuzz did not cover. Law: SKR.release returns typed
  # tuples on hostile headers/tokens, never raises.
  test "SKR.release never raises on hostile tokens x hostile conns" do
    Store.put(:smalt_vault_keys, "l6-fuzz", %{
      "kid" => "k-fuzz",
      "release_policy" => %{"authority" => "smalt-test"}
    })

    now = System.system_time(:second)

    tokens =
      [
        "",
        "garbage",
        "a.b",
        "a.b.c.d",
        String.duplicate("x", 200_000),
        ReceiptSigner.sign(%{"x-ms-compliance-status" => "wrong-status"}),
        # validly signed, compliance ok, hostile jti/JWK shapes (all encodable)
        ReceiptSigner.sign(%{
          "x-ms-compliance-status" => @compliance,
          "x-ms-runtime" => %{"jti" => ""},
          "exp" => now + 7200
        }),
        ReceiptSigner.sign(%{
          "x-ms-compliance-status" => @compliance,
          "x-ms-runtime" => %{"jti" => %{"nested" => 1}},
          "exp" => now + 7200
        }),
        ReceiptSigner.sign(%{
          "x-ms-compliance-status" => @compliance,
          "x-ms-runtime" => %{"jti" => String.duplicate("j", 100_000)},
          "skr_recipient_jwk" => %{"kty" => "RSA", "n" => "", "e" => ""},
          "exp" => now + 7200
        })
      ]

    for token <- tokens do
      conn = release_conn("l6-fuzz", token)
      result = SKR.release("l6-fuzz", conn)

      assert match?({:ok, 200, _}, result) or match?({:error, _, _}, result),
             "SKR.release misreturned on token: #{String.slice(inspect(token), 0, 40)}"
    end

    hostile_conns = [
      # no authorization header
      :post |> Plug.Test.conn("/keys/l6-fuzz/release"),
      # multiple authorization entries (get_req_header returns a list)
      conn_multi(),
      # lowercase scheme
      release_conn("l6-fuzz", "bearer " <> ReceiptSigner.sign(good_claims())),
      # non-Bearer scheme
      release_conn("l6-fuzz", "Basic abc"),
      # legacy header only, legacy disabled
      :post
      |> Plug.Test.conn("/keys/l6-fuzz/release")
      |> Plug.Conn.put_req_header("x-ms-compliance-status", @compliance)
    ]

    for conn <- hostile_conns do
      result = SKR.release("l6-fuzz", conn)

      assert match?({:ok, 200, _}, result) or match?({:error, _, _}, result),
             "SKR.release misreturned on hostile conn"
    end
  end

  defp release_conn(name, token) do
    :post
    |> Plug.Test.conn("/keys/#{name}/release")
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
  end

  defp conn_multi do
    conn =
      :post
      |> Plug.Test.conn("/keys/l6-fuzz/release")
      |> Plug.Conn.put_req_header("authorization", "Bearer a")

    Plug.Conn.put_req_header(conn, "authorization", "Bearer b")
  end

  defp good_claims do
    now = System.system_time(:second)

    %{
      "x-ms-compliance-status" => @compliance,
      "x-ms-runtime" => %{"jti" => "l6-fuzz-ok-#{System.unique_integer([:positive])}"},
      "exp" => now + 7200
    }
  end
  # lens-6 cycle-8: wave 2 on the SKR.release entry — a fresh shape family:
  # hostile key names / key records, and hostile-but-legible claim shapes
  # (nbf, typ, nested runtime) never raise.
  test "SKR.release wave 2: hostile key names and claim shapes never raise" do
    Store.put(:smalt_vault_keys, "l6-fuzz", %{
      "kid" => "k-fuzz",
      "release_policy" => %{"authority" => "smalt-test"}
    })

    now = System.system_time(:second)

    base = %{
      "x-ms-compliance-status" => @compliance,
      "x-ms-runtime" => %{"jti" => "l6-w2"},
      "exp" => now + 7200
    }

    names = [
      "l6-fuzz",
      "no-such-key-#{System.unique_integer()}",
      "",
      String.duplicate("k", 5000),
      "with/slash"
    ]

    claim_shaspe = [
      Map.put(base, "nbf", now + 10_000),
      Map.put(base, "nbf", now - 1),
      Map.delete(base, "exp"),
      Map.put(base, "x-ms-runtime", "not-a-map"),
      Map.put(base, "skr_recipient_jwk", "not-a-map"),
      Map.put(base, "skr_recipient_jwk", %{"kty" => "oct", "k" => "AAAA"}),
      Map.put(base, "skr_recipient_jwk", %{"kty" => 42}),
      Map.put(base, "skr_recipient_jwk", %{"kty" => "RSA", "n" => "####", "e" => "AQAB"})
    ]

    for name <- names, claims <- claim_shaspe do
      conn = release_conn(name, ReceiptSigner.sign(claims))
      result = SKR.release(name, conn)

      assert match?({:ok, 200, _}, result) or match?({:error, _, _}, result),
             "SKR.release misreturned on name=#{String.slice(inspect(name), 0, 30)}"
    end

    # lens-7 cycle-3: hostile nested-form (x-ms-isolation-tee) shapes — the
    # compliance_status/1 traversal's second site. Top-level compliance is
    # DELETED so the tee branch actually executes; a non-map tee must be a
    # typed refusal, never a raise (the same get_in crash class as
    # x-ms-runtime). The final shape is the real nested MAA form and must
    # RELEASE (pins the nested-form admit path).
    now2 = System.system_time(:second)

    tee_base = %{
      "x-ms-runtime" => %{"jti" => "l6-tee-#{System.unique_integer([:positive])}"},
      "exp" => now2 + 7200
    }

    tee_shapes = [
      Map.put(tee_base, "x-ms-isolation-tee", "not-a-map"),
      Map.put(tee_base, "x-ms-isolation-tee", 42),
      Map.put(tee_base, "x-ms-isolation-tee", ["list", "form"]),
      Map.put(tee_base, "x-ms-isolation-tee", nil),
      Map.put(tee_base, "x-ms-isolation-tee", %{"x-ms-compliance-status" => @compliance})
    ]

    tee_results =
      for claims <- tee_shapes do
        conn = release_conn("l6-fuzz", ReceiptSigner.sign(claims))
        SKR.release("l6-fuzz", conn)
      end

    assert Enum.all?(tee_results, fn r ->
             match?({:ok, 200, _}, r) or match?({:error, _, _}, r)
           end),
           "hostile tee shapes must return typed tuples"

    assert {:ok, 200, _} = Enum.at(tee_results, 4),
           "real nested MAA form (tee map with compliance) must release"
  end

  # lens-8 cycle-3: generator rotation — NESTED-hostile tees (the tee map
  # itself carries hostile nested shapes) CROSSED with hostile claim shapes.
  # Law: the tee-admit path never raises and returns typed tuples; and the
  # real nested MAA form (runtime + compliance inside the tee) gets the SAME
  # single-use jti enforcement as the flat form.
  test "SKR.release wave 3: nested-hostile tees x crossed claims never raise; tee-form jti is single-use" do
    Store.put(:smalt_vault_keys, "l6-fuzz", %{
      "kid" => "k-fuzz",
      "release_policy" => %{"authority" => "smalt-test"}
    })

    now = System.system_time(:second)

    inner_runtime_shapes = [
      %{"jti" => ""},
      %{"jti" => 42},
      %{"jti" => %{"deep" => %{"deeper" => 1}}},
      %{"jti" => String.duplicate("n", 50_000)},
      "not-a-map",
      42,
      nil
    ]

    tee_shapes = [
      %{"x-ms-compliance-status" => @compliance, "x-ms-runtime" => %{"jti" => "tee-flat-dup"}},
      %{"x-ms-compliance-status" => 42},
      %{"x-ms-compliance-status" => nil},
      %{"x-ms-compliance-status" => @compliance, "skr_recipient_jwk" => "not-a-map"},
      %{"x-ms-compliance-status" => @compliance, "skr_recipient_jwk" => %{"kty" => 42}},
      %{"nested" => %{"deeper" => %{"deepest" => @compliance}}}
    ]

    crossed =
      for tee <- tee_shapes, rt <- inner_runtime_shapes do
        Map.put(tee, "x-ms-runtime", rt)
      end

    family = crossed ++ [Map.delete(hd(tee_shapes), "x-ms-runtime")]

    results =
      for claims <- family do
        token = ReceiptSigner.sign(claims)
        conn = release_conn("l6-fuzz", token)
        SKR.release("l6-fuzz", conn)
      end

    assert Enum.all?(results, fn r ->
             match?({:ok, 200, _}, r) or match?({:error, _, _}, r)
           end),
           "nested-hostile tee x crossed claims must return typed tuples"

    # Witness court for the lens-8 defect: a REAL nested MAA form (compliance
    # AND runtime inside the tee) must consume its jti — the SECOND release of
    # the same token must be a typed 403 replay, not a second 200.
    now2 = System.system_time(:second)

    nested_token =
      ReceiptSigner.sign(%{
        "x-ms-isolation-tee" => %{
          "x-ms-compliance-status" => @compliance,
          "x-ms-runtime" => %{"jti" => "l8-replay-#{System.unique_integer([:positive])}"}
        },
        "exp" => now2 + 7200
      })

    assert {:ok, 200, _} = SKR.release("l6-fuzz", release_conn("l6-fuzz", nested_token)),
           "first nested-form release must succeed"

    assert {:error, 403, _} = SKR.release("l6-fuzz", release_conn("l6-fuzz", nested_token)),
           "nested-form jti must be single-use: replay must be 403, got a second 200"

    # Recipient-site witness (lens-8 cycle-5): the wrap path must ALSO read
    # claims through the tee fallback — a nested-form token carrying a real
    # RSA recipient JWK inside the tee releases ATTESTED (RSA-OAEP-256), not
    # plaintext dev mode.
    recipient_priv = :public_key.generate_key({:rsa, 2048, 65_537})
    {:"RSAPrivateKey", _, _, _, n, e, _, _, _, _, _} = recipient_priv

    tee_jwk_token =
      ReceiptSigner.sign(%{
        "x-ms-isolation-tee" => %{
          "x-ms-compliance-status" => @compliance,
          "x-ms-runtime" => %{"jti" => "l8-jwk-#{System.unique_integer([:positive])}"},
          "skr_recipient_jwk" => %{
            "kty" => "RSA",
            "n" => Base.url_encode64(:binary.encode_unsigned(n), padding: false),
            "e" => Base.url_encode64(:binary.encode_unsigned(e), padding: false)
          }
        },
        "exp" => System.system_time(:second) + 7200
      })

    assert {:ok, 200, %{"transport" => "RSA-OAEP-256"}} =
             SKR.release("l6-fuzz", release_conn("l6-fuzz", tee_jwk_token)),
           "tee-form recipient JWK must wrap to the attested recipient, not dev plaintext"
  end


  # lens-9 wave 4: SPLIT claim placement. The MAA real-world form is not
  # always all-flat or all-nested: individual claims can sit on either side
  # of the tee boundary. Law (via the canonical claim_value/2 accessor, per
  # claim INDEPENDENTLY): every enforcement site (compliance admit, jti
  # single-use) sees the claim wherever it sits; top-level shadows tee on
  # conflict; and the replay court holds in every placement.
  test "SKR.release wave 4: split flat/nested claim placement across enforcement sites" do
    Store.put(:smalt_vault_keys, "l6-fuzz", %{
      "kid" => "k-fuzz",
      "release_policy" => %{"authority" => "smalt-test"}
    })

    uniq = System.unique_integer([:positive])

    put_compliance = fn claims, where, value ->
      case where do
        :flat -> Map.put(claims, "x-ms-compliance-status", value)
        :tee -> Map.update(claims, "x-ms-isolation-tee", %{"x-ms-compliance-status" => value}, &Map.put(&1, "x-ms-compliance-status", value))
      end
    end

    put_runtime = fn claims, where, jti ->
      case where do
        :flat -> Map.put(claims, "x-ms-runtime", %{"jti" => jti})
        :tee -> Map.update(claims, "x-ms-isolation-tee", %{"x-ms-runtime" => %{"jti" => jti}}, &Map.put(&1, "x-ms-runtime", %{"jti" => jti}))
      end
    end

    # 4 compliance placements x 3 jti placements, each released TWICE.
    results =
      for c_where <- [:flat, :tee],
          j_where <- [:flat, :tee] do
        jti = "l9-#{Atom.to_string(c_where)}-#{Atom.to_string(j_where)}-#{uniq}"

        claims =
          %{"exp" => System.system_time(:second) + 7200}
          |> put_compliance.(c_where, @compliance)
          |> put_runtime.(j_where, jti)

        token = ReceiptSigner.sign(claims)
        first = SKR.release("l6-fuzz", rel_conn(token))
        second = SKR.release("l6-fuzz", rel_conn(token))
        {c_where, j_where, first, second}
      end

    # All 4 admit; every jti placement is single-use (second release 403).
    for {c, j, first, second} <- results do
      assert {:ok, 200, _} = first, "placement #{inspect({c, j})} must admit"
      assert {:error, 403, %{"error" => %{"code" => "TokenReplay"}}} = second,
             "placement #{inspect({c, j})} replay must be 403 TokenReplay"
    end

    # Top-level precedence pin: flat BAD compliance shadows a good tee value.
    shadow =
      %{"exp" => System.system_time(:second) + 7200}
      |> put_compliance.(:flat, "wrong-status")
      |> put_compliance.(:tee, @compliance)
      |> put_runtime.(:tee, "l9-shadow-#{uniq}")

    assert {:error, 403, _} = SKR.release("l6-fuzz", rel_conn(ReceiptSigner.sign(shadow)))
  end

  defp rel_conn(token) do
    Plug.Test.conn(:post, "/keys/l6-fuzz/release")
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
  end
end
