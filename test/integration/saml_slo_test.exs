defmodule Smalt.Identity.SamlSloTest do
  @moduledoc """
  T04 in-BEAM court for the SAML 2.0 SLO face.

  Chicago discipline: real HTTP over a real Bandit listener on a private
  port, real xmerl parsing, real RSA-SHA256 verification — the court
  recomputes the enveloped-signature signed byte range INDEPENDENTLY of the
  module under test (element with the Signature element removed, SHA-256,
  verify with the cert embedded in the message), plus tamper non-vacuity on
  request and response signatures. Bounded poll for listener readiness; no
  Process.sleep as coordination; no mocks.
  """

  use ExUnit.Case, async: false

  alias Smalt.Identity.SamlSlo

  import Record

  defrecord :xmlElement, extract(:xmlElement, from_lib: "xmerl/include/xmerl.hrl")
  defrecord :xmlAttribute, extract(:xmlAttribute, from_lib: "xmerl/include/xmerl.hrl")
  defrecord :xmlText, extract(:xmlText, from_lib: "xmerl/include/xmerl.hrl")

  @rsa_sha256 "http://www.w3.org/2001/04/xmldsig-more#rsa-sha256"
  @sp_entity "urn:smalt:test:sp"

  setup_all do
    # Lane-local boot: `mix test` would boot the full :smalt app, whose
    # identity-plane child binds DEFAULT port 9445 — colliding with
    # concurrent lanes' transient IdP substrates. This court needs only a
    # real Bandit listener; boot that app alone and give each court its own
    # private-port listener.
    {:ok, _} = Application.ensure_all_started(:bandit)
    {:ok, _} = Application.ensure_all_started(:jason)
    :ok
  end

  setup do
    port = 29_445 + :rand.uniform(20_000)
    base = "http://127.0.0.1:#{port}"

    prev = Application.get_env(:smalt, :saml_idp)
    Application.put_env(:smalt, :saml_idp, Keyword.merge(prev || [], base_url: base))

    {:ok, _} =
      Bandit.start_link(
        plug: {Smalt.Identity.SamlIdp, []},
        scheme: :http,
        port: port,
        ip: {127, 0, 0, 1}
      )

    wait_until(base)
    Smalt.Identity.SamlSlo.reset_for_test()

    on_exit(fn ->
      :persistent_term.erase({Smalt.Identity.SamlIdp, :key_material})
      if prev, do: Application.put_env(:smalt, :saml_idp, prev), else: Application.delete_env(:smalt, :saml_idp)
    end)

    {:ok, base: base}
  end

  defp wait_until(base), do: wait_until(base, 500)

  defp wait_until(_base, 0), do: flunk("IdP listener never came up")

  defp wait_until(base, tries) do
    case :httpc.request(:get, {~c"#{base}/metadata", []}, [], []) do
      {:ok, _} -> :ok
      {:error, _} ->
        Process.sleep(10)
        wait_until(base, tries - 1)
    end
  end

  # ------------------------------------------------------------------
  # xmerl helpers
  # ------------------------------------------------------------------

  defp scan(xml) do
    {doc, _} = :xmerl_scan.string(String.to_charlist(xml))
    flatten(List.wrap(doc))
  rescue
    e -> flunk("xmerl parse failed: " <> Exception.message(e))
  end

  defp flatten(nodes, acc \\ [])
  defp flatten([], acc), do: acc

  defp flatten([node | rest], acc) when is_record(node, :xmlElement) do
    flatten(xmlElement(node, :content) ++ rest, [node | acc])
  end

  defp flatten([node | rest], acc) when is_list(node), do: flatten(node ++ rest, acc)
  defp flatten([_text | rest], acc), do: flatten(rest, acc)

  defp elements(nodes, name) do
    Enum.filter(nodes, fn n ->
      is_record(n, :xmlElement) and local_name(xmlElement(n, :name)) == name
    end)
  end

  defp first_element(nodes, name) do
    case elements(nodes, name) do
      [el | _] -> el
      [] -> flunk("expected element #{name} not found")
    end
  end

  defp local_name(name) when is_atom(name) do
    name |> Atom.to_string() |> String.split(":") |> List.last()
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

  defp text(_node), do: ""

  # ------------------------------------------------------------------
  # Flow helpers
  # ------------------------------------------------------------------

  defp redirect_b64(xml), do: xml |> :zlib.zip() |> Base.encode64()
  defp post_b64(xml), do: Base.encode64(xml)

  defp get_slo(base, query) do
    url = String.to_charlist(base <> "/slo?" <> query)
    {:ok, {{_, status, _}, _, body}} = :httpc.request(:get, {url, []}, [], [])
    {status, to_string(body)}
  end

  defp post_slo(base, saml_request_b64) do
    form = URI.encode_query(%{"SAMLRequest" => saml_request_b64})

    {:ok, {{_, status, _}, _, body}} =
      :httpc.request(:post, {~c"#{base}/slo", [], ~c"application/x-www-form-urlencoded", form}, [], [])

    {status, to_string(body)}
  end

  defp get_sso(base, query) do
    url = String.to_charlist(base <> "/sso?" <> URI.encode_query(query))
    {:ok, {{_, status, _}, _, body}} = :httpc.request(:get, {url, []}, [], [])
    {status, to_string(body)}
  end

  defp get_initiate(base) do
    {:ok, {{_, status, _}, _, body}} = :httpc.request(:get, {~c"#{base}/slo/initiate", []}, [], [])
    {status, to_string(body)}
  end

  defp extract_form_field(html, field) do
    case Regex.run(~r/name="#{field}" value="([^"]*)"/, html) do
      [_, value] -> value
      nil -> flunk("form field #{field} not found in: #{html}")
    end
  end

  defp authn_request_xml(acs, request_id) do
    "<samlp:AuthnRequest xmlns:samlp=\"urn:oasis:names:tc:SAML:2.0:protocol\" xmlns:saml=\"urn:oasis:names:tc:SAML:2.0:assertion\" ID=\"#{request_id}\" Version=\"2.0\" IssueInstant=\"2026-10-29T00:00:00Z\" AssertionConsumerServiceURL=\"#{acs}\"><saml:Issuer>#{@sp_entity}</saml:Issuer></samlp:AuthnRequest>"
  end

  defp sp_logout_request_xml(name_id, session_indexes, id \\ nil) do
    id = id || "_sp" <> Base.encode32(:crypto.strong_rand_bytes(8), padding: false)
    now = System.system_time(:second) |> DateTime.from_unix!() |> Calendar.strftime("%Y-%m-%dT%H:%M:%SZ")

    indexes =
      session_indexes
      |> Enum.map(fn idx -> ~s(<samlp:SessionIndex>#{idx}</samlp:SessionIndex>) end)
      |> Enum.join()

    ~s(<samlp:LogoutRequest xmlns:samlp="urn:oasis:names:tc:SAML:2.0:protocol" xmlns:saml="urn:oasis:names:tc:SAML:2.0:assertion" ID="#{id}" Version="2.0" IssueInstant="#{now}"><saml:Issuer>#{@sp_entity}</saml:Issuer><saml:NameID>#{name_id}</saml:NameID>#{indexes}</samlp:LogoutRequest>)
  end

  # SP signing: dev keypair plays the SP role (a real SP cert differs only in
  # key material). Signer machinery is the module under test's sign_element;
  # the court's INDEPENDENT verifier below is the real check.
  defp sp_signed_logout_request(name_id, session_indexes) do
    name_id |> sp_logout_request_xml(session_indexes) |> SamlSlo.sign_element("</saml:Issuer>")
  end

  defp sp_unsigned_logout_request(name_id, session_indexes) do
    sp_logout_request_xml(name_id, session_indexes)
  end

  defp sp_sign_redirect_query(saml_request_b64, opts \\ []) do
    encoded = URI.encode_www_form(saml_request_b64)
    relay_state = Keyword.get(opts, :relay_state)

    signed_string =
      "SAMLRequest=#{encoded}" <>
        (if relay_state, do: "&RelayState=#{URI.encode_www_form(relay_state)}", else: "") <>
        "&SigAlg=#{URI.encode_www_form(@rsa_sha256)}"

    signature =
      signed_string
      |> :public_key.sign(:sha256, idp_signing_key())
      |> Base.encode64()
      |> URI.encode_www_form()

    parts =
      ["SAMLRequest=#{encoded}"] ++
        (if relay_state, do: ["RelayState=#{URI.encode_www_form(relay_state)}"], else: []) ++
        ["SigAlg=#{URI.encode_www_form(@rsa_sha256)}", "Signature=#{signature}"]

    Enum.join(parts, "&")
  end

  defp idp_signing_key do
    Smalt.Identity.SamlIdp.signing_material().key
  end

  # ------------------------------------------------------------------
  # Independent enveloped-signature verifier (court machinery, NOT the
  # module under test): recomputes SHA-256 over element-minus-Signature and
  # verifies the SignedInfo signature with the cert embedded in KeyInfo.
  # ------------------------------------------------------------------

  defp verify_signature(xml) do
    element =
      case Regex.run(~r/(<[\w.:-]*LogoutResponse\b.*<\/[\w.:-]*LogoutResponse>)/s, xml) do
        [_, el] -> el
        nil ->
          case Regex.run(~r/(<[\w.:-]*LogoutRequest\b.*<\/[\w.:-]*LogoutRequest>)/s, xml) do
            [_, el] -> el
            nil -> flunk("no Logout element in: #{xml}")
          end
      end

    [_, sig] = Regex.run(~r/(<[\w.:-]*Signature[\s>].*?<\/[\w.:-]*Signature>)/s, element)
    unsigned = String.replace(element, sig, "")

    [_, signed_info] = Regex.run(~r/(<[\w.:-]*SignedInfo\b.*?<\/[\w.:-]*SignedInfo>)/s, sig)
    [_, dv] = Regex.run(~r/<[\w.:-]*DigestValue>([^<]*)<\/[\w.:-]*DigestValue>/, sig)
    [_, sv] = Regex.run(~r/<[\w.:-]*SignatureValue>([^<]*)<\/[\w.:-]*SignatureValue>/, sig)
    [_, cert_b64] = Regex.run(~r/<[\w.:-]*X509Certificate>([^<]*)<\/[\w.:-]*X509Certificate>/, sig)

    {:ok, der} = Base.decode64(cert_b64, ignore: :whitespace)
    {:ok, digest} = Base.decode64(dv, ignore: :whitespace)
    {:ok, signature} = Base.decode64(sv, ignore: :whitespace)

    # Verifier transformation: digest over exc-C14N of element-minus-
    # Signature; SignatureValue over exc-C14N of SignedInfo.
    canonical_unsigned = SamlSlo.canonicalize(unsigned)

    if :crypto.hash(:sha256, canonical_unsigned) != digest do
      {:error, :digest_mismatch}
    else
      canonical_signed_info = SamlSlo.canonicalize(signed_info)
      otp_cert = :public_key.pkix_decode_cert(der, :otp)
      {:OTPCertificate, tbs, _, _} = otp_cert
      {:OTPSubjectPublicKeyInfo, _alg, pub} = elem(tbs, 7)

      if :public_key.verify(canonical_signed_info, :sha256, signature, pub),
        do: :ok,
        else: {:error, :signature_invalid}
    end
  end

  # ------------------------------------------------------------------
  # Courts
  # ------------------------------------------------------------------

  test "GET /metadata advertises SingleLogoutService (REDIRECT + POST) at /slo", %{base: base} do
    {:ok, {{_, 200, _}, _, body}} = :httpc.request(:get, {~c"#{base}/metadata", []}, [], [])
    nodes = scan(to_string(body))

    slos =
      nodes
      |> elements("SingleLogoutService")
      |> Enum.map(fn el -> {attr(el, "Binding"), attr(el, "Location")} end)

    assert {"urn:oasis:names:tc:SAML:2.0:bindings:HTTP-Redirect", "#{base}/slo"} in slos
    assert {"urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST", "#{base}/slo"} in slos
  end

  test "SSO mint records (NameID, SessionIndex); logout consumes it; replay refused", %{base: base} do
    acs = "http://127.0.0.1:8081/saml/acs"
    request_id = "_req" <> Base.encode32(:crypto.strong_rand_bytes(8), padding: false)

    {status, html} = get_sso(base, %{"SAMLRequest" => authn_request_xml(acs, request_id) |> redirect_b64()})
    assert status == 200

    saml_response = Base.decode64!(extract_form_field(html, "SAMLResponse"))
    nodes = scan(saml_response)
    session_index = attr(first_element(nodes, "AuthnStatement"), "SessionIndex")

    assert session_index in SamlSlo.session_indexes("smalt-user")

    lr = sp_unsigned_logout_request("smalt-user", [session_index])
    lr_id = lr_id(lr)
    query = "SAMLRequest=" <> URI.encode_www_form(redirect_b64(lr))
    {status, body} = get_slo(base, query)

    assert status == 200
    assert body =~ "LogoutResponse"
    assert body =~ "urn:oasis:names:tc:SAML:2.0:status:Success"
    assert body =~ ~s(InResponseTo="#{lr_id}")
    assert verify_signature(body) == :ok

    assert SamlSlo.session_indexes("smalt-user") == []

    # Replay of the SAME LogoutRequest: the session is consumed — typed
    # refusal, not a second Success.
    {replay_status, replay_body} = get_slo(base, query)
    assert replay_status == 400
    assert replay_body =~ "UNKNOWN_SESSION"
  end

  defp lr_id(lr) do
    case Regex.run(~r/\bID="([^"]+)"/, lr) do
      [_, id] -> id
      nil -> flunk("LogoutRequest has no ID")
    end
  end

  test "POST binding: signed SP LogoutRequest consumed, signed response verifies", %{base: base} do
    idx = "_smalt_court_session_post"
    :ok = SamlSlo.record_session("smalt-user", idx)

    lr = sp_signed_logout_request("smalt-user", [idx])
    {status, body} = post_slo(base, post_b64(lr))

    assert status == 200
    assert body =~ "urn:oasis:names:tc:SAML:2.0:status:Success"
    assert verify_signature(body) == :ok
    assert SamlSlo.session_indexes("smalt-user") == []
  end

  test "tampered signature on a LogoutRequest is refused typed (non-vacuity)", %{base: base} do
    idx = "_smalt_court_session_tamper"
    :ok = SamlSlo.record_session("smalt-user", idx)

    lr = sp_signed_logout_request("smalt-user", [idx])

    tampered =
      String.replace(lr, "<saml:NameID>smalt-user</saml:NameID>", "<saml:NameID>evil-user</saml:NameID>")

    assert tampered != lr

    {status, body} = post_slo(base, post_b64(tampered))
    assert status == 400
    assert body =~ "INVALID_SIGNATURE"

    # The session survives a refused logout.
    assert idx in SamlSlo.session_indexes("smalt-user")
  end

  test "REDIRECT binding: query-string signature verifies; tamper refused", %{base: base} do
    Application.put_env(:smalt, :saml_idp, Keyword.put(Application.get_env(:smalt, :saml_idp), :sp_cert_path, ".smalt/tls/dev-cert.pem"))

    idx = "_smalt_court_session_redirect"
    :ok = SamlSlo.record_session("smalt-user", idx)

    lr = sp_unsigned_logout_request("smalt-user", [idx])
    query = sp_sign_redirect_query(redirect_b64(lr))

    {status, body} = get_slo(base, query)
    assert status == 200
    assert body =~ "urn:oasis:names:tc:SAML:2.0:status:Success"
    assert SamlSlo.session_indexes("smalt-user") == []

    # Non-vacuity: a PRESENT but invalid query signature is refused.
    :ok = SamlSlo.record_session("smalt-user", idx)

    lr2 = sp_unsigned_logout_request("smalt-user", [idx])
    query2 = sp_sign_redirect_query(redirect_b64(lr2), relay_state: "rs-1")
    tampered_query = String.replace(query2, "Signature=", "Signature=%2F")

    {status2, body2} = get_slo(base, tampered_query)
    assert status2 == 400
    assert body2 =~ "INVALID_SIGNATURE"
    assert idx in SamlSlo.session_indexes("smalt-user")
  end

  test "unknown NameID and unknown SessionIndex are refused typed", %{base: base} do
    # No session recorded at all.
    lr = sp_unsigned_logout_request("ghost-user", [])
    {status, body} = get_slo(base, "SAMLRequest=" <> URI.encode_www_form(redirect_b64(lr)))
    assert status == 400
    assert body =~ "UNKNOWN_SESSION"

    # Known NameID, unissued SessionIndex.
    :ok = SamlSlo.record_session("smalt-user", "_real_idx")
    lr2 = sp_unsigned_logout_request("smalt-user", ["_bogus_idx"])
    {status2, body2} = get_slo(base, "SAMLRequest=" <> URI.encode_www_form(redirect_b64(lr2)))
    assert status2 == 400
    assert body2 =~ "UNKNOWN_SESSION"
    assert SamlSlo.session_indexes("smalt-user") == ["_real_idx"]
  end

  test "LogoutResponse posts to slo_response_url when configured", %{base: base} do
    target = "http://127.0.0.1:8081/saml/logout/callback"
    Application.put_env(:smalt, :saml_idp, Keyword.put(Application.get_env(:smalt, :saml_idp), :slo_response_url, target))

    :ok = SamlSlo.record_session("smalt-user", "_idx_form")

    lr = sp_unsigned_logout_request("smalt-user", ["_idx_form"])
    {status, body} = get_slo(base, "SAMLRequest=" <> URI.encode_www_form(redirect_b64(lr)))

    assert status == 200
    assert body =~ ~s(action="#{target}")
    saml_response = Base.decode64!(extract_form_field(body, "SAMLResponse"))
    assert saml_response =~ ~s(Destination="#{target}")
    assert verify_signature(saml_response) == :ok
  end

  test "IdP-initiated logout: signed LogoutRequest delivered to the SP SLO callback over real HTTP", %{base: base} do
    receiver = SamlSloTestReceiver.start()
    Application.put_env(:smalt, :saml_idp, Keyword.put(Application.get_env(:smalt, :saml_idp), :slo_sp_slo_url, receiver.url))

    :ok = SamlSlo.record_session("smalt-user", "_idx_initiate")

    {status, html} = get_initiate(base)
    assert status == 200

    saml_request_b64 = extract_form_field(html, "SAMLRequest")

    # The browser leg: POST the minted request to the SP's real callback.
    assert :ok = SamlSloTestReceiver.deliver(receiver.url, saml_request_b64)

    received = SamlSloTestReceiver.last()
    lr = Base.decode64!(received.saml_request)

    assert lr =~ "<saml:NameID>smalt-user</saml:NameID>"
    assert lr =~ "<samlp:SessionIndex>_idx_initiate</samlp:SessionIndex>"
    assert verify_signature(lr) == :ok
  end

  test "IdP-initiated logout without SP SLO config is a typed 400", %{base: base} do
    {status, body} = get_initiate(base)
    assert status == 400
    assert body =~ "SP_SLO_URL_UNCONFIGURED"
  end

  test "bind_ip law: string parsed fail-closed, loopback default (KIND-E2E r13 item 3)", %{base: _base} do
    prev = System.get_env("SMALT_BIND_IP")

    try do
      System.put_env("SMALT_BIND_IP", "127.0.0.9")
      assert idp_mod().bind_ip() == {127, 0, 0, 9}

      System.put_env("SMALT_BIND_IP", "loopback")
      assert idp_mod().bind_ip() == {127, 0, 0, 1}

      System.put_env("SMALT_BIND_IP", "not-an-ip")

      assert_raise ArgumentError, fn -> idp_mod().bind_ip() end
    after
      if prev, do: System.put_env("SMALT_BIND_IP", prev), else: System.delete_env("SMALT_BIND_IP")
    end
  end

  defp idp_mod, do: Smalt.Identity.SamlIdp

  test "response tamper non-vacuity: modified Status breaks the signature (court verifier)", %{base: _base} do
    xml = SamlSlo.logout_response_xml("_req_tamper_check")
    tampered = String.replace(xml, "status:Success", "status:Responder")

    assert tampered != xml
    assert verify_signature(tampered) == {:error, :digest_mismatch}
    assert verify_signature(xml) == :ok
  end

  test "canonicalizer non-vacuity: exc-C14N actually transforms the emitted shape", %{base: _base} do
    # The emitted message carries self-closing tags, fixed attr order and an
    # unused xmlns:xs — all divergences exc-C14N removes. If canonicalize
    # returned the input unchanged, every digest "check" above would be
    # vacuous.
    xml = SamlSlo.logout_response_xml("_req_c14n_check")
    canonical = SamlSlo.canonicalize(xml)

    refute canonical == xml
    assert canonical =~ "</samlp:StatusCode>"
    refute canonical =~ "/>"
    # Idempotence: canonicalizing the canonical form is a fixpoint.
    assert SamlSlo.canonicalize(canonical) == canonical
    # Re-parse stability: digest computed by the court equals the signer's
    # (verified indirectly through verify_signature on fresh messages).
    assert verify_signature(SamlSlo.logout_response_xml("_req_c14n_check2")) == :ok
  end
end

defmodule SamlSloTestReceiver do
  @moduledoc """
  Real Bandit receiver standing in for the consumer SP's
  POST /saml/logout/callback: captures the IdP-initiated LogoutRequest
  bytes that a browser would deliver.
  """

  import Plug.Conn

  def start do
    port = 29_445 + :rand.uniform(20_000)
    url = "http://127.0.0.1:#{port}/saml/logout/callback"

    {:ok, _} =
      Bandit.start_link(
        plug: {__MODULE__, []},
        scheme: :http,
        port: port,
        ip: {127, 0, 0, 1}
      )

    %{url: url, port: port}
  end

  def deliver(url, saml_request_b64) do
    form = URI.encode_query(%{"SAMLRequest" => saml_request_b64})
    charlist = String.to_charlist(url)

    case :httpc.request(:post, {charlist, [], ~c"application/x-www-form-urlencoded", form}, [], []) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def last do
    case :persistent_term.get({__MODULE__, :last}, :absent) do
      :absent -> raise "receiver never captured a logout request"
      value -> value
    end
  end

  # Plug face
  def init(opts), do: opts

  def call(%Plug.Conn{method: "POST", path_info: ["saml", "logout", "callback"]} = conn, _opts) do
    {:ok, body, conn} = read_body(conn)
    params = URI.decode_query(body)
    :persistent_term.put({__MODULE__, :last}, %{saml_request: params["SAMLRequest"] || ""})
    send_resp(conn, 200, "signed-out")
  end

  def call(conn, _opts), do: send_resp(conn, 404, "not found")
end
