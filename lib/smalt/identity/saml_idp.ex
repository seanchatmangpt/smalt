defmodule Smalt.Identity.SamlIdp do
  @moduledoc """
  Minimal Entra-shaped SAML 2.0 IdP face for the identity plane.

  Serves:
    - `GET /metadata` — IdP entity metadata (entityID, signing KeyDescriptor
      carrying the DER base64 X509Certificate, POST SingleSignOnService).
    - `GET|POST /sso` — accepts a SAML AuthnRequest (REDIRECT binding:
      DEFLATE raw + base64; also POST binding: plain base64 XML), mints one
      RSA-SHA256-signed Assertion inside a `samlp:Response` and answers with
      an auto-submit HTML form targeting the request's
      AssertionConsumerServiceURL.

  Config (`config :smalt, :saml_idp, ...`):
    - `:entity_id`  (default `urn:smalt:identity:saml`)
    - `:base_url`   (default `http://<bind ip>:<port>`)
    - `:cert_path`  / `:key_path` (default `.smalt/tls/dev-cert.pem` / dev-key)
    - `:allowed_acs` (exact-URL allowlist for non-loopback ACS values)
    - `:name_id` / `:groups` (single-user claim shape)

  Key material is loaded lazily and cached in `:persistent_term`. Digests
  and signatures are computed over EXCLUSIVE-C14N bytes of the emitted
  elements (`Smalt.Identity.SamlSlo.canonicalize/1`) — the exact
  transformation an enveloped-signature verifier (xml-crypto / node-saml /
  lxml) applies before digesting; the raw emitted string is never the signed
  byte range.
  """

  use Plug.Router

  alias Smalt.Identity.SamlSlo

  import Record

  defrecord :xmlElement, extract(:xmlElement, from_lib: "xmerl/include/xmerl.hrl")
  defrecord :xmlAttribute, extract(:xmlAttribute, from_lib: "xmerl/include/xmerl.hrl")
  defrecord :xmlText, extract(:xmlText, from_lib: "xmerl/include/xmerl.hrl")

  @entity_id_default "urn:smalt:identity:saml"
  @name_id_default "smalt-user"
  @groups_default ["smalt-admin"]
  @validity_seconds 5 * 60
  @clock_skew_seconds 60

  @logout_request_re ~r/(<[\w.:-]*LogoutRequest\b.*<\/[\w.:-]*LogoutRequest>)/s

  plug Plug.Parsers,
    parsers: [:urlencoded],
    pass: ["*/*"]

  plug :match
  plug :dispatch

  get "/metadata" do
    conn
    |> put_resp_content_type("application/samlmetadata+xml")
    |> send_resp(200, metadata_xml())
  end

  get "/sso" do
    handle_sso(conn, conn.query_params)
  end

  post "/sso" do
    handle_sso(conn, conn.body_params)
  end

  # T04 SLO face: SP-initiated logout (REDIRECT + POST bindings), IdP-
  # initiated logout face.
  get "/slo" do
    handle_slo(conn, conn.query_params)
  end

  post "/slo" do
    handle_slo(conn, conn.body_params)
  end

  get "/slo/initiate" do
    handle_slo_initiate(conn)
  end

  post "/slo/initiate" do
    handle_slo_initiate(conn)
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  # ------------------------------------------------------------------
  # Child spec (Bandit plug server)
  # ------------------------------------------------------------------

  @doc false
  def child_spec(opts) when is_list(opts) do
    port = Keyword.get(opts, :port, Application.get_env(:smalt, :saml_idp_port, 9445))

    %{
      id: {__MODULE__, port},
      start:
        {Bandit, :start_link,
         [
           [
             plug: {__MODULE__, []},
             scheme: :http,
             port: port,
             ip: bind_ip()
           ]
         ]},
      type: :worker,
      restart: :permanent,
      shutdown: 10_000
    }
  end

  # ------------------------------------------------------------------
  # SSO flow
  # ------------------------------------------------------------------

  defp handle_sso(conn, params) do
    case params["SAMLRequest"] do
      saml_request when is_binary(saml_request) ->
        mint_and_respond(conn, saml_request, params["RelayState"])

      _ ->
        typed_bad_request(conn, "MISSING_SAML_REQUEST")
    end
  end

  defp mint_and_respond(conn, saml_request_b64, relay_state) do
    relay_state = if relay_state in [nil, ""], do: nil, else: relay_state

    with {:ok, request_xml} <- decode_request(saml_request_b64),
         {:ok, request} <- parse_authn_request(request_xml),
         :ok <- validate_acs(request.acs) do
      html = auto_submit_form(request.acs, mint_response_b64(request, relay_state), relay_state)

      conn
      |> put_resp_content_type("text/html")
      |> send_resp(200, html)
    else
      {:error, reason} -> typed_bad_request(conn, reason)
    end
  end

  defp typed_bad_request(conn, code) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(400, Jason.encode!(%{error: code}))
  end

  @doc """
  Decodes a SAMLRequest: REDIRECT binding (DEFLATE raw + base64) or POST
  binding (plain base64 XML).
  """
  def decode_request(b64) do
    case Base.decode64(b64, ignore: :whitespace) do
      {:ok, raw} ->
        cond do
          xml?(raw) -> {:ok, raw}
          inflated = safe_inflate(raw) -> {:ok, inflated}
          true -> {:error, "UNPARSEABLE_SAML_REQUEST"}
        end

      :error ->
        {:error, "UNPARSEABLE_SAML_REQUEST"}
    end
  end

  defp xml?(raw), do: raw |> String.trim_leading() |> String.starts_with?("<")

  defp safe_inflate(raw) do
    # DEFLATE raw (no zlib header) — the SAML REDIRECT binding shape.
    try do
      case :zlib.unzip(raw) do
        xml when is_binary(xml) -> xml
        _ -> nil
      end
    rescue
      _ -> nil
    end
  end

  # ------------------------------------------------------------------
  # SLO flow (T04)
  # ------------------------------------------------------------------

  defp handle_slo(conn, params) do
    case params["SAMLRequest"] do
      saml_request when is_binary(saml_request) ->
        consume_logout(conn, saml_request, params["RelayState"])

      _ ->
        typed_bad_request(conn, "MISSING_SAML_REQUEST")
    end
  end

  defp consume_logout(conn, saml_request_b64, relay_state) do
    relay_state = if relay_state in [nil, ""], do: nil, else: relay_state

    with {:ok, request_xml} <- decode_request(saml_request_b64),
         {:ok, request} <- SamlSlo.parse_logout_request(request_xml),
         :ok <- verify_slo_signature(request_xml, conn, relay_state) do
      case SamlSlo.validate_and_consume(request) do
        :ok ->
          respond_with_logout_response(conn, request.id, relay_state)

        {:error, reason} ->
          typed_bad_request(conn, reason)
      end
    else
      {:error, reason} -> typed_bad_request(conn, reason)
    end
  end

  # Signature law: a PRESENT signature must verify (enveloped XML on the
  # POST binding, query-string signature on REDIRECT) — else typed refusal.
  # An ABSENT signature is lawful: metadata advertises
  # WantAuthnRequestsSigned="false".
  defp verify_slo_signature(request_xml, conn, _relay_state) do
    cond do
      SamlSlo.signed?(request_xml) ->
        case SamlSlo.verify_enveloped_signature(request_xml, @logout_request_re) do
          :ok -> :ok
          {:error, _reason} -> {:error, "INVALID_SIGNATURE"}
        end

      binding_has_query?(conn) and redirect_signature_present?(conn) ->
        case SamlSlo.verify_redirect_signature(conn.query_string) do
          :ok -> :ok
          {:error, _} -> {:error, "INVALID_SIGNATURE"}
        end

      true ->
        :ok
    end
  end

  defp binding_has_query?(conn), do: conn.method == "GET" and conn.query_string != ""

  defp redirect_signature_present?(conn) do
    conn.query_string
    |> String.split("&")
    |> Enum.any?(&String.starts_with?(&1, "Signature="))
  end

  defp respond_with_logout_response(conn, in_response_to, relay_state) do
    xml = SamlSlo.logout_response_xml(in_response_to, SamlSlo.slo_response_url())

    if is_binary(SamlSlo.slo_response_url()) do
      conn
      |> put_resp_content_type("text/html")
      |> send_resp(200, auto_submit_form(SamlSlo.slo_response_url(), Base.encode64(xml), relay_state))
    else
      conn
      |> put_resp_content_type("application/samlmetadata+xml")
      |> send_resp(200, xml)
    end
  end

  defp handle_slo_initiate(conn) do
    case SamlSlo.slo_sp_slo_url() do
      nil ->
        typed_bad_request(conn, "SP_SLO_URL_UNCONFIGURED")

      sp_slo_url ->
        name_id = name_id()
        xml = SamlSlo.logout_request_xml(name_id, nil, sp_slo_url)
        html = auto_submit_form(sp_slo_url, Base.encode64(xml), nil, "SAMLRequest")

        conn
        |> put_resp_content_type("text/html")
        |> send_resp(200, html)
    end
  end

  @doc false
  def parse_authn_request(xml) do
    with {:ok, doc} <- scan(xml),
         root when root != nil <- Enum.find(flatten(doc), fn n -> is_record(n, :xmlElement) and local_name(xmlElement(n, :name)) == "AuthnRequest" end) do
      id = attr(root, "ID")
      acs = attr(root, "AssertionConsumerServiceURL")

      if is_binary(id) and is_binary(acs) do
        {:ok, %{id: id, acs: acs, issuer: text_of_child(root, "Issuer") || ""}}
      else
        {:error, "INVALID_AUTHNREQUEST"}
      end
    else
      _ -> {:error, "UNPARSEABLE_SAML_REQUEST"}
    end
  end

  # ------------------------------------------------------------------
  # ACS validation law
  # ------------------------------------------------------------------

  @doc """
  The AssertionConsumerServiceURL must be an http(s) URL on a loopback host,
  or an exact match against the `:allowed_acs` config allowlist. Otherwise a
  typed refusal — the IdP never auto-posts a signed assertion to an
  arbitrary destination.
  """
  def validate_acs(acs) do
    cond do
      not is_binary(acs) ->
        {:error, "INVALID_ACS"}

      acs in allowed_acs() ->
        :ok

      true ->
        case URI.new(acs) do
          {:ok, %URI{scheme: scheme, host: host}}
          when scheme in ["http", "https"] and is_binary(host) ->
            if loopback_host?(host), do: :ok, else: {:error, "ACS_NOT_LOOPBACK"}

          _ ->
            {:error, "INVALID_ACS"}
        end
    end
  end

  defp allowed_acs do
    Application.get_env(:smalt, :saml_idp, []) |> Keyword.get(:allowed_acs, [])
  end

  defp loopback_host?(host) do
    host in ["localhost", "::1", "[::1]"] or String.starts_with?(host, "127.")
  end

  # ------------------------------------------------------------------
  # Response / assertion minting
  # ------------------------------------------------------------------

  @doc """
  Mints the base64 SAMLResponse for an AuthnRequest map
  `%{id: request_id, acs: acs_url, issuer: issuer}`. Public for court use:
  the test decodes, parses and signature-verifies against the embedded cert.
  """
  def mint_response_b64(request, relay_state \\ nil) do
    request
    |> mint_response(relay_state)
    |> Base.encode64()
  end

  @doc false
  def mint_response(request, _relay_state \\ nil) do
    now = System.system_time(:second)
    assertion_id = "_smalt" <> unique_id()
    response_id = "_smalt" <> unique_id()

    # T04: track the (NameID, SessionIndex) pair this sign-in issues, so a
    # later LogoutRequest validates meaningfully.
    SamlSlo.record_session(name_id(), assertion_id)

    assertion = signed_assertion(assertion_id, request, now)

    response =
      """
      <samlp:Response xmlns:samlp="urn:oasis:names:tc:SAML:2.0:protocol" xmlns:saml="urn:oasis:names:tc:SAML:2.0:assertion" ID="#{xml_escape(response_id)}" Version="2.0" IssueInstant="#{xs_datetime(now)}" Destination="#{xml_escape(request.acs)}" InResponseTo="#{xml_escape(request.id)}"><saml:Issuer>#{xml_escape(entity_id())}</saml:Issuer><samlp:Status><samlp:StatusCode Value="urn:oasis:names:tc:SAML:2.0:status:Success"/></samlp:Status>#{assertion}</samlp:Response>
      """
      |> String.trim_trailing("\n")

    # node-saml's wantAuthnResponseSigned defaults TRUE: the consumer
    # validator requires a Response-level (document) signature in addition
    # to the signed assertion. Digest over the INCLUSIVE-C14N bytes of the
    # Response-minus-signature (assertion signature rides inside as data);
    # insert after the Response's own Issuer (first occurrence in doc order).
    canonical = SamlSlo.canonicalize(response)
    digest = :crypto.hash(:sha256, canonical)
    response_signature = signature_with_value(signature_xml(digest, response_id))

    String.replace(response, "</saml:Issuer>", "</saml:Issuer>" <> response_signature, global: false)
  end

  # The assertion is minted unsigned, digested over its INCLUSIVE-C14N bytes
  # (the reference transform the operative consumer validator applies —
  # xml-crypto appends REC-xml-c14n implicitly; raw-string digests are the
  # defect class FINISH-WIRE wire-witnessed: node-saml "Invalid document
  # signature"), and the Signature is inserted immediately after Issuer —
  # the standard enveloped-signature position.
  defp signed_assertion(assertion_id, request, now) do
    unsigned = assertion_xml(assertion_id, request, now)
    canonical = SamlSlo.canonicalize(unsigned)
    digest = :crypto.hash(:sha256, canonical)
    signature = signature_with_value(signature_xml(digest, assertion_id))

    String.replace(unsigned, "</saml:Issuer>", "</saml:Issuer>" <> signature, global: false)
  end

  defp assertion_xml(assertion_id, request, now) do
    not_before = xs_datetime(now - @clock_skew_seconds)
    not_after = xs_datetime(now + @validity_seconds)

    attributes =
      # Entra-shaped claims (S3 landing, wired by coordinator v26.10.30):
      # the consumer's mapProfile/2 reads the EXACT Entra claim URIs
      # (objectidentifier, tenantid, displayname, groups, role). The bare
      # `groups` attribute minted nothing the authz policy could fence on
      # (court witness: tenant_mismatch at claims.ts:92).
      # EntraClaims.attribute_statement_xml/1 mints the full set; the
      # legacy `groups` attribute still appends for non-Entra consumers.
      # EntraClaims mints its OWN <saml:AttributeStatement> wrapper —
      # nesting it inside the assertion's statement buries the claims one
      # element too deep (node-saml's xml2js read only the outer node:
      # profile = {groups} only, coordinator witness 11:0xZ). Unwrap.
      case Smalt.Identity.EntraClaims.attribute_statement_xml([]) do
        xml when is_binary(xml) and xml != "" ->
          xml
          |> String.replace_prefix("<saml:AttributeStatement>", "")
          |> String.replace_suffix("</saml:AttributeStatement>", "")

        _ ->
          ""
      end <>
        Enum.join(
          groups()
          |> Enum.map(fn group ->
            ~s(<saml:Attribute Name="groups" NameFormat="urn:oasis:names:tc:SAML:2.0:attrname-format:basic"><saml:AttributeValue>#{xml_escape(group)}</saml:AttributeValue></saml:Attribute>)
          end)
        )

    """
    <saml:Assertion xmlns:saml="urn:oasis:names:tc:SAML:2.0:assertion" xmlns:samlp="urn:oasis:names:tc:SAML:2.0:protocol" ID="#{xml_escape(assertion_id)}" Version="2.0" IssueInstant="#{xs_datetime(now)}"><saml:Issuer>#{xml_escape(entity_id())}</saml:Issuer><saml:Subject><saml:NameID Format="urn:oasis:names:tc:SAML:2.0:nameid-format:unspecified">#{xml_escape(name_id())}</saml:NameID><saml:SubjectConfirmation Method="urn:oasis:names:tc:SAML:2.0:cm:bearer"><saml:SubjectConfirmationData Recipient="#{xml_escape(request.acs)}" InResponseTo="#{xml_escape(request.id)}" NotOnOrAfter="#{not_after}"/></saml:SubjectConfirmation></saml:Subject><saml:Conditions NotBefore="#{not_before}" NotOnOrAfter="#{not_after}">#{audience_element(request.issuer)}</saml:Conditions><saml:AuthnStatement AuthnInstant="#{xs_datetime(now)}" SessionIndex="#{xml_escape(assertion_id)}"><saml:AuthnContext><saml:AuthnContextClassRef>urn:oasis:names:tc:SAML:2.0:ac:classes:PasswordProtectedTransport</saml:AuthnContextClassRef></saml:AuthnContext></saml:AuthnStatement><saml:AttributeStatement>#{attributes}</saml:AttributeStatement></saml:Assertion>
    """
    |> String.trim_trailing("\n")
  end

  # Returns the <ds:SignedInfo> element (emitted shape). Reference
  # transforms declare what is actually digested: enveloped-signature +
  # INCLUSIVE C14N; SignatureValue is computed over the exc-C14N of
  # SignedInfo (the declared CanonicalizationMethod).
  defp signature_xml(digest, assertion_id) do
    ~s(<ds:SignedInfo xmlns:ds="http://www.w3.org/2000/09/xmldsig#"><ds:CanonicalizationMethod Algorithm="http://www.w3.org/2001/10/xml-exc-c14n#"/><ds:SignatureMethod Algorithm="http://www.w3.org/2001/04/xmldsig-more#rsa-sha256"/><ds:Reference URI="##{xml_escape(assertion_id)}"><ds:Transforms><ds:Transform Algorithm="http://www.w3.org/2000/09/xmldsig#enveloped-signature"/><ds:Transform Algorithm="http://www.w3.org/TR/2001/REC-xml-c14n-20010315"/></ds:Transforms><ds:DigestMethod Algorithm="http://www.w3.org/2001/04/xmlenc#sha256"/><ds:DigestValue>#{Base.encode64(digest)}</ds:DigestValue></ds:Reference></ds:SignedInfo>)
  end

  defp signature_with_value(signed_info) do
    signed_info_canonical = SamlSlo.canonicalize_exc(signed_info)

    signature_value =
      signed_info_canonical
      |> :public_key.sign(:sha256, private_key())
      |> Base.encode64()

    ~s(<ds:Signature xmlns:ds="http://www.w3.org/2000/09/xmldsig#">) <>
      signed_info <>
      ~s(<ds:SignatureValue>) <>
      signature_value <>
      ~s(</ds:SignatureValue><ds:KeyInfo><ds:X509Data><ds:X509Certificate>) <>
      der_cert_b64() <>
      ~s(</ds:X509Certificate></ds:X509Data></ds:KeyInfo></ds:Signature>)
  end

  # ------------------------------------------------------------------
  # Metadata
  # ------------------------------------------------------------------

  @doc false
  def metadata_xml do
    base = base_url()

    """
    <EntityDescriptor xmlns="urn:oasis:names:tc:SAML:2.0:metadata" xmlns:ds="http://www.w3.org/2000/09/xmldsig#" entityID="#{xml_escape(entity_id())}"><IDPSSODescriptor WantAuthnRequestsSigned="false" protocolSupportEnumeration="urn:oasis:names:tc:SAML:2.0:protocol"><KeyDescriptor use="signing"><ds:KeyInfo><ds:X509Data><ds:X509Certificate>#{der_cert_b64()}</ds:X509Certificate></ds:X509Data></ds:KeyInfo></KeyDescriptor><NameIDFormat>urn:oasis:names:tc:SAML:2.0:nameid-format:unspecified</NameIDFormat><SingleSignOnService Binding="urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST" Location="#{xml_escape(base <> "/sso")}"/><SingleLogoutService Binding="urn:oasis:names:tc:SAML:2.0:bindings:HTTP-Redirect" Location="#{xml_escape(base <> "/slo")}"/><SingleLogoutService Binding="urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST" Location="#{xml_escape(base <> "/slo")}"/></IDPSSODescriptor></EntityDescriptor>
    """
    |> String.trim_trailing("\n")
  end

  # ------------------------------------------------------------------
  # Auto-submit form
  # ------------------------------------------------------------------

  defp auto_submit_form(acs, saml_field_b64, relay_state, field_name \\ "SAMLResponse") do
    relay_state_attr =
      case relay_state do
        nil -> ""
        rs -> ~s( name="RelayState" value="#{xml_attr_escape(rs)}")
      end

    body =
      "<!DOCTYPE html><html><body onload=\"document.forms[0].submit()\">" <>
        ~s(<form method="POST" action="#{xml_attr_escape(acs)}">) <>
        ~s(<input type="hidden" name="#{field_name}" value="#{xml_attr_escape(saml_field_b64)}"#{relay_state_attr}/>) <>
        ~s(<noscript><input type="submit"/></noscript></form></body></html>)

    body
  end

  # ------------------------------------------------------------------
  # Config accessors
  # ------------------------------------------------------------------

  defp saml_config, do: Application.get_env(:smalt, :saml_idp, [])

  defp entity_id, do: saml_config() |> Keyword.get(:entity_id, @entity_id_default)
  defp name_id, do: saml_config() |> Keyword.get(:name_id, @name_id_default)
  defp groups, do: saml_config() |> Keyword.get(:groups, @groups_default)
  defp audience, do: saml_config() |> Keyword.get(:audience)

  # The SP entity ID this IdP mints assertions FOR (Entra-shaped
  # AudienceRestriction; consumer validates audience). Falls back to the
  # AuthnRequest Issuer (the SP entity ID from the request) when
  # unconfigured — a real IdP always names the audience it saw in the
  # request. Coordinator patch v26.10.29 (witness: court r3 leg-3C
  # rejection "SAML assertion has no AudienceRestriction" at 08:43Z).
  defp audience_element(request_issuer) do
    case audience() || request_issuer do
      nil -> ""
      sp_entity -> "<saml:AudienceRestriction><saml:Audience>#{xml_escape(sp_entity)}</saml:Audience></saml:AudienceRestriction>"
    end
  end

  defp base_url do
    case saml_config() |> Keyword.get(:base_url) do
      nil ->
        port = Application.get_env(:smalt, :saml_idp_port, 9445)
        "http://" <> host_str(bind_ip()) <> ":#{port}"

      url ->
        url
    end
  end

  # The bind_ip law (Smalt.DataPlane.RedisWire.bind_ip/0 precedent,
  # KIND-E2E r13 item 3: a raw SMALT_BIND_IP string passed to Bandit is
  # :badarg at boot): nil/"loopback" -> loopback, binary ->
  # :inet.parse_address fail-closed, tuple -> itself.
  @spec bind_ip() :: :inet.ip_address()
  def bind_ip do
    case Smalt.Config.bind_ip() do
      nil -> {127, 0, 0, 1}
      "loopback" -> {127, 0, 0, 1}

      str when is_binary(str) ->
        case :inet.parse_address(String.to_charlist(str)) do
          {:ok, ip} -> ip
          {:error, _} -> raise ArgumentError, "SMALT_BIND_IP=#{str} is not a valid IPv4/IPv6 address"
        end

      ip when is_tuple(ip) ->
        ip
    end
  end

  defp host_str(ip) when is_tuple(ip), do: ip |> :inet.ntoa() |> to_string()
  defp host_str(ip) when is_binary(ip), do: ip

  defp cert_path, do: saml_config() |> Keyword.get(:cert_path, ".smalt/tls/dev-cert.pem")
  defp key_path, do: saml_config() |> Keyword.get(:key_path, ".smalt/tls/dev-key.pem")

  # ------------------------------------------------------------------
  # Key material (lazy, :persistent_term cached)
  # ------------------------------------------------------------------

  defp key_material do
    case :persistent_term.get({__MODULE__, :key_material}, :absent) do
      :absent ->
        material = load_key_material()

        :persistent_term.put({__MODULE__, :key_material}, material)
        material

      material ->
        material
    end
  end

  defp load_key_material do
    cert_pem = read_pem(cert_path())
    key_pem = read_pem(key_path())

    cert_entry = Enum.find(cert_pem, fn {type, _, _} -> type == :Certificate end)
    key_entry = Enum.find(key_pem, fn {type, _, _} -> type in [:"RSAPrivateKey", :"PrivateKeyInfo"] end)

    true = cert_entry != nil and key_entry != nil

    {:"Certificate", der_cert, :not_encrypted} = cert_entry
    cert = :public_key.pkix_decode_cert(der_cert, :otp)
    key = :public_key.pem_entry_decode(key_entry)

    %{der_cert: der_cert, cert: cert, key: key}
  end

  defp read_pem(path) do
    expanded = if Path.absname(path) == path, do: path, else: Path.join(File.cwd!(), path)

    case File.read(expanded) do
      {:ok, content} -> :public_key.pem_decode(content)
      {:error, reason} -> raise "SamlIdp: cannot read PEM #{expanded}: #{inspect(reason)}"
    end
  end

  defp der_cert_b64, do: key_material().der_cert |> Base.encode64()
  defp private_key, do: key_material().key

  @doc """
  The decoded OTP certificate backing the IdP signing key. Court-facing
  (signature verification against the embedded cert).
  """
  def signing_cert, do: key_material().cert

  @doc false
  def signing_material, do: key_material()

  # ------------------------------------------------------------------
  # xmerl helpers
  # ------------------------------------------------------------------

  defp scan(xml) do
    case :xmerl_scan.string(String.to_charlist(xml)) do
      {doc, _} -> {:ok, flatten(List.wrap(doc))}
      _ -> {:error, :scan}
    end
  rescue
    e -> {:error, {:scan, Exception.message(e)}}
  end

  # xmerl keeps prefixed tag names as-is (e.g. :"saml:Assertion"); courts
  # match on the local-name suffix so either shape parses.
  defp flatten(nodes, acc \\ [])
  defp flatten([], acc), do: acc

  defp flatten([node | rest], acc) when is_record(node, :xmlElement) do
    flatten(xmlElement(node, :content) ++ rest, [node | acc])
  end

  defp flatten([node | rest], acc) when is_list(node), do: flatten(node ++ rest, acc)
  defp flatten([_text | rest], acc), do: flatten(rest, acc)

  defp local_name(name) when is_atom(name) do
    name
    |> Atom.to_string()
    |> String.split(":")
    |> List.last()
  end

  defp attr(node, name) do
    xmlElement(node, :attributes)
    |> Enum.find_value(fn
      a when is_record(a, :xmlAttribute) ->
        if xmlAttribute(a, :name) == String.to_atom(name), do: to_string(xmlAttribute(a, :value))

      _ ->
        nil
    end)
  end

  defp text_of_child(node, name) do
    xmlElement(node, :content)
    |> Enum.find_value(fn
      child when is_record(child, :xmlElement) ->
        if local_name(xmlElement(child, :name)) == name do
          text =
            xmlElement(child, :content)
            |> Enum.map_join("", fn t when is_record(t, :xmlText) -> to_string(xmlText(t, :value)); _ -> "" end)

          if text == "", do: nil, else: String.trim(text)
        end

      _ ->
        nil
    end)
  end

  defp xs_datetime(seconds) do
    seconds
    |> DateTime.from_unix!()
    |> Calendar.strftime("%Y-%m-%dT%H:%M:%SZ")
  end

  defp unique_id, do: :crypto.strong_rand_bytes(16) |> Base.encode32(padding: false) |> String.downcase()

  defp xml_escape(v) when is_binary(v) do
    v
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end

  # Attribute-position escaping: escape the quote character last so the
  # attribute value can never terminate the attribute.
  defp xml_attr_escape(v), do: xml_escape(v)
end
