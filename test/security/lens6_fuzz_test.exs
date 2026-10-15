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
  end

end
