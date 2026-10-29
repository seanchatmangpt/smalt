defmodule Smalt.Test.Integration.TenantFenceRegistryTest do
  @moduledoc """
  D3 registry-fence court (cosmos registry namespacing — G4 residual): db and
  collection NAMES were enumerable cross-tenant (`list_dbs`/`list_collections`
  scanned the unscoped `{0, db}` / `{1, db, coll}` rows).

  Gate: tenant B lists ZERO of tenant A's dbs/colls while seeing its own; the
  home tenant's registry keys stay byte-identical to the legacy layout; a
  cross-tenant container-meta face (pkranges, backed by the container record)
  is refused the typed 403.

  Chicago discipline: real HTTPS on the real twin listener, real curl
  subprocess transport, real STS-minted bearers (tid from the token-endpoint
  PATH tenant), asserting final wire state.
  """

  use ExUnit.Case, async: false

  alias Smalt.Auth.TenantLaw

  @pk_meta_table :smalt_cosmos_pk_meta

  @token_key_a :tenant_registry_tok_a
  @token_key_b :tenant_registry_tok_b
  @token_key_home :tenant_registry_tok_home

  test "tenant B lists zero of tenant A's dbs and colls, and sees its own" do
    {base, cert} = twin()
    ts = System.system_time(:millisecond)
    db_a = "rf-db-a-#{ts}"
    db_b = "rf-db-b-#{ts}"
    coll = "c1"

    # Tenant A provisions db + container through the wire.
    assert {201, _} =
             authed(:post, :a, base, cert, "/dbs", Jason.encode!(%{"id" => db_a}), [
               "Content-Type: application/json"
             ])

    assert {201, _} =
             authed(:post, :a, base, cert, "/dbs/#{db_a}/colls", Jason.encode!(%{"id" => coll}), [
               "Content-Type: application/json",
               "x-ms-version: 2018-12-31"
             ])

    # Tenant B provisions its own db + container (same coll name as A's).
    assert {201, _} =
             authed(:post, :b, base, cert, "/dbs", Jason.encode!(%{"id" => db_b}), [
               "Content-Type: application/json"
             ])

    assert {201, _} =
             authed(:post, :b, base, cert, "/dbs/#{db_b}/colls", Jason.encode!(%{"id" => coll}), [
               "Content-Type: application/json",
               "x-ms-version: 2018-12-31"
             ])

    # B's db feed: ZERO of A's dbs, B's own db present.
    assert {200, dbs_b} = authed_body(:get, :b, base, cert, "/dbs")
    refute dbs_b =~ db_a
    assert dbs_b =~ db_b

    # B's container feed addressed at A's db: zero rows (200 + empty
    # envelope, never A's collection names).
    assert {200, colls_on_a} = authed_body(:get, :b, base, cert, "/dbs/#{db_a}/colls")
    refute colls_on_a =~ coll

    # B's container feed on its own db: its own container present.
    assert {200, colls_b} = authed_body(:get, :b, base, cert, "/dbs/#{db_b}/colls")
    assert colls_b =~ coll

    # B's container GET on A's container: 404 (no existence leak).
    assert {404, _} = authed_body(:get, :b, base, cert, "/dbs/#{db_a}/colls/#{coll}")

    # Cross-tenant container-meta face (pkranges reads the container record):
    # typed 403 Forbidden, never the routing map, never a silent 404.
    assert {403, fbody} =
             authed_body(:get, :b, base, cert, "/dbs/#{db_a}/colls/#{coll}/pkranges")

    assert fbody =~ "Forbidden"

    # B's own pkranges: 200 with the routing map.
    assert {200, own} = authed_body(:get, :b, base, cert, "/dbs/#{db_b}/colls/#{coll}/pkranges")
    assert own =~ "PartitionKeyRanges"

    # A still sees its own db on the feed, and not B's.
    assert {200, dbs_a} = authed_body(:get, :a, base, cert, "/dbs")
    assert dbs_a =~ db_a
    refute dbs_a =~ db_b

    # A's container feed on its own db: its container present.
    assert {200, colls_a} = authed_body(:get, :a, base, cert, "/dbs/#{db_a}/colls")
    assert colls_a =~ coll
  end

  test "home tenant registry stays byte-identical: legacy keys, legacy visibility" do
    {base, cert} = twin()
    ts = System.system_time(:millisecond)
    db = "rf-home-db-#{ts}"
    coll = "c1"

    # A foreign tenant's db must NOT appear in the home feed.
    assert {200, before} = authed_body(:get, :home, base, cert, "/dbs")
    refute before =~ "rf-db-b-"

    # Home provisions through the wire (home bearer = the legacy namespace).
    assert {201, _} =
             authed(:post, :home, base, cert, "/dbs", Jason.encode!(%{"id" => db}), [
               "Content-Type: application/json"
             ])

    assert {201, _} =
             authed(:post, :home, base, cert, "/dbs/#{db}/colls", Jason.encode!(%{"id" => coll}), [
               "Content-Type: application/json",
               "x-ms-version: 2018-12-31"
             ])

    # Byte-identical registry state: the db row is the literal legacy key
    # {0, db}, the collection row {1, db, coll}, the pk-paths row "db/coll".
    assert [{{0, ^db}, _record}] = :ets.lookup(@pk_meta_table, {0, db})
    assert [{{1, ^db, ^coll}, _record}] = :ets.lookup(@pk_meta_table, {1, db, coll})
    assert [_meta] = :ets.lookup(@pk_meta_table, "#{db}/#{coll}")

    # Home sees its db on the feed and on the db-read face.
    assert {200, dbs} = authed_body(:get, :home, base, cert, "/dbs")
    assert dbs =~ db

    assert {200, dbread} = authed_body(:get, :home, base, cert, "/dbs/#{db}")
    assert dbread =~ db

    # And zero foreign dbs leak into the home feed.
    assert {200, home_after} = authed_body(:get, :home, base, cert, "/dbs")
    refute home_after =~ "rf-db-a-"
    refute home_after =~ "rf-db-b-"

    # Unit face of the namespacing law (TenantLaw back-compat).
    assert TenantLaw.tenant_scoped_key(TenantLaw.home_tenant(), "#{db}/#{coll}") ==
             "#{db}/#{coll}"
  end

  # -- transport --------------------------------------------------------------

  defp authed(method, tenant, base, cert, path, body, extra_headers) do
    key =
      case tenant do
        :a -> @token_key_a
        :b -> @token_key_b
        :home -> @token_key_home
      end

    case :persistent_term.get(key, nil) do
      nil ->
        :persistent_term.put(key, fetch_sts_token(base, cert, tenant))
        authed(method, tenant, base, cert, path, body, extra_headers)

      _tok ->
        case request_body(method, base, cert, path, body, extra_headers ++ auth_header(key)) do
          {401, _} ->
            :persistent_term.put(key, fetch_sts_token(base, cert, tenant))
            request_body(method, base, cert, path, body, extra_headers ++ auth_header(key))

          other ->
            other
        end
    end
  end

  defp authed_body(method, tenant, base, cert, path) do
    authed(method, tenant, base, cert, path, nil, ["x-ms-version: 2018-12-31"])
  end

  defp request_body(method, base, cert, path, body, extra_headers) do
    args =
      List.flatten([
        "-s",
        "--cacert",
        cert,
        "-w",
        "\n%{http_code}",
        "-X",
        String.upcase(Atom.to_string(method)),
        header_args(extra_headers),
        body_args(body),
        "#{base}#{path}"
      ])

    {out, 0} = System.cmd("curl", args, stderr_to_stdout: true)

    case String.trim_trailing(out) |> String.split("\n") |> List.last() |> Integer.parse() do
      {code, ""} when code in 100..599 ->
        body = out |> String.split("\n") |> Enum.drop(-1) |> Enum.join("\n")
        {code, body}

      _ ->
        raise "curl returned non-status output for #{path}: #{inspect(out)}"
    end
  end

  defp twin do
    port = Application.fetch_env!(:smalt, :arm_tls_port)
    {cert, _key} = Smalt.TLS.dev_cert_paths(port)
    {"https://127.0.0.1:#{port}", cert}
  end

  defp header_args(headers), do: Enum.flat_map(headers, &["-H", &1])

  defp auth_header(key) do
    case :persistent_term.get(key, nil) do
      nil -> ["-H", "Authorization: Bearer anonymous-probe"]
      tok -> ["-H", "Authorization: Bearer #{tok}"]
    end
  end

  defp body_args(nil), do: []
  defp body_args(body), do: ["--data-binary", body]

  # Real STS issuer on the twin: POST /{tenant}/oauth2/v2.0/token — the mint
  # stamps tid from the PATH tenant. The home tenant mints at the legacy
  # "smalt-tenant" path (tid = home), so its registry keys stay legacy.
  defp fetch_sts_token(base, cert, tenant) do
    tid =
      case tenant do
        :a -> "tenant-a-g4"
        :b -> "tenant-b-g4"
        :home -> TenantLaw.home_tenant()
      end

    args = [
      "-s",
      "--cacert",
      cert,
      "-X",
      "POST",
      "-d",
      "grant_type=client_credentials&client_id=tf-lane&client_secret=tf-lane&scope=https://documents.azure.com/.default",
      "#{base}/#{tid}/oauth2/v2.0/token"
    ]

    {out, 0} = System.cmd("curl", args, stderr_to_stdout: true)
    %{"access_token" => tok} = Jason.decode!(out)
    tok
  end
end
