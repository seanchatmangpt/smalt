defmodule Smalt.Identity.SamlIdpTest do
  @moduledoc """
  T02 in-repo court for the SAML 2.0 IdP face.

  Chicago discipline: real HTTP over a real Bandit listener on a private
  port, real xmerl parsing, real RSA-SHA256 signature verification against
  the cert embedded in the response (recomputed SHA-256 over the emitted
  assertion with the Signature element removed - the enveloped-signature
  signed byte range). Bounded poll for listener readiness, no Process.sleep
  as coordination.
  """

  use ExUnit.Case, async: false

  import Record

  defrecord :xmlElement, extract(:xmlElement, from_lib: "xmerl/include/xmerl.hrl")
  defrecord :xmlAttribute, extract(:xmlAttribute, from_lib: "xmerl/include/xmerl.hrl")
  defrecord :xmlText, extract(:xmlText, from_lib: "xmerl/include/xmerl.hrl")


  setup do
    port = 29_445 + :rand.uniform(20_000)
    base = "http://127.0.0.1:#{port}"

    # The IdP derives /metadata SSO Location from :base_url; scope it to the
    # private-port listener for the duration of each court, restore after.
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

    on_exit(fn ->
      :persistent_term.erase({Smalt.Identity.SamlIdp, :key_material})
      if prev, do: Application.put_env(:smalt, :saml_idp, prev), else: Application.delete_env(:smalt, :saml_idp)
    end)

    {:ok, base: base}
  end

  # Bounded poll on the real observable (listener accepts), no fixed sleep.
  defp wait_until(base), do: wait_until(base, 500)

  defp wait_until(_base, 0), do: flunk("IdP listener never came up")

  defp wait_until(base, tries) do
    case :httpc.request(:get, {~c"#{base}/metadata", []}, [], []) do
      {:ok, _} ->
        :ok

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
        if xmlAttribute(a, :name) == String.to_atom(name) do
          to_string(xmlAttribute(a, :value))
        end

      _ ->
        nil
    end)
  end

  defp text(node) do
    xmlElement(node, :content)
    |> Enum.map_join("", fn
      t when is_record(t, :xmlText) -> to_string(xmlText(t, :value))
      _ -> ""
    end)
    |> String.trim()
  end

  # ------------------------------------------------------------------
  # Flow helpers
  # ------------------------------------------------------------------

  defp authn_request_xml(acs, request_id) do
    "<samlp:AuthnRequest xmlns:samlp=\"urn:oasis:names:tc:SAML:2.0:protocol\" xmlns:saml=\"urn:oasis:names:tc:SAML:2.0:assertion\" ID=\"#{request_id}\" Version=\"2.0\" IssueInstant=\"2026-10-29T00:00:00Z\" AssertionConsumerServiceURL=\"#{acs}\"><saml:Issuer>urn:smalt:test:sp</saml:Issuer></samlp:AuthnRequest>"
  end

  defp redirect_binding_b64(xml), do: xml |> :zlib.zip() |> Base.encode64()
  defp post_binding_b64(xml), do: Base.encode64(xml)

  defp get_metadata(base) do
    {:ok, {{_, 200, _}, _, body}} = :httpc.request(:get, {~c"#{base}/metadata", []}, [], [])
    to_string(body)
  end

  defp get_sso(base, query) do
    url = String.to_charlist(base <> "/sso?" <> URI.encode_query(query))

    {:ok, {{_, status, _}, _, body}} = :httpc.request(:get, {url, []}, [], [])

    {status, to_string(body)}
  end

  defp post_sso(base, saml_request_b64, relay_state) do
    form = URI.encode_query(%{"SAMLRequest" => saml_request_b64, "RelayState" => relay_state})

    {:ok, {{_, status, _}, _, body}} =
      :httpc.request(
        :post,
        {~c"#{base}/sso", [], ~c"application/x-www-form-urlencoded", form},
        [],
        []
      )

    {status, to_string(body)}
  end

  defp extract_form_field(html, field) do
    case Regex.run(~r/name="#{field}" value="([^"]*)"/, html) do
      [_, value] -> value
      nil -> flunk("form field #{field} not found in: #{html}")
    end
  end

  # Recomputes the enveloped-signature verification exactly as an SP would:
  # signed bytes = emitted assertion with the <ds:Signature> element removed,
  # digest = SHA-256 over those bytes, verified with the cert embedded in
  # the response's KeyInfo. Returns :ok | {:error, reason}.
  defp verify_signature(response_xml) do
    with [_, assertion] <- Regex.run(~r/(<saml:Assertion .*<\/saml:Assertion>)/, response_xml),
         [_, sig] <- Regex.run(~r/(<ds:Signature .*?<\/ds:Signature>)/s, assertion),
         unsigned = String.replace(assertion, sig, ""),
         [_, signed_info] <- Regex.run(~r/(<ds:SignedInfo .*?<\/ds:SignedInfo>)/s, sig),
         [_, dv] <- Regex.run(~r/<ds:DigestValue>([^<]*)<\/ds:DigestValue>/, sig),
         [_, sv] <- Regex.run(~r/<ds:SignatureValue>([^<]*)<\/ds:SignatureValue>/, sig),
         [_, cert_b64] <- Regex.run(~r/<ds:X509Certificate>([^<]*)<\/ds:X509Certificate>/, sig),
         {:ok, der} <- Base.decode64(dv_cert(cert_b64)),
         {:ok, digest} <- Base.decode64(dv),
         {:ok, signature} <- Base.decode64(sv) do
      # T04 c14n fix (lane L16 unblock disclosure, in-flight at T02 lane
      # completion): digests are over EXCLUSIVE-C14N bytes — the verifier's
      # transformation — not the raw emitted string (FINISH-WIRE wire
      # witness: node-saml rejected raw-string digests). Canonicalizer is
      # the production SamlSlo.canonicalize/1; the independent proof lives
      # in the real-consumer leg (r3 addendum).
      actual_digest = :crypto.hash(:sha256, Smalt.Identity.SamlSlo.canonicalize(unsigned))

      if actual_digest != digest do
        {:error, :digest_mismatch}
      else
        otp_cert = :public_key.pkix_decode_cert(der, :otp)
        {:OTPCertificate, tbs, _, _} = otp_cert
        {:OTPSubjectPublicKeyInfo, _alg, pub} = elem(tbs, 7)

        if :public_key.verify(Smalt.Identity.SamlSlo.canonicalize(signed_info), :sha256, signature, pub) do
          :ok
        else
          {:error, :signature_invalid}
        end
      end
    else
      other -> {:error, {:malformed, other}}
    end
  end

  defp dv_cert(b64), do: b64

  defp assertion_and_response_fields(response_xml, nodes) do
    response = first_element(nodes, "Response")
    assertion = first_element(nodes, "Assertion")
    status_code = first_element(nodes, "StatusCode")
    scd = first_element(nodes, "SubjectConfirmationData")
    name_id = first_element(nodes, "NameID")
    %{
      response: response,
      assertion: assertion,
      status_value: attr(status_code, "Value"),
      in_response_to: attr(response, "InResponseTo"),
      acs_recipient: attr(scd, "Recipient"),
      scd_in_response_to: attr(scd, "InResponseTo"),
      name_id_text: text(name_id)
    }
  end

  # ------------------------------------------------------------------
  # Courts
  # ------------------------------------------------------------------

  test "GET /metadata pins entityID, signing cert, SSO location", %{base: base} do
    xml = get_metadata(base)
    nodes = scan(xml)

    entity = first_element(nodes, "EntityDescriptor")
    assert attr(entity, "entityID") == "urn:smalt:identity:saml"

    kd = first_element(nodes, "KeyDescriptor")
    assert attr(kd, "use") == "signing"

    cert_text = text(first_element(nodes, "X509Certificate"))
    assert byte_size(cert_text) > 100
    assert {:ok, _der} = Base.decode64(cert_text)

    sso = first_element(nodes, "SingleSignOnService")
    assert attr(sso, "Location") == "#{base}/sso"
    assert attr(sso, "Binding") == "urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST"
  end

  test "REDIRECT binding SSO: signed response verifies end to end", %{base: base} do
    acs = "http://127.0.0.1:8081/saml/acs"
    request_id = "_req" <> Base.encode32(:crypto.strong_rand_bytes(8), padding: false)

    saml_request =
      authn_request_xml(acs, request_id)
      |> redirect_binding_b64()

    assert {200, html} = get_sso(base, %{"SAMLRequest" => saml_request, "RelayState" => "rs-123"})
    assert html =~ "document.forms[0].submit()"
    assert html =~ "action=\"#{acs}\""

    saml_response_b64 = extract_form_field(html, "SAMLResponse")
    assert extract_form_field(html, "RelayState") == "rs-123"

    xml = Base.decode64!(saml_response_b64)
    nodes = scan(xml)
    fields = assertion_and_response_fields(xml, nodes)

    assert fields.status_value == "urn:oasis:names:tc:SAML:2.0:status:Success"
    assert fields.in_response_to == request_id
    assert fields.scd_in_response_to == request_id
    assert fields.acs_recipient == acs
    assert fields.name_id_text == "smalt-user"

    assert verify_signature(xml) == :ok
  end

  test "POST binding SSO: plain base64 XML accepted", %{base: base} do
    acs = "http://localhost:8081/saml/acs"
    request_id = "_req" <> Base.encode32(:crypto.strong_rand_bytes(8), padding: false)

    saml_request = authn_request_xml(acs, request_id) |> post_binding_b64()
    assert {200, html} = post_sso(base, saml_request, nil)
    refute html =~ ~s(name="RelayState")

    xml = Base.decode64!(extract_form_field(html, "SAMLResponse"))
    nodes = scan(xml)
    fields = assertion_and_response_fields(xml, nodes)
    assert fields.in_response_to == request_id
    assert verify_signature(xml) == :ok
  end

  test "tampered assertion fails signature verification (non-vacuity)", %{base: base} do
    acs = "http://127.0.0.1:8081/saml/acs"

    saml_request = authn_request_xml(acs, "_req_tamper") |> redirect_binding_b64()
    assert {200, html} = get_sso(base, %{"SAMLRequest" => saml_request})

    xml = Base.decode64!(extract_form_field(html, "SAMLResponse"))

    tampered = String.replace(xml, "smalt-user</saml:NameID>", "evil-user</saml:NameID>")
    assert tampered != xml

    assert {:error, :digest_mismatch} = verify_signature(tampered)
  end

  test "non-loopback ACS is refused typed 400", %{base: base} do
    saml_request =
      authn_request_xml("https://evil.example.com/saml/acs", "_req_bad_acs")
      |> redirect_binding_b64()

    {status, body} = get_sso(base, %{"SAMLRequest" => saml_request})
    assert status == 400
    assert body =~ "ACS_NOT_LOOPBACK"
  end

  test "garbage SAMLRequest is refused typed 400", %{base: base} do
    {status, body} = get_sso(base, %{"SAMLRequest" => Base.encode64("definitely not xml")})
    assert status == 400
    assert body =~ "UNPARSEABLE_SAML_REQUEST"
  end
end
