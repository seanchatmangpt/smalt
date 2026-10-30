# KD-03 KV value-echo polarity court (lane 15, v26.10.31): the per-face
# value-echo law over the real KvRoutes router + real Store ETS rows —
# Chicago discipline, no mocks, no sleeps.
#
# Polarity law (posh KD-03), one row per face:
#   8443 point GET/PATCH -> value ECHOES
#   test/internal/kdlith_w2 court pins value presence on /versions list
#   (registered divergence — that face's own law is recorded, not cleaned up)
#   8443 list faces      -> value NEVER
#   engine soft-delete   -> value NEVER
#   ARM face             -> echoes verbatim (Go-side table: posh armkv/kv7)
#
# Split-brain witness: TWO same-named public_secret_record/1 disagreed on
# "value" (AppConfigRoutes.ex:340 keeps; key_vault/secrets.ex:111 dropped) —
# the engine PATCH face silently dropped the value real Azure's
# SecretBundle-on-update echoes. Fixed by aligning the engine point face to
# the router point face; this court flips if either half regresses.
defmodule Smalt.Internal.Kd03KvPolarityTest do
  use ExUnit.Case, async: false
  alias Plug.Adapters.Test.Conn, as: TestConn

  @table :smalt_vault_secrets

  setup do
    # Fail loud if the store is not booted — real-store court.
    assert :ets.info(@table) != :undefined, "smalt vault secrets store not booted"
    :ok
  end

  test "KD-03: per-face value polarity over real wire dispatch" do
    name = "kd03-sec-#{System.system_time(:millisecond)}"

    # --- point faces: PUT / GET / PATCH echo the value ---------------------
    put_body = put_secret(name, "shh")
    assert put_body["value"] == "shh", "PUT (point face) must echo value"
    assert bookkeeping_absent?(put_body), "bookkeeping must never leave the vault"

    {200, get_body} = wire(name)
    assert get_body["value"] == "shh", "point GET must echo value"
    assert bookkeeping_absent?(get_body)

    conn =
      %Plug.Conn{}
      |> TestConn.conn("PATCH", "/secrets/#{name}", "")
      |> Map.put(:body_params, %{"attributes" => %{"enabled" => false}})

    conn = Smalt.Egress.KvRoutes.call(conn, [])
    assert conn.status == 200, "PATCH -> #{conn.status}"
    patch_body = Jason.decode!(conn.resp_body)
    assert patch_body["value"] == "shh", "PATCH (point face) must echo value (KD-03 split-brain fix)"
    assert bookkeeping_absent?(patch_body)

    # --- list face: never echoes the value ---------------------------------
    conn =
      %Plug.Conn{}
      |> TestConn.conn("GET", "/secrets", "")
      |> Smalt.Egress.KvRoutes.call([])

    assert conn.status == 200
    list_body = Jason.decode!(conn.resp_body)

    case list_body["value"] do
      nil ->
        flunk("list face returned no value envelope: #{inspect(list_body)}")

      bundles when is_list(bundles) ->
        # Only this court's secret is asserted on (shared store).
        mine = Enum.filter(bundles, &(&1["id"] && String.contains?(&1["id"], name)))

        case mine do
          [] -> flunk("list face missing the court's secret")
          bundles ->
            assert Enum.all?(bundles, &is_nil(&1["value"])),
                   "list face must never echo value"
        end
    end

    # --- soft-delete face: deleted bundle never echoes the value -----------
    conn =
      %Plug.Conn{}
      |> TestConn.conn("DELETE", "/secrets/#{name}", "")
      |> Smalt.Egress.KvRoutes.call([])

    assert conn.status in [200, 204], "DELETE -> #{conn.status}"

    conn =
      %Plug.Conn{}
      |> TestConn.conn("GET", "/deletedsecrets/#{name}", "")
      |> Smalt.Egress.KvRoutes.call([])

    assert conn.status == 200, "GET deleted secret -> #{conn.status}"
    deleted = Jason.decode!(conn.resp_body)
    assert is_nil(deleted["value"]), "soft-delete face must never echo value"
  end

  # ---------------------------------------------------------------------------

  defp bookkeeping_absent?(body) do
    %{"versions" => nil, "created_seq" => nil, "is_version_row" => nil, "version" => nil}
    |> Map.new(fn {k, _} -> {k, Map.has_key?(body, k)} end)
    |> Enum.all?(fn {_k, present} -> not present end)
  end

  # wire helpers (real router dispatch over the Plug test adapter)
  defp put_secret(name, value) do
    conn =
      %Plug.Conn{}
      |> TestConn.conn("PUT", "/secrets/#{name}", "")
      |> Map.put(:body_params, %{"value" => value})

    conn = Smalt.Egress.KvRoutes.call(conn, [])
    assert conn.status in [200, 201], "PUT /secrets/#{name} -> #{conn.status}"
    Jason.decode!(conn.resp_body)
  end

  defp wire(name) do
    conn =
      %Plug.Conn{}
      |> TestConn.conn("GET", "/secrets/#{name}", "")
      |> Smalt.Egress.KvRoutes.call([])

    {conn.status, Jason.decode!(conn.resp_body)}
  end
end