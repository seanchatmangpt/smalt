defmodule Smalt.Test.Integration.TenantFenceCosmosTest do
  @moduledoc """
  G4 tenant-fence court (CZ2: two-tenant cross-tenant witness on the cosmos
  plane). Chicago discipline: real HTTPS on the real twin listener, real curl
  subprocess transport, real STS-minted bearer tokens (the STS mint stamps
  `tid` from the token-endpoint PATH tenant, so tenantA/tenantB are distinct
  verified identities), asserting final wire state.

  Gate: tenant-B bearer gets read 403 Forbidden, delete 403 + doc survives,
  query/list partition-scoped empty; same-tenant flows unchanged; no-tid
  tokens keep legacy behavior (the existing cosmos courts, run in full, are
  the regression legs).
  """

  use ExUnit.Case, async: false

  alias Smalt.Auth.TenantLaw

  @docs_table :smalt_cosmos_docs
  @token_key_a :tenant_fence_tok_a
  @token_key_b :tenant_fence_tok_b

  test "tenant B cannot read, delete, or see tenant A's cosmos docs" do
    {base, cert} = twin()
    ts = System.system_time(:millisecond)
    db = "tf-db-#{ts}"
    coll = "c1"
    doc_id = "doc-a-#{ts}"

    # Tenant A provisions a real db/container/doc through the wire.
    assert {201, _} =
             authed(:post, :a, base, cert, "/dbs", Jason.encode!(%{"id" => db}), [
               "Content-Type: application/json"
             ])

    assert {201, _} =
             authed(:post, :a, base, cert, "/dbs/#{db}/colls", Jason.encode!(%{"id" => coll}), [
               "Content-Type: application/json",
               "x-ms-version: 2018-12-31"
             ])

    assert {201, body} =
             authed(
               :post,
               :a,
               base,
               cert,
               "/dbs/#{db}/colls/#{coll}/docs",
               Jason.encode!(%{"id" => doc_id, "v" => "tenant-a-secret"}),
               ["Content-Type: application/json"]
             )

    assert body =~ doc_id

    # Cross-tenant READ: 403 Forbidden (real-Azure typed envelope), never the
    # document, never a silent 404 that hides the fence.
    assert {403, fbody} =
             authed_body(:get, :b, base, cert, "/dbs/#{db}/colls/#{coll}/docs/#{doc_id}")

    assert fbody =~ "Forbidden"
    refute fbody =~ "tenant-a-secret"

    # Cross-tenant DELETE: 403 AND the doc survives under tenant A.
    assert {403, _} =
             authed(:delete, :b, base, cert, "/dbs/#{db}/colls/#{coll}/docs/#{doc_id}", nil, [
               "x-ms-version: 2018-12-31"
             ])

    assert {200, surv} = authed_body(:get, :a, base, cert, "/dbs/#{db}/colls/#{coll}/docs/#{doc_id}")
    assert surv =~ "tenant-a-secret"

    # Cross-tenant PUT: 403, no write lands under tenant A's key.
    assert {403, _} =
             authed(
               :put,
               :b,
               base,
               cert,
               "/dbs/#{db}/colls/#{coll}/docs/#{doc_id}",
               Jason.encode!(%{"id" => doc_id, "v" => "tenant-b-write"}),
               ["Content-Type: application/json"]
             )

    assert {200, intact} =
             authed_body(:get, :a, base, cert, "/dbs/#{db}/colls/#{coll}/docs/#{doc_id}")

    assert intact =~ "tenant-a-secret"
    refute intact =~ "tenant-b-write"

    # Cross-tenant QUERY: partition-scoped empty (B scans only its namespace).
    assert {200, qbody} =
             authed(
               :post,
               :b,
               base,
               cert,
               "/dbs/#{db}/colls/#{coll}/docs",
               Jason.encode!(%{"query" => "SELECT * FROM c"}),
               ["Content-Type: application/query+json"]
             )

    refute qbody =~ doc_id
    refute qbody =~ "tenant-a-secret"

    # Cross-tenant LIST feed: partition-scoped empty as well.
    assert {200, lbody} = authed_body(:get, :b, base, cert, "/dbs/#{db}/colls/#{coll}/docs")
    refute lbody =~ doc_id
    refute lbody =~ "tenant-a-secret"

    # Same-tenant: A deletes 204, A re-read 404 (same-tenant law unchanged).
    assert {204, _} =
             authed(:delete, :a, base, cert, "/dbs/#{db}/colls/#{coll}/docs/#{doc_id}", nil, [
               "x-ms-version: 2018-12-31"
             ])

    assert {404, _} = authed_body(:get, :a, base, cert, "/dbs/#{db}/colls/#{coll}/docs/#{doc_id}")
  end

  test "tenant B create/read/delete its OWN docs (write isolation)" do
    {base, cert} = twin()
    ts = System.system_time(:millisecond)
    db = "tf-db2-#{ts}"
    coll = "c1"
    doc_id = "doc-b-#{ts}"

    assert {201, _} =
             authed(:post, :b, base, cert, "/dbs", Jason.encode!(%{"id" => db}), [
               "Content-Type: application/json"
             ])

    assert {201, _} =
             authed(:post, :b, base, cert, "/dbs/#{db}/colls", Jason.encode!(%{"id" => coll}), [
               "Content-Type: application/json",
               "x-ms-version: 2018-12-31"
             ])

    assert {201, _} =
             authed(
               :post,
               :b,
               base,
               cert,
               "/dbs/#{db}/colls/#{coll}/docs",
               Jason.encode!(%{"id" => doc_id, "v" => "tenant-b-data"}),
               ["Content-Type: application/json"]
             )

    assert {200, body} = authed_body(:get, :b, base, cert, "/dbs/#{db}/colls/#{coll}/docs/#{doc_id}")
    assert body =~ "tenant-b-data"

    assert {204, _} =
             authed(:delete, :b, base, cert, "/dbs/#{db}/colls/#{coll}/docs/#{doc_id}", nil, [
               "x-ms-version: 2018-12-31"
             ])

    # Symmetric fence: A cannot read B's doc (404 — A's namespace has no such
    # key; the 403 face is reserved for a key that exists in another tenant).
    assert {404, _} = authed_body(:get, :a, base, cert, "/dbs/#{db}/colls/#{coll}/docs/#{doc_id}")
  end

  test "tenant law unit face: home-tenant keys stay legacy-byte-identical" do
    assert TenantLaw.tenant_scoped_key(TenantLaw.home_tenant(), "db/coll/doc") == "db/coll/doc"
    assert TenantLaw.tenant_scoped_key("7777-tenant-b", "db/coll/doc") == "7777-tenant-b/db/coll/doc"

    # foreign_doc? on the REAL store table: a key nobody created is not
    # foreign to anyone (no false 403s on plain misses). The legacy mint
    # tenant "smalt-tenant" is home — assert it admits legacy keys unchanged.
    assert TenantLaw.tenant_scoped_key("smalt-tenant", "db/coll/doc") == "db/coll/doc"
    assert TenantLaw.foreign_doc?(@docs_table, "smalt-tenant", "no-such-db/c/no-such-doc") == false
  end

  # -- transport --------------------------------------------------------------

  defp authed(method, tenant, base, cert, path, body, extra_headers) do
    key = if tenant == :a, do: @token_key_a, else: @token_key_b

    # Mint eagerly when not cached: in test :anonymous auth mode there is no
    # 401 to trigger the challenge dance, but the tenant law reads the tid
    # off the bearer regardless of mode (dev face, disclosed in the law).
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
  # stamps tid from the PATH tenant, so each fetch is a distinct verified
  # identity. Per-tenant fixed probe id keeps the two tenants distinct
  # (identity is the tid; the probe id only separates the two fetches).
  defp fetch_sts_token(base, cert, tenant) do
    tid = if tenant == :a, do: "tenant-a-g4", else: "tenant-b-g4"

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

    case Jason.decode(out) do
      {:ok, %{"access_token" => tok}} when is_binary(tok) ->
        tok

      other ->
        flunk("STS token fetch failed: #{inspect(other)}")
    end
  end
end
