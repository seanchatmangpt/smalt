defmodule Smalt.Identity.EntraSaml do
  @moduledoc """
  Entra-shaped SAML 2.0 IdP face (lane S3, r16; census rows R7/R8/R9).

  An additive sibling face to `Smalt.Identity.SamlIdp` that mints the FULL
  Entra attribute surface via `Smalt.Identity.EntraClaims` (the claim shapes
  courtroom-platform-az's claims.ts reads) plus the Entra NameID/issuer/
  audience shape:

    * entityID `https://sts.windows.net/{tid}/` (the consumer SAML_IDP_ISSUER
      derivation default, config.ts:152-156)
    * NameID `urn:oasis:names:tc:SAML:1.1:nameid-format:unspecified` with the
      UPN value (consumer SAML_NAMEID_FORMAT default, config.ts:245)
    * Conditions carrying an AudienceRestriction for the SP entity
      (node-saml validates audience = consumer SAML_ISSUER)
    * the full Entra claim set (groups GUIDs, role, tenantid, oid, amr,
      displayname, name=UPN, email, givenname, surname, groups.link on
      overage)
    * enveloped RSA-SHA256 signatures on BOTH the assertion and the Response
      (INCLUSIVE-C14N digests; the SamlIdp technique recomputed here so this
      file is self-contained - disclosed duplication in r16)

  Faces: GET /metadata, GET|POST /sso, GET|POST /slo. Config
  `config :smalt, :entra_saml, ...`: `:base_url`, `:entity_id`,
  `:name_id_format`, `:allowed_acs` (delegated check).

  Request parsing, ACS validation law and SLO session law delegate to the
  public faces of `SamlIdp` (decode_request/1, parse_authn_request/1,
  validate_acs/1) and `SamlSlo` (canonicalization, session records,
  LogoutRequest parse/consume) - read-only reuse, zero edits to the
  L16-owned files.
  """

  use Plug.Router

  alias Smalt.Identity.EntraClaims
  alias Smalt.Identity.SamlIdp
  alias Smalt.Identity.SamlSlo

  @name_id_format_default "urn:oasis:names:tc:SAML:1.1:nameid-format:unspecified"
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

  get "/slo" do
    handle_slo(conn, conn.query_params)
  end

  post "/slo" do
    handle_slo(conn, conn.body_params)
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  # ------------------------------------------------------------------
  # Child spec (Bandit plug server) - the SamlIdp child_spec pattern
  # ------------------------------------------------------------------

  @doc false
  def child_spec(opts) when is_list(opts) do
    port = Keyword.get(opts, :port, Application.get_env(:smalt, :entra_saml_port, 9446))

    %{
      id: {__MODULE__, port},
      start:
        {Bandit, :start_link,
         [
           [
             plug: {__MODULE__, []},
             scheme: :http,
             port: port,
             ip: Smalt.Config.bind_ip() || {127, 0, 0, 1}
           ]
         ]},
      type: :worker,
      restart: :permanent,
      shutdown: 10_000
    }
  end

  # ------------------------------------------------------------------
  # Config accessors (public for courts)
  # ------------------------------------------------------------------

  @doc "Effective `config :smalt, :entra_saml` (or `[]`)."
  def saml_config, do: Application.get_env(:smalt, :entra_saml, [])

  @doc "The IdP entityID (default `https://sts.windows.net/{tid}/`)."
  def entity_id do
    case saml_config() |> Keyword.get(:entity_id) do
      nil -> "https://sts.windows.net/#{EntraClaims.resolve()[:tenant_id]}/"
      eid when is_binary(eid) -> eid
    end
  end

  @doc "The face base URL (default derived from the configured port)."
  def base_url do
    case saml_config() |> Keyword.get(:base_url) do
      nil ->
        port = Application.get_env(:smalt, :entra_saml_port, 9446)
        ip = Smalt.Config.bind_ip() || {127, 0, 0, 1}
        "http://" <> host_str(ip) <> ":#{port}"

      url when is_binary(url) ->
        url
    end
  end

  @doc "The minted NameID Format URI."
  def name_id_format, do: saml_config() |> Keyword.get(:name_id_format, @name_id_format_default)

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

    with {:ok, request_xml} <- SamlIdp.decode_request(saml_request_b64),
         {:ok, request} <- SamlIdp.parse_authn_request(request_xml),
         :ok <- SamlIdp.validate_acs(request.acs) do
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

  # ------------------------------------------------------------------
  # Response / assertion minting (Entra shape)
  # ------------------------------------------------------------------

  @doc """
  Mints the base64 SAMLResponse for an AuthnRequest map
  `%{id: request_id, acs: acs_url, issuer: issuer}` with the full Entra
  claim set. Public for court use.
  """
  def mint_response_b64(request, relay_state \\ nil) do
    request |> mint_response(relay_state) |> Base.encode64()
  end

  @doc false
  def mint_response(request, _relay_state \\ nil) do
    now = System.system_time(:second)
    assertion_id = "_smalt" <> unique_id()
    response_id = "_smalt" <> unique_id()

    # SLO session law (same as SamlIdp): track (NameID, SessionIndex) so a
    # later LogoutRequest validates meaningfully.
    SamlSlo.record_session(name_id(), assertion_id)

    assertion = signed_assertion(assertion_id, request, now)

    response =
      """
      <samlp:Response xmlns:samlp="urn:oasis:names:tc:SAML:2.0:protocol" xmlns:saml="urn:oasis:names:tc:SAML:2.0:assertion" ID="#{xml_escape(response_id)}" Version="2.0" IssueInstant="#{xs_datetime(now)}" Destination="#{xml_escape(request.acs)}" InResponseTo="#{xml_escape(request.id)}"><saml:Issuer>#{xml_escape(entity_id())}</saml:Issuer><samlp:Status><samlp:StatusCode Value="urn:oasis:names:tc:SAML:2.0:status:Success"/></samlp:Status>#{assertion}</samlp:Response>
      """
      |> String.trim_trailing("\n")

    # node-saml validates the Response-level signature when
    # wantAuthnResponseSigned is set; mint BOTH signatures unconditionally
    # (the SamlIdp shape), digested over the INCLUSIVE-C14N bytes of the
    # element minus its own Signature.
    canonical = SamlSlo.canonicalize(response)
    digest = :crypto.hash(:sha256, canonical)
    response_signature = signature_with_value(signature_xml(digest, response_id))

    String.replace(response, "</saml:Issuer>", "</saml:Issuer>" <> response_signature, global: false)
  end

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
    claims = EntraClaims.resolve()

    """
    <saml:Assertion xmlns:saml="urn:oasis:names:tc:SAML:2.0:assertion" xmlns:samlp="urn:oasis:names:tc:SAML:2.0:protocol" ID="#{xml_escape(assertion_id)}" Version="2.0" IssueInstant="#{xs_datetime(now)}"><saml:Issuer>#{xml_escape(entity_id())}</saml:Issuer><saml:Subject><saml:NameID Format="#{xml_escape(name_id_format())}">#{xml_escape(claims.upn)}</saml:NameID><saml:SubjectConfirmation Method="urn:oasis:names:tc:SAML:2.0:cm:bearer"><saml:SubjectConfirmationData Recipient="#{xml_escape(request.acs)}" InResponseTo="#{xml_escape(request.id)}" NotOnOrAfter="#{not_after}"/></saml:SubjectConfirmation></saml:Subject><saml:Conditions NotBefore="#{not_before}" NotOnOrAfter="#{not_after}"><saml:AudienceRestriction><saml:Audience>#{xml_escape(request.issuer)}</saml:Audience></saml:AudienceRestriction></saml:Conditions><saml:AuthnStatement AuthnInstant="#{xs_datetime(now)}" SessionIndex="#{xml_escape(assertion_id)}"><saml:AuthnContext><saml:AuthnContextClassRef>urn:oasis:names:tc:SAML:2.0:ac:classes:PasswordProtectedTransport</saml:AuthnContextClassRef></saml:AuthnContext></saml:AuthnStatement>#{EntraClaims.attribute_statement_xml(claims)}</saml:Assertion>
    """
    |> String.trim_trailing("\n")
  end

  # The SamlIdp signature technique recomputed so this lane's file is
  # self-contained (disclosed duplication, r16): enveloped-signature +
  # INCLUSIVE C14N reference transforms; SignatureValue over exc-C14N of
  # SignedInfo; KeyInfo carries the DER base64 X509Certificate.
  defp signature_xml(digest, element_id) do
    ~s(<ds:SignedInfo xmlns:ds="http://www.w3.org/2000/09/xmldsig#"><ds:CanonicalizationMethod Algorithm="http://www.w3.org/2001/10/xml-exc-c14n#"/><ds:SignatureMethod Algorithm="http://www.w3.org/2001/04/xmldsig-more#rsa-sha256"/><ds:Reference URI="##{xml_escape(element_id)}"><ds:Transforms><ds:Transform Algorithm="http://www.w3.org/2000/09/xmldsig#enveloped-signature"/><ds:Transform Algorithm="http://www.w3.org/TR/2001/REC-xml-c14n-20010315"/></ds:Transforms><ds:DigestMethod Algorithm="http://www.w3.org/2001/04/xmlenc#sha256"/><ds:DigestValue>#{Base.encode64(digest)}</ds:DigestValue></ds:Reference></ds:SignedInfo>)
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

  defp private_key, do: SamlIdp.signing_material().key
  defp der_cert_b64, do: SamlIdp.signing_material().der_cert |> Base.encode64()
  defp name_id, do: EntraClaims.resolve()[:upn]

  # ------------------------------------------------------------------
  # SLO flow (consumer-shaped logout court leg; R9)
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

    with {:ok, request_xml} <- SamlIdp.decode_request(saml_request_b64),
         {:ok, request} <- SamlSlo.parse_logout_request(request_xml),
         :ok <- verify_slo_signature(request_xml, conn) do
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

  # Signature law mirrors SamlIdp: a PRESENT signature must verify; an
  # ABSENT signature is lawful (WantAuthnRequestsSigned="false"; the
  # consumer's logout URL is unsigned because no SP signing key exists).
  defp verify_slo_signature(request_xml, conn) do
    cond do
      SamlSlo.signed?(request_xml) ->
        case SamlSlo.verify_enveloped_signature(request_xml, @logout_request_re) do
          :ok -> :ok
          {:error, _reason} -> {:error, "INVALID_SIGNATURE"}
        end

      conn.method == "GET" and conn.query_string != "" and redirect_signature_present?(conn) ->
        case SamlSlo.verify_redirect_signature(conn.query_string) do
          :ok -> :ok
          {:error, _} -> {:error, "INVALID_SIGNATURE"}
        end

      true ->
        :ok
    end
  end

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

  # ------------------------------------------------------------------
  # Metadata
  # ------------------------------------------------------------------

  @doc false
  def metadata_xml do
    base = base_url()

    """
    <EntityDescriptor xmlns="urn:oasis:names:tc:SAML:2.0:metadata" xmlns:ds="http://www.w3.org/2000/09/xmldsig#" entityID="#{xml_escape(entity_id())}"><IDPSSODescriptor WantAuthnRequestsSigned="false" protocolSupportEnumeration="urn:oasis:names:tc:SAML:2.0:protocol"><KeyDescriptor use="signing"><ds:KeyInfo><ds:X509Data><ds:X509Certificate>#{der_cert_b64()}</ds:X509Certificate></ds:X509Data></ds:KeyInfo></KeyDescriptor><NameIDFormat>#{xml_escape(name_id_format())}</NameIDFormat><SingleSignOnService Binding="urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST" Location="#{xml_escape(base <> "/sso")}"/><SingleLogoutService Binding="urn:oasis:names:tc:SAML:2.0:bindings:HTTP-Redirect" Location="#{xml_escape(base <> "/slo")}"/><SingleLogoutService Binding="urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST" Location="#{xml_escape(base <> "/slo")}"/></IDPSSODescriptor></EntityDescriptor>
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

    "<!DOCTYPE html><html><body onload=\"document.forms[0].submit()\">" <>
      ~s(<form method="POST" action="#{xml_attr_escape(acs)}">) <>
      ~s(<input type="hidden" name="#{field_name}" value="#{xml_attr_escape(saml_field_b64)}"#{relay_state_attr}/>) <>
      ~s(<noscript><input type="submit"/></noscript></form></body></html>)
  end

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  defp host_str(ip) when is_tuple(ip), do: ip |> :inet.ntoa() |> to_string()
  defp host_str(ip) when is_binary(ip), do: ip

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

  defp xml_attr_escape(v), do: xml_escape(v)
end
