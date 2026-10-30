defmodule Smalt.Identity.SamlSlo do
  @moduledoc """
  SAML 2.0 Single Logout (SLO) machinery for the smalt IdP face (T04).

  Serves the logout half of the identity plane:

    - Session tracking: (NameID, SessionIndex) pairs issued at sign-in,
      held in a lazy shadow ETS table (`:smalt_saml_sessions`, named, public,
      heir to `:init` — `Smalt.Policy` / AzureCache registry precedent: the
      first creator can be a Bandit request task, so without an heir the
      table dies with the request process).
    - `parse_logout_request/1` — xmerl parse of an SP `samlp:LogoutRequest`.
    - Signature machinery (reuses the T02 RSA-SHA256 canonical-XML shape):
      `sign_element/2` mints an enveloped RSA-SHA256 signature over the
      emitted canonical bytes of a root element; `verify_enveloped_signature/2`
      recomputes the enveloped-signature signed byte range exactly as an
      SP/court does (element with the Signature element removed) and verifies
      with the configured SP cert or the cert embedded in the message.
    - `verify_redirect_signature/2` — REDIRECT binding query-string signature
      (SigAlg rsa-sha256) per the SAML HTTP-Redirect binding.
    - `logout_response_xml/2` / `logout_request_xml/4` — signed
      `samlp:LogoutResponse` (Status Success) and IdP-initiated signed
      `samlp:LogoutRequest`.

  Signature-anchor law: when `:sp_cert_path` is configured, the SP signature
  must verify against that cert; otherwise the cert embedded in the message's
  KeyInfo is the anchor (dev posture — advertised `WantAuthnRequestsSigned`
  is false, so unsigned SP logout requests are lawful; a PRESENT but invalid
  signature is always a typed refusal).

  Config (`config :smalt, :saml_idp, ...`):
    - `:sp_cert_path`     — SP signing cert PEM; strict anchor when set
    - `:slo_response_url` — where the auto-submit LogoutResponse form posts
    - `:slo_sp_slo_url`   — the SP's single-logout callback for
      IdP-initiated logout (`/slo/initiate`)
  """

  import Record

  defrecord :xmlElement, extract(:xmlElement, from_lib: "xmerl/include/xmerl.hrl")
  defrecord :xmlAttribute, extract(:xmlAttribute, from_lib: "xmerl/include/xmerl.hrl")
  defrecord :xmlText, extract(:xmlText, from_lib: "xmerl/include/xmerl.hrl")

  @table :smalt_saml_sessions
  @entity_id_default "urn:smalt:identity:saml"
  @rsa_sha256 "http://www.w3.org/2001/04/xmldsig-more#rsa-sha256"

  # ===========================================================================
  # Shadow session table (lazy, named, public, heir to :init)
  # `Smalt.Policy` precedent: lazy create with `{:heir, Process.whereis(:init), []}`,
  # ArgumentError rescue keeps the create race fail-safe.
  # ===========================================================================

  @doc "Lazily creates `:smalt_saml_sessions` (heir to `:init`) if absent."
  @spec ensure_table() :: :ok
  def ensure_table do
    if :ets.info(@table) == :undefined do
      try do
        :ets.new(@table, [
          :named_table,
          :public,
          :set,
          {:read_concurrency, true},
          {:write_concurrency, true},
          # Shadow-table law: NOT in Store's boot list, so the first creator
          # can be a Bandit request task — heir to :init keeps the table
          # node-permanent.
          {:heir, Process.whereis(:init), []}
        ])
      rescue
        ArgumentError -> :ok
      end
    end

    :ok
  end

  @doc "Records a (NameID, SessionIndex) pair issued at sign-in."
  @spec record_session(binary(), binary()) :: :ok
  def record_session(name_id, session_index) when is_binary(name_id) and is_binary(session_index) do
    ensure_table()
    true = :ets.insert(@table, {{name_id, session_index}, System.system_time(:second)})
    :ok
  end

  @doc "Session indexes recorded for `name_id`."
  @spec session_indexes(binary()) :: [binary()]
  def session_indexes(name_id) when is_binary(name_id) do
    ensure_table()

    :ets.select(@table, [
      {{{:"$1", :"$2"}, :_}, [{:==, :"$1", name_id}], [:"$2"]}
    ])
  end

  @doc """
  The SLO consumption law: the request's NameID must have recorded sessions,
  and every SessionIndex it names must be one this IdP issued. On success the
  named sessions (or all sessions for the NameID when none named) are
  DELETED — a replayed LogoutRequest is then a typed `UNKNOWN_SESSION`
  refusal, not a second Success.
  """
  @spec validate_and_consume(%{name_id: binary() | nil, session_indexes: [binary()]}) ::
          :ok | {:error, binary()}
  def validate_and_consume(%{name_id: name_id, session_indexes: indexes}) do
    ensure_table()
    known = if is_binary(name_id), do: session_indexes(name_id), else: []

    cond do
      known == [] ->
        {:error, "UNKNOWN_SESSION"}

      indexes != [] and Enum.any?(indexes, fn idx -> idx not in known end) ->
        {:error, "UNKNOWN_SESSION"}

      true ->
        delete_sessions(name_id, if(indexes == [], do: :all, else: indexes))
        :ok
    end
  end

  @doc "Deletes the given session indexes for `name_id` (or all). Returns count."
  @spec delete_sessions(binary(), [binary()] | :all) :: non_neg_integer()
  def delete_sessions(name_id, :all) do
    ensure_table()

    :ets.select_delete(@table, [
      {{{name_id, :"$1"}, :_}, [], [true]}
    ])
  end

  def delete_sessions(name_id, indexes) when is_list(indexes) do
    ensure_table()
    Enum.count(indexes, fn idx -> :ets.delete(@table, {name_id, idx}) end)
  end

  @doc "Test seam: drop every recorded session row."
  @spec reset_for_test() :: :ok
  def reset_for_test do
    ensure_table()

    if :ets.info(@table) != :undefined, do: :ets.delete_all_objects(@table)

    :ok
  end

  # ===========================================================================
  # LogoutRequest parsing
  # ===========================================================================

  @doc """
  Parses a `samlp:LogoutRequest` XML document into
  `%{id:, issuer:, name_id:, session_indexes:, signed?:}`.
  """
  def parse_logout_request(xml) when is_binary(xml) do
    with {:ok, nodes} <- scan(xml),
         root when root != nil <-
           Enum.find(nodes, fn n ->
             is_record(n, :xmlElement) and local_name(xmlElement(n, :name)) == "LogoutRequest"
           end) do
      indexes =
        nodes
        |> Enum.filter(fn n ->
          is_record(n, :xmlElement) and local_name(xmlElement(n, :name)) == "SessionIndex"
        end)
        |> Enum.map(&text_of/1)

      {:ok,
       %{
         id: attr(root, "ID"),
         issuer: text_of_child(root, "Issuer") || "",
         name_id: text_of_child(root, "NameID"),
         session_indexes: indexes,
         signed?: signed?(xml)
       }}
    else
      _ -> {:error, "UNPARSEABLE_LOGOUT_REQUEST"}
    end
  end

  @doc false
  def signed?(xml), do: Regex.match?(~r/<[\w.:-]*Signature[\s>]/, xml)

  # ===========================================================================
  # Exclusive C14N 1.0 (no comments) over the first element
  # ===========================================================================

  @doc """
  Exclusive XML canonicalization (exc-C14N 1.0, no comments) of the first
  root element in `xml`, as binary bytes. This is the transformation
  verifiers (xml-crypto / node-saml / lxml) apply before digesting, so the
  DigestValue is computed over THESE bytes — never over the raw emitted
  string (FINISH-WIRE wire witness 2026-10-29: raw-string digests read
  "Invalid document signature" from node-saml; attr order + self-closing
  tags + unused xmlns:xs drop are the divergence).

  Scope note: this implementation carries the SAML message grammar minted /
  parsed here — element and attribute names may be prefixed, namespace
  rendering follows the selected C14N mode, attributes sort by name with
  namespace nodes first. No comments/PIs/DTDs (banned from our minted
  messages; SP input reaches the digest only after xmerl parse, which drops
  nothing we emit but normalizes self-closing tags the same way).
  """

  @type c14n_mode :: :inclusive | :exclusive

  @doc """
  INCLUSIVE C14N (REC-xml-c14n-20010315, no comments) of the first root
  element. This is the digest c14n the operative consumer validator applies:
  xml-crypto appends the inclusive transform to the Reference implicitly
  (witnessed: SignedXml.getReferences()[0].transforms = enveloped-signature
  ++ REC-xml-c14n-20010315), so DigestValue is sha256 over THESE bytes.
  Every in-scope namespace renders at the first output element that carries
  it (render-once rule).
  """
  @spec canonicalize(binary()) :: binary()
  def canonicalize(xml) when is_binary(xml) do
    c14n(xml, :inclusive)
  end

  @doc """
  EXCLUSIVE C14N (exc-C14N 1.0, no comments) of the first root element —
  the visibly-utilized namespace rule. Used for the SignedInfo c14n (the
  declared CanonicalizationMethod) and available for courts.
  """
  @spec canonicalize_exc(binary()) :: binary()
  def canonicalize_exc(xml) when is_binary(xml) do
    c14n(xml, :exclusive)
  end

  defp c14n(xml, mode) when is_binary(xml) do
    {:ok, root} = scan_root(xml)
    {iodata, _emitted} = c14n_walk(root, Map.new(), Map.new(), mode)
    IO.iodata_to_binary(iodata)
  end

  defp scan_root(xml) do
    case :xmerl_scan.string(String.to_charlist(xml)) do
      {root, _} when is_record(root, :xmlElement) ->
        {:ok, root}

      {doc, _} ->
        case Enum.find(List.wrap(doc), &is_record(&1, :xmlElement)) do
          nil -> {:error, :no_element}
          root -> {:ok, root}
        end
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp c14n_walk(el, emitted, inherited, mode) do
    name = atom_name(xmlElement(el, :name))
    attrs = xmlElement(el, :attributes)

    {ns_decls, plain_attrs} =
      Enum.split_with(attrs, fn a ->
        attr_name = atom_name(xmlAttribute(a, :name))
        String.starts_with?(attr_name, "xmlns")
      end)

    # In-scope namespace map after this element's own declarations.
    scope =
      Enum.reduce(ns_decls, inherited, fn a, acc ->
        Map.put(acc, ns_prefix(atom_name(xmlAttribute(a, :name))), attr_value(a))
      end)

    # Namespace rendering candidates:
    #   :inclusive — every in-scope namespace (render-once rule)
    #   :exclusive — only the visibly-utilized prefixes
    {elem_prefix, _local} = split_prefix(name)

    candidates =
      if mode == :inclusive do
        Map.to_list(scope)
      else
        visible =
          Enum.reduce(plain_attrs, MapSet.new([elem_prefix]), fn a, acc ->
            {p, _} = split_prefix(atom_name(xmlAttribute(a, :name)))
            MapSet.put(acc, p)
          end)
          |> MapSet.delete("xmlns")

        scope |> Enum.filter(fn {prefix, _uri} -> MapSet.member?(visible, prefix) end)
      end

    {decl_iodata, emitted2} =
      candidates
      |> Enum.filter(fn {prefix, uri} -> uri != "" and Map.get(emitted, prefix) != uri end)
      |> Enum.sort_by(fn {prefix, _uri} -> prefix end)
      |> Enum.reduce({[], emitted}, fn {prefix, uri}, {acc, em} ->
        attr =
          case prefix do
            "" -> ~s( xmlns="#{ns_escape(uri)}")
            p -> ~s( xmlns:#{p}="#{ns_escape(uri)}")
          end

        {[acc | attr], Map.put(em, prefix, uri)}
      end)

    attr_iodata =
      plain_attrs
      |> Enum.sort_by(fn a ->
        # No namespaced attributes in the SAML message grammar carried here,
        # so (uri, local) sorting degenerates to byte-lexicographic local
        # name ("Name" < "NameFormat").
        n = atom_name(xmlAttribute(a, :name))
        {_, local} = split_prefix(n)
        local
      end)
      |> Enum.map(fn a ->
        n = atom_name(xmlAttribute(a, :name))
        ~s( #{n}="#{attr_escape(attr_value(a))}")
      end)

    open = [?<, name, decl_iodata, attr_iodata, ?>]

    children =
      xmlElement(el, :content)
      |> Enum.map(fn
        t when is_record(t, :xmlText) -> text_escape(to_string(xmlText(t, :value)))
        c when is_record(c, :xmlElement) -> c14n_walk(c, emitted2, scope, mode) |> elem(0)
        _ -> ""
      end)

    {[open, children, ?<, ?/, name, ?>], emitted2}
  end

  defp ns_prefix("xmlns"), do: ""
  defp ns_prefix("xmlns:" <> p), do: p

  defp split_prefix(name) do
    case String.split(name, ":") do
      [local] -> {"", local}
      [p, local] -> {p, local}
      parts -> {List.first(parts), List.last(parts)}
    end
  end

  defp atom_name(name) when is_atom(name), do: Atom.to_string(name)

  defp attr_value(a) do
    case xmlAttribute(a, :value) do
      v when is_list(v) -> to_string(v)
      v when is_binary(v) -> v
      v -> to_string(v)
    end
  end

  # C14N attr-value escaping: & < " and #x9 #xA #xD.
  defp attr_escape(v) do
    v
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("\t", "&#x9;")
    |> String.replace("\n", "&#xA;")
    |> String.replace("\r", "&#xD;")
  end

  defp ns_escape(uri), do: attr_escape(uri)

  # C14N text escaping: & < > and #xD.
  defp text_escape(v) do
    v
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\r", "&#xD;")
  end

  # ===========================================================================
  # Enveloped RSA-SHA256 signature minting (T02 canonical-XML machinery)
  # ===========================================================================

  @doc """
  Signs the ROOT element of `unsigned` (canonical emitted bytes, digest =
  SHA-256 over those bytes) and inserts the `ds:Signature` immediately after
  `anchor` (the closing `</saml:Issuer>` — standard enveloped position).
  Uses the IdP dev signing key.
  """
  @spec sign_element(binary(), binary()) :: binary()
  def sign_element(unsigned, anchor) do
    element_id =
      case Regex.run(~r/\bID="([^"]+)"/, unsigned) do
        [_, id] -> id
        nil -> raise ArgumentError, "sign_element/2: root element has no ID attribute"
      end

    # Digest over the INCLUSIVE-C14N bytes (the reference transform the
    # operative validator applies — xml-crypto appends REC-xml-c14n
    # implicitly). Raw-string digests are the FINISH-WIRE-refuted defect
    # class; exclusive-c14n digests diverge by the inherited-namespace rule.
    canonical = canonicalize(unsigned)
    digest = :crypto.hash(:sha256, canonical)
    signature = signature_with_value(signature_xml(digest, element_id))

    true = String.contains?(unsigned, anchor)
    String.replace(unsigned, anchor, anchor <> signature, global: false)
  end

  # SignedInfo is signed over its exc-C14N bytes (the declared
  # CanonicalizationMethod), not the emitted substring. The Reference
  # declares the transforms that are ACTUALLY applied to the digest bytes:
  # enveloped-signature + inclusive C14N (xml-crypto's implicit pair,
  # now self-described).
  defp signature_xml(digest, element_id) do
    ~s(<ds:SignedInfo xmlns:ds="http://www.w3.org/2000/09/xmldsig#"><ds:CanonicalizationMethod Algorithm="http://www.w3.org/2001/10/xml-exc-c14n#"/><ds:SignatureMethod Algorithm="http://www.w3.org/2001/04/xmldsig-more#rsa-sha256"/><ds:Reference URI="##{element_id}"><ds:Transforms><ds:Transform Algorithm="http://www.w3.org/2000/09/xmldsig#enveloped-signature"/><ds:Transform Algorithm="http://www.w3.org/TR/2001/REC-xml-c14n-20010315"/></ds:Transforms><ds:DigestMethod Algorithm="http://www.w3.org/2001/04/xmlenc#sha256"/><ds:DigestValue>#{Base.encode64(digest)}</ds:DigestValue></ds:Reference></ds:SignedInfo>)
  end

  defp signature_with_value(signed_info) do
    signed_info_canonical = canonicalize_exc(signed_info)

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

  # ===========================================================================
  # Enveloped signature verification (court face + SP-signature face)
  # ===========================================================================

  @doc """
  Verifies the enveloped RSA-SHA256 signature covering the first element
  matching `element_pattern` (Regex whose group 1 captures the whole
  element). Signed bytes = element with the first embedded Signature element
  removed — the same range an enveloped-signature verifier recomputes.
  Returns `:ok` or `{:error, reason}` with reason one of
  `:no_element | :unsigned | :digest_mismatch | :unsupported_algorithm |
  :signature_invalid | :no_signature`.
  """
  @spec verify_enveloped_signature(binary(), Regex.t()) :: :ok | {:error, term()}
  def verify_enveloped_signature(xml, element_pattern) do
    with {:ok, element} <- run_capture(element_pattern, xml, :no_element),
         {:ok, sig} <- extract_signature(element),
         {:ok, signed_info} <- run_capture(~r/(<[\w.:-]*SignedInfo[\s>].*?<\/[\w.:-]*SignedInfo>)/s, sig, :unsigned),
         {:ok, digest_b64} <- run_capture(~r/<[\w.:-]*DigestValue>([^<]*)<\/[\w.:-]*DigestValue>/, sig, :unsigned),
         {:ok, sig_value_b64} <- run_capture(~r/<[\w.:-]*SignatureValue>([^<]*)<\/[\w.:-]*SignatureValue>/, sig, :unsigned),
         :ok <- algorithm_check(sig),
         # Digest over INCLUSIVE-C14N of element-minus-signature — the
         # reference transform the operative validator applies.
         :ok <- digest_check(canonicalize(String.replace(element, sig, "")), digest_b64),
         {:ok, sig_value} <- safe_decode64(sig_value_b64),
         {:ok, pub} <- verify_key(cert_b64(sig)) do
      # SignatureValue verifies over the exc-C14N of SignedInfo (the
      # declared CanonicalizationMethod).
      if :public_key.verify(canonicalize_exc(signed_info), :sha256, sig_value, pub),
        do: :ok,
        else: {:error, :signature_invalid}
    end
  end

  defp run_capture(re, input, err) do
    case Regex.run(re, input) do
      [_, g] -> {:ok, g}
      nil -> {:error, err}
    end
  end

  defp extract_signature(element) do
    case Regex.run(~r/(<[\w.:-]*Signature[\s>].*?<\/[\w.:-]*Signature>)/s, element) do
      [_, sig] -> {:ok, sig}
      nil -> {:error, :unsigned}
    end
  end

  defp cert_b64(sig) do
    case Regex.run(~r/<[\w.:-]*X509Certificate>([^<]*)<\/[\w.:-]*X509Certificate>/, sig) do
      [_, c] -> c
      nil -> nil
    end
  end

  defp decode64!(b64), do: Base.decode64!(b64, ignore: :whitespace)

  defp safe_decode64(b64) do
    case Base.decode64(b64, ignore: :whitespace) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, :invalid_signature_encoding}
    end
  end

  defp digest_check(unsigned_canonical, digest_b64) do
    case safe_decode64(digest_b64) do
      {:ok, digest} ->
        if :crypto.hash(:sha256, unsigned_canonical) == digest,
          do: :ok,
          else: {:error, :digest_mismatch}

      :error ->
        {:error, :invalid_signature_encoding}
    end
  end

  defp algorithm_check(sig) do
    case Regex.run(~r/SignatureMethod[^>]*Algorithm="([^"]*)"/, sig) do
      [_, @rsa_sha256] -> :ok
      [_, other] -> {:error, {:unsupported_algorithm, other}}
      nil -> :ok
    end
  end

  defp verify_key(cert_b64) do
    cond do
      is_binary(sp_cert_path()) ->
        {:ok, pubkey_of_pem_cert(File.read!(expand_path(sp_cert_path())))}

      is_binary(cert_b64) ->
        {:ok, pubkey_of_der(decode64!(cert_b64))}

      true ->
        {:error, :no_signature}
    end
  end

  defp pubkey_of_der(der) do
    cert = :public_key.pkix_decode_cert(der, :otp)
    {:OTPCertificate, tbs, _, _} = cert
    {:OTPSubjectPublicKeyInfo, _alg, pub} = elem(tbs, 7)
    pub
  end

  defp pubkey_of_pem_cert(pem) do
    entry =
      pem
      |> :public_key.pem_decode()
      |> Enum.find(fn {type, _, _} -> type == :Certificate end)

    {:"Certificate", der, :not_encrypted} = entry
    pubkey_of_der(der)
  end

  defp expand_path(p) when is_binary(p),
    do: if(Path.absname(p) == p, do: p, else: Path.join(File.cwd!(), p))

  # ===========================================================================
  # REDIRECT binding query-string signature
  # ===========================================================================

  @doc """
  Verifies the REDIRECT binding query-string signature on a raw query
  string: signed bytes = `SAMLRequest|SAMLResponse=<enc>[&RelayState=<enc>]&SigAlg=<enc>`
  (original encodings preserved), signature = the `Signature` param, key =
  the configured SP cert (strict: a query string has no embedded anchor).
  Absent `Signature` is `{:error, :unsigned}` — the caller decides policy.
  """
  @spec verify_redirect_signature(binary()) :: :ok | {:error, term()}
  def verify_redirect_signature(raw_query) when is_binary(raw_query) do
    tokens = String.split(raw_query, "&")

    msg_token =
      Enum.find(tokens, &String.starts_with?(&1, "SAMLRequest=")) ||
        Enum.find(tokens, &String.starts_with?(&1, "SAMLResponse="))

    sig_b64 = query_param(raw_query, "Signature")
    sig_alg = query_param(raw_query, "SigAlg") || @rsa_sha256

    cond do
      is_nil(msg_token) or is_nil(sig_b64) ->
        {:error, :unsigned}

      sig_alg != @rsa_sha256 ->
        {:error, {:unsupported_algorithm, sig_alg}}

      is_nil(sp_cert_path()) ->
        {:error, :no_sp_cert}

      true ->
        signed_string =
          [
            msg_token,
            relay_state_token(tokens, raw_query),
            Enum.find(tokens, &String.starts_with?(&1, "SigAlg="))
          ]
          |> Enum.reject(&is_nil/1)
          |> Enum.join("&")

        # sig_b64 is already www-form-decoded by query_param/2 — decoding
        # again maps the base64 "+" to space ("incorrect padding" witness).
        with {:ok, signature} <- safe_decode64(sig_b64) do
          pub = pubkey_of_pem_cert(File.read!(expand_path(sp_cert_path())))

          if :public_key.verify(signed_string, :sha256, signature, pub),
            do: :ok,
            else: {:error, :signature_invalid}
        end
    end
  end

  defp relay_state_token(tokens, raw_query) do
    case query_param(raw_query, "RelayState") do
      nil -> nil
      _ -> Enum.find(tokens, &String.starts_with?(&1, "RelayState="))
    end
  end

  defp query_param(raw_query, name) do
    raw_query
    |> URI.decode_query()
    |> Map.get(name)
  end

  # ===========================================================================
  # Message minting
  # ===========================================================================

  @doc """
  Mints a signed `samlp:LogoutResponse` (Status Success) answering
  `in_response_to`. `destination` (optional) becomes the Destination attr.
  """
  def logout_response_xml(in_response_to, destination \\ nil) do
    id = "_smalt" <> unique_id()
    now = System.system_time(:second)
    dest_attr = if is_binary(destination), do: ~s( Destination="#{xml_escape(destination)}"), else: ""

    unsigned =
      ~s(<samlp:LogoutResponse xmlns:samlp="urn:oasis:names:tc:SAML:2.0:protocol" xmlns:saml="urn:oasis:names:tc:SAML:2.0:assertion" ID="#{xml_escape(id)}" Version="2.0" IssueInstant="#{xs_datetime(now)}" InResponseTo="#{xml_escape(in_response_to)}"#{dest_attr}><saml:Issuer>#{xml_escape(entity_id())}</saml:Issuer><samlp:Status><samlp:StatusCode Value="urn:oasis:names:tc:SAML:2.0:status:Success"/></samlp:Status></samlp:LogoutResponse>)

    sign_element(unsigned, ~s(</saml:Issuer>))
  end

  @doc """
  Mints a signed IdP-initiated `samlp:LogoutRequest` for `name_id`
  (optionally scoping to `session_indexes`, default: all recorded sessions
  for the NameID).
  """
  def logout_request_xml(name_id, session_indexes \\ nil, destination \\ nil, in_response_to \\ nil) do
    id = "_smalt" <> unique_id()
    now = System.system_time(:second)
    indexes = if is_list(session_indexes), do: session_indexes, else: session_indexes(name_id)

    index_elems =
      indexes
      |> Enum.map(fn idx -> ~s(<samlp:SessionIndex>#{xml_escape(idx)}</samlp:SessionIndex>) end)
      |> Enum.join()

    dest_attr = if is_binary(destination), do: ~s( Destination="#{xml_escape(destination)}"), else: ""
    irt_attr = if is_binary(in_response_to), do: ~s( InResponseTo="#{xml_escape(in_response_to)}"), else: ""

    unsigned =
      ~s(<samlp:LogoutRequest xmlns:samlp="urn:oasis:names:tc:SAML:2.0:protocol" xmlns:saml="urn:oasis:names:tc:SAML:2.0:assertion" ID="#{xml_escape(id)}" Version="2.0" IssueInstant="#{xs_datetime(now)}"#{dest_attr}#{irt_attr}><saml:Issuer>#{xml_escape(entity_id())}</saml:Issuer><saml:NameID>#{xml_escape(name_id)}</saml:NameID>#{index_elems}</samlp:LogoutRequest>)

    sign_element(unsigned, ~s(</saml:Issuer>))
  end

  # ===========================================================================
  # Config accessors
  # ===========================================================================

  defp saml_config, do: Application.get_env(:smalt, :saml_idp, [])
  defp entity_id, do: saml_config() |> Keyword.get(:entity_id, @entity_id_default)
  defp sp_cert_path, do: saml_config() |> Keyword.get(:sp_cert_path)
  @doc false
  def slo_response_url, do: saml_config() |> Keyword.get(:slo_response_url)
  @doc false
  def slo_sp_slo_url, do: saml_config() |> Keyword.get(:slo_sp_slo_url)

  # ===========================================================================
  # Key material (shares the SamlIdp dev cert lazily via its cache)
  # ===========================================================================

  defp key_material, do: Smalt.Identity.SamlIdp.signing_material()

  defp private_key, do: key_material().key
  defp der_cert_b64, do: key_material().der_cert |> Base.encode64()

  # ===========================================================================
  # xmerl helpers
  # ===========================================================================

  defp scan(xml) do
    case :xmerl_scan.string(String.to_charlist(xml)) do
      {doc, _} -> {:ok, flatten(List.wrap(doc))}
      _ -> {:error, :scan}
    end
  rescue
    e -> {:error, {:scan, Exception.message(e)}}
  end

  defp flatten(nodes, acc \\ [])
  defp flatten([], acc), do: acc

  defp flatten([node | rest], acc) when is_record(node, :xmlElement) do
    flatten(xmlElement(node, :content) ++ rest, [node | acc])
  end

  defp flatten([node | rest], acc) when is_list(node), do: flatten(node ++ rest, acc)
  defp flatten([_text | rest], acc), do: flatten(rest, acc)

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

  defp text_of(node) do
    xmlElement(node, :content)
    |> Enum.map_join("", fn t when is_record(t, :xmlText) -> to_string(xmlText(t, :value)); _ -> "" end)
    |> String.trim()
  end

  defp text_of_child(node, name) do
    xmlElement(node, :content)
    |> Enum.find_value(fn
      child when is_record(child, :xmlElement) ->
        if local_name(xmlElement(child, :name)) == name do
          text = text_of(child)
          if text == "", do: nil, else: text
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
end
