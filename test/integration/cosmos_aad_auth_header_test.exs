defmodule Smalt.Test.Integration.CosmosAadAuthHeaderTest do
  @moduledoc """
  V21 registry-namespacing regression court (athena customer1-simulation HOP 1
  falsifier).

  The @azure/cosmos SDK does NOT send `Authorization: Bearer <jwt>` — it sends
  the Cosmos AAD wire form `Authorization: type=aad&ver=1.0&sig=<jwt>`. Every
  tenant-resolution seam that pattern-matches only the `Bearer ` prefix
  (`TenantLaw.extract_tenant/1`, `tenant_from_headers/1`) silently resolves the
  SDK-path caller to the HOME tenant, while the same caller's raw-fetch calls
  (Authorization: Bearer, athena's authedFetch in ensureCaseSpace) resolve to
  its real `tid`. After the D3 registry-namespacing wave the registry keys are
  tenant-dependent, so:

    - ensureCaseSpace (Bearer, tid="common") creates the container row under
      `common/<db>` / `common/<db>/<coll>`;
    - caseDocPut's SDK container read (aad-form, resolves home) looks under
      `<db>` (home namespace) -> 404 "Entity with id cases not found".

  Court: the SAME caller (foreign tid "common") must see ONE namespace across
  BOTH auth-header forms — create via Bearer, read/write via the SDK's aad
  form — plus the home-tenant Bearer chain asserted step-by-step.
  """

  use ExUnit.Case, async: false

  @token_key_aad :v21_tok_aad
  @token_key_home :v21_tok_home

  test "foreign-tenant caller: one namespace across Bearer and aad-form auth" do
    {base, cert} = twin()
    ts = System.system_time(:millisecond)
    db = "v21-db-#{ts}"
    coll = "cases"

    # Create db + container as tid "common" via raw Bearer (the athena
    # ensureCaseSpace transport).
    assert {201, _} =
             authed(:post, :aad, base, cert, "/dbs", Jason.encode!(%{"id" => db}), [
               "Content-Type: application/json"
             ])

    assert {201, _} =
             authed(:post, :aad, base, cert, "/dbs/#{db}/colls", Jason.encode!(%{"id" => coll}), [
               "Content-Type: application/json",
               "x-ms-version: 2018-12-31"
             ])

    # The SDK transport (aad-form auth header) must resolve the SAME tenant:
    # container read 200. (Falsifier: pre-fix this is 404
    # "Entity with id cases not found".)
    {status, body} =
      authed(
        :get,
        :aad,
        base,
        cert,
        "/dbs/#{db}/colls/#{coll}",
        nil,
        ["x-ms-version: 2018-12-31"],
        auth_form: :aad
      )

    assert status == 200, "container read via aad-form auth: #{status} #{body}"

    # SDK upsert (POST doc with x-ms-documentdb-is-upsert) via the aad form.
    {wstatus, wbody} =
      authed(
        :post,
        :aad,
        base,
        cert,
        "/dbs/#{db}/colls/#{coll}/docs",
        Jason.encode!(%{"id" => "d1", "v" => 1}),
        [
          "Content-Type: application/json",
          "x-ms-version: 2018-12-31",
          "x-ms-documentdb-is-upsert: true"
        ],
        auth_form: :aad
      )

    assert wstatus == 201, "upsert via aad-form auth: #{wstatus} #{wbody}"
    assert Jason.decode!(wbody)["id"] == "d1"

    # Point read via the aad form sees the doc.
    {rstatus, rbody} =
      authed(
        :get,
        :aad,
        base,
        cert,
        "/dbs/#{db}/colls/#{coll}/docs/d1",
        nil,
        [
          "x-ms-version: 2018-12-31"
        ],
        auth_form: :aad
      )

    assert rstatus == 200, "doc read via aad-form auth: #{rstatus} #{rbody}"

    # Bearer transport reads the same doc too (one namespace across forms).
    {bstatus, bbody} =
      authed(:get, :aad, base, cert, "/dbs/#{db}/colls/#{coll}/docs/d1", nil, [
        "x-ms-version: 2018-12-31"
      ])

    assert bstatus == 200, "doc read via Bearer auth: #{bstatus} #{bbody}"
  end

  test "home-tenant chain: db -> coll -> container read -> upsert -> point read, each step" do
    {base, cert} = twin()
    ts = System.system_time(:millisecond)
    db = "v21-home-#{ts}"
    coll = "cases"

    assert {201, _} =
             authed(:post, :home, base, cert, "/dbs", Jason.encode!(%{"id" => db}), [
               "Content-Type: application/json"
             ])

    assert {201, _} =
             authed(
               :post,
               :home,
               base,
               cert,
               "/dbs/#{db}/colls",
               Jason.encode!(%{"id" => coll}),
               [
                 "Content-Type: application/json",
                 "x-ms-version: 2018-12-31"
               ]
             )

    assert {200, _} =
             authed(:get, :home, base, cert, "/dbs/#{db}/colls/#{coll}", nil, [
               "x-ms-version: 2018-12-31"
             ])

    assert {201, body} =
             authed(
               :post,
               :home,
               base,
               cert,
               "/dbs/#{db}/colls/#{coll}/docs",
               Jason.encode!(%{"id" => "h1", "v" => 1}),
               [
                 "Content-Type: application/json",
                 "x-ms-version: 2018-12-31",
                 "x-ms-documentdb-is-upsert: true"
               ]
             )

    assert Jason.decode!(body)["id"] == "h1"

    assert {200, body} =
             authed(:get, :home, base, cert, "/dbs/#{db}/colls/#{coll}/docs/h1", nil, [
               "x-ms-version: 2018-12-31"
             ])

    assert Jason.decode!(body)["id"] == "h1"
  end

  # -------------------------------------------------------------------------

  defp twin do
    port = Application.fetch_env!(:smalt, :arm_tls_port)
    {cert, _key} = Smalt.TLS.dev_cert_paths(port)
    {"https://127.0.0.1:#{port}", cert}
  end

  defp authed(method, tenant, base, cert, path, body, extra_headers, opts \\ []) do
    aad_form? = Keyword.get(opts, :auth_form, :bearer) == :aad
    key = if tenant == :home, do: @token_key_home, else: @token_key_aad

    case :persistent_term.get(key, nil) do
      nil ->
        :persistent_term.put(key, fetch_sts_token(base, cert, tenant))
        authed(method, tenant, base, cert, path, body, extra_headers, opts)

      _tok ->
        headers =
          extra_headers ++
            if aad_form? do
              tok = :persistent_term.get(key)
              ["Authorization: type=aad&ver=1.0&sig=#{tok}"]
            else
              ["Authorization: Bearer #{:persistent_term.get(key)}"]
            end

        case request_body(method, base, cert, path, body, headers) do
          {401, _} ->
            :persistent_term.put(key, fetch_sts_token(base, cert, tenant))
            authed(method, tenant, base, cert, path, body, extra_headers, opts)

          other ->
            other
        end
    end
  end

  # Real STS issuer on the twin: POST /{tenant}/oauth2/v2.0/token — the mint
  # stamps tid from the PATH tenant.
  defp fetch_sts_token(base, cert, tenant) do
    tid = if tenant == :home, do: "smalt-tenant", else: "common"

    args = [
      "-s",
      "--cacert",
      cert,
      "-X",
      "POST",
      "-d",
      "grant_type=client_credentials&client_id=v21-lane&client_secret=v21-lane&scope=https://management.azure.com/.default",
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

    case String.split(out, "\n", trim: false) do
      parts ->
        code = parts |> List.last() |> String.trim() |> String.to_integer()
        body_out = parts |> Enum.drop(-1) |> Enum.join("\n")
        {code, body_out}
    end
  end

  defp header_args(headers), do: Enum.flat_map(headers, &["-H", &1])

  defp body_args(nil), do: []
  defp body_args(body), do: ["-d", body]
end
