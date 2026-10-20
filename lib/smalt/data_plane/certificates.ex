defmodule Smalt.DataPlane.Certificates do
  # KD-COVERS: KD-104 (certificates plane: create/get/list/delete/purge;
  # flip-gated on the CertificateClient-tier witness receipt)
  @moduledoc """
  Minimal Azure Key Vault Certificates data plane (KD-104) over a
  module-owned, heir'd ETS table `:smalt_vault_certificates`.

  Strictly the four verbs the KD-104 falsifier names (CertificateClient
  create/get + list, plus delete): NO versions/latest surface, NO merge or
  pending-Certificate operation resolver — Azure's create here is atomic,
  never `pending`.

  Wire surface (routes live in `EgressRouter`; wiring seam is the same
  `{:ok, status, body}` tuple contract the `/keys` + `/secrets` siblings
  use, so a handler is one `case`):

    - `POST /certificates/:name/create` -> `create/3` (self-signed X.509
      minted from the request policy)
    - `GET  /certificates`              -> `list/0`
    - `GET  /certificates/:name`        -> `get/1` (200 cer + attributes)
    - `DELETE /certificates/:name`      -> `delete/1` (200 deletedCertificate
      bundle: recoveryId/deletedDate/scheduledPurgeDate)
    - `GET  /deletedcertificates`       -> `list_deleted/0`
    - `GET  /deletedcertificates/:name` -> `get_deleted/1` (200 bundle)
    - `POST /deletedcertificates/:name/recover` -> `recover/1` (200 restore)
    - `POST /deletedcertificates/:name/purge`   -> `purge/1` (204)

  ## Certificate material

  A real RSA-2048 self-signed X.509 v3 certificate is minted per create via
  OTP `:public_key` (hand-assembled `:OTPCertificate`, DER-encoded,
  SHA256WithRSAEncryption-signed). The DER is stored under `"cer"` (base64
  on the wire); the private key is NOT retained — the certificate is the
  stored asset. `pem/1` exports the stored DER as PEM.

  ## Attributes

  `attributes` mirror the KV shape: `enabled`, `created`/`updated` (unix
  seconds), `nbf`/`exp` (unix seconds, derived from the policy validity),
  `recoveryLevel: "Purgeable"`.

  ## Deleted-certificates class

  Soft delete moves the row to the SAME heir'd table under the tuple key
  `{:deleted, name}` (the secrets-mirror namespacing: binary keys stay live,
  tuple keys are deleted bundles) with `recoveryId`, `deletedDate` and
  `scheduledPurgeDate` (epoch seconds, 90-day retention). Live `get/1` /
  `list/0` 404/omit soft-deleted rows by construction (`Store.list/1` walks
  binary keys only); `recover/1` re-puts the live row and drops the bundle.
  """

  alias Smalt.Store

  @table :smalt_vault_certificates
  @gregorian_offset 62_167_219_200

  # ---------------------------------------------------------------------------
  # Table ownership (shadow-table law — same pattern as Smalt.Policy /
  # cosmos.ex ru_table; NO request-linked owner GenServer)
  # ---------------------------------------------------------------------------

  @doc """
  Ensures `#{@table}` exists, creating it lazily from whichever process
  first touches it with `heir: Process.whereis(:init)` so the table
  outlives its creator.

  Shadow-table law (KD-104 wire witness 2026-10-20): the first creator is
  a Bandit request task — a request-linked GenServer owner (or a bare
  creator with no heir) dies with the request process and every later
  request sees a fresh store (witnessed: create 201 → get 404 on the same
  beam, list empty, duplicate create 201 instead of 409). Heir to `:init`
  (permanent, node-local) makes the table node-permanent; the
  ArgumentError rescue keeps the multi-request create race fail-safe.
  Idempotent; safe from any process.
  """
  @spec ensure_table :: :ok
  def ensure_table do
    if :ets.info(@table) == :undefined do
      try do
        :ets.new(@table, [
          :set,
          :public,
          :named_table,
          {:heir, Process.whereis(:init), []},
          read_concurrency: true,
          write_concurrency: true
        ])
      rescue
        ArgumentError -> :ok
      end
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Create
  # ---------------------------------------------------------------------------

  @doc """
  `POST /certificates/:name/create`. Body `{"policy": {"x509_props":
  {"subject": "CN=...", "validity_months": N}}}` (both optional; defaults
  `CN=smalt-cert`, 12 months). Mints a real self-signed certificate, stores
  DER + attributes, returns the full Certificate object (201, Azure shape:
  `id`, `cer` base64 DER, `attributes`, `policy`).

  An existing name is refused atomically with typed
  `409 {"error":{"code":"CertificateNameAlreadyExists"}}` — the exists-check
  AND the insert are ONE `:ets.insert_new/2` on the public table, so the
  create-on-existing silent overwrite is structurally impossible.
  """
  @spec create(binary, Plug.Conn.t() | binary, map) :: {:ok, 201, map} | {:error, 409, map}
  def create(name, conn_or_host, body_params) do
    ensure_table()

    host =
      case conn_or_host do
        %Plug.Conn{host: host} -> host
        host when is_binary(host) -> host
      end

    policy = Map.get(body_params || %{}, "policy", %{})
    x509 = Map.get(policy, "x509_props", %{})

    subject = Map.get(x509, "subject", "CN=smalt-cert")
    months = Map.get(x509, "validity_months", 12)

    now = System.system_time(:second)
    not_before = now
    not_after = add_months(now, months)

    {:ok, der} = mint_certificate(subject, subject, not_before, not_after)

    record = %{
      "id" => "https://#{host}:8443/certificates/#{name}",
      "name" => name,
      "cer" => Base.encode64(der),
      "attributes" => %{
        "enabled" => Map.get(x509, "enabled", true),
        "created" => now,
        "updated" => now,
        "nbf" => not_before,
        "exp" => not_after,
        "recoveryLevel" => "Purgeable"
      },
      "policy" => %{
        "id" => "https://#{host}:8443/certificates/#{name}/policy",
        "x509_props" => %{
          "subject" => subject,
          "validity_months" => months
        },
        "attributes" => %{
          "created" => now,
          "updated" => now,
          "recoveryLevel" => "Purgeable"
        }
      }
    }

    case insert_new(name, record) do
      :ok -> {:ok, 201, record}
      {:error, :exists} -> {:error, 409, certificate_error("CertificateNameAlreadyExists")}
    end
  end

  defp insert_new(name, record) do
    # The table is `:public` — insert_new is atomic from ANY process, so the
    # exists-check + insert need no owner-GenServer serialization (the old
    # GenServer.call hop was the request-linked lifetime defect, KD-104).
    case :ets.insert_new(@table, {name, record}) do
      true -> :ok
      false -> {:error, :exists}
    end
  end

  # ---------------------------------------------------------------------------
  # Get / list
  # ---------------------------------------------------------------------------

  @doc """
  `GET /certificates/:name`. Returns the stored Certificate object (same
  shape the create route returned; `cer` is base64 DER). Unknown name ->
  typed `404 CertificateNotFound`.
  """
  @spec get(binary) :: {:ok, 200, map} | {:error, 404, map}
  def get(name) do
    ensure_table()

    case Store.get(@table, name) do
      {:ok, record} -> {:ok, 200, record}
      :error -> {:error, 404, certificate_error("CertificateNotFound")}
    end
  end

  @doc """
  `GET /certificates`. Certificate list envelope
  `{"value": [CertificateItem...]}` (id + name + attributes per row).
  """
  @spec list :: {:ok, 200, map}
  def list do
    ensure_table()

    {:ok, 200,
     %{
       "value" =>
         Enum.map(Store.list(@table), fn record ->
           %{"id" => record["id"], "name" => record["name"], "attributes" => record["attributes"]}
         end)
     }}
  end

  # ---------------------------------------------------------------------------
  # Soft delete / recover / purge (deleted-certificates class)
  # ---------------------------------------------------------------------------

  @retention_seconds 90 * 24 * 3600

  @doc """
  `DELETE /certificates/:name` (soft delete). Removes the certificate from
  the live surface (subsequent `get/1` 404s CertificateNotFound) and moves it
  to the deleted-bundle tuple row `{:deleted, name}` in the SAME heir'd table,
  with `recoveryId`, `deletedDate` and `scheduledPurgeDate` (epoch seconds,
  90-day retention). Returns the deletedCertificate bundle (200).
  Unknown name -> typed `404 CertificateNotFound`.
  """
  @spec delete(binary) :: {:ok, 200, map} | {:error, 404, map}
  def delete(name) do
    ensure_table()

    case Store.get(@table, name) do
      {:ok, record} ->
        now = System.system_time(:second)

        deleted =
          record
          |> Map.put("deletedDate", now)
          |> Map.put("scheduledPurgeDate", now + @retention_seconds)
          |> Map.put("recoveryId", "https://smalt-vault/deletedcertificates/#{name}")
          |> Map.put("is_deleted_certificate", true)

        Store.delete(@table, name)
        Store.put(@table, {:deleted, name}, deleted)

        {:ok, 200, deleted}

      :error ->
        {:error, 404, certificate_error("CertificateNotFound")}
    end
  end

  @doc """
  `GET /deletedcertificates/:name`. The deletedCertificate bundle
  (`recoveryId`, `deletedDate`, `scheduledPurgeDate`). Unknown or purged
  certificate -> 404 CertificateNotFound. The live path (`get/1`) 404s by
  construction — the live row is gone.
  """
  @spec get_deleted(binary) :: {:ok, 200, map} | {:error, 404, map}
  def get_deleted(name) do
    ensure_table()

    case Store.get(@table, {:deleted, name}) do
      {:ok, deleted} -> {:ok, 200, deleted}
      :error -> {:error, 404, certificate_error("CertificateNotFound")}
    end
  end

  @doc """
  `GET /deletedcertificates`. All deletedCertificate bundles, key order.
  """
  @spec list_deleted :: {:ok, 200, map}
  def list_deleted do
    ensure_table()

    {:ok, 200,
     %{
       "value" =>
         # list_all/1, not list/1: list/1 filters to the binary-key prefix
         # contract and silently drops tuple-keyed rows — deleted certificates
         # ride {:deleted, name} tuple keys (same defect class the secrets
         # mirror hit: witnessed live 2026-10-20, deleted secret present,
         # list []).
         Enum.flat_map(Store.list_all(@table), fn
           %{"is_deleted_certificate" => true} = record -> [record]
           _ -> []
         end)
     }}
  end

  @doc """
  `POST /deletedcertificates/:name/recover`. Restores the soft-deleted
  certificate to the live surface (same record, deletion fields dropped); the
  deleted bundle is removed. Unknown or purged certificate -> 404
  CertificateNotFound.
  """
  @spec recover(binary) :: {:ok, 200, map} | {:error, 404, map}
  def recover(name) do
    ensure_table()

    case Store.get(@table, {:deleted, name}) do
      {:ok, deleted} ->
        restored =
          deleted
          |> Map.drop(["deletedDate", "scheduledPurgeDate", "recoveryId", "is_deleted_certificate"])

        Store.put(@table, name, restored)
        Store.delete(@table, {:deleted, name})
        {:ok, 200, restored}

      :error ->
        {:error, 404, certificate_error("CertificateNotFound")}
    end
  end

  @doc """
  `POST /deletedcertificates/:name/purge`. Permanent removal — recover then
  404s. Unknown or already-purged certificate -> typed 404
  CertificateNotFound.
  """
  @spec purge(binary) :: {:ok, 204, map} | {:error, 404, map}
  def purge(name) do
    ensure_table()

    case Store.get(@table, {:deleted, name}) do
      {:ok, _deleted} ->
        Store.delete(@table, {:deleted, name})
        {:ok, 204, %{}}

      :error ->
        {:error, 404, certificate_error("CertificateNotFound")}
    end
  end

  @doc """
  Exports the stored certificate as PEM (`-----BEGIN CERTIFICATE-----`).
  The DER is re-encoded from the stored base64 — no cached side state.
  """
  @spec pem(binary) :: {:ok, binary} | {:error, 404, map}
  def pem(name) do
    case get(name) do
      {:ok, 200, record} ->
        {:ok, der} = Base.decode64(record["cer"])
        {:ok, :public_key.pem_encode([{:Certificate, der, :not_encrypted}])}

      error ->
        error
    end
  end

  # ---------------------------------------------------------------------------
  # X.509 minting (OTP :public_key)
  # ---------------------------------------------------------------------------

  @doc """
  Mints a self-signed X.509 v3 certificate: RSA-2048, SHA256WithRSAEncryption,
  subject == issuer (CN extracted from the policy subject string, e.g.
  `"CN=foo"`). Returns `{:ok, der_binary}`. `not_before`/`not_after` are
  unix seconds.
  """
  @spec mint_certificate(binary, binary, integer, integer) :: {:ok, binary}
  def mint_certificate(subject, issuer, not_before, not_after) do
    rsa_key = :public_key.generate_key({:rsa, 2048, 65_537})
    # {:RSAPrivateKey, version, n, e, d, ...}
    n = elem(rsa_key, 2)
    e = elem(rsa_key, 3)

    spki = {
      :"SubjectPublicKeyInfo",
      {:"AlgorithmIdentifier", {1, 2, 840, 113_549, 1, 1, 1}, {:asn1_OPENTYPE, <<5, 0>>}},
      :public_key.der_encode(:RSAPublicKey, {:"RSAPublicKey", e, n})
    }

    tbs = {
      :"OTPTBSCertificate",
      :v3,
      serial_number(),
      sig_alg(),
      name_rdn(issuer),
      {:"Validity", asn1_time(not_before), asn1_time(not_after)},
      name_rdn(subject),
      spki,
      # issuerUniqueID / subjectUniqueID / extensions — all absent
      :asn1_NOVALUE,
      :asn1_NOVALUE,
      :asn1_NOVALUE
    }

    tbs_der = :public_key.der_encode(:OTPTBSCertificate, tbs)
    signature = :public_key.sign(tbs_der, :sha256, rsa_key)

    cert = {:"OTPCertificate", tbs, sig_alg(), signature}

    {:ok, :public_key.der_encode(:OTPCertificate, cert)}
  end

  defp sig_alg do
    {:"SignatureAlgorithm", {1, 2, 840, 113_549, 1, 1, 11}, {:asn1_OPENTYPE, <<5, 0>>}}
  end

  defp serial_number do
    # Positive, RFC 5280-conformant (≤ 20 octets): 16 random bytes decoded
    # to a positive INTEGER (the ASN.1 encoder rejects raw binaries).
    :crypto.strong_rand_bytes(16)
    |> :binary.decode_unsigned()
    |> max(1)
  end

  defp name_rdn(cn) do
    cn_part = cn |> String.split("CN=", parts: 2) |> List.last() |> String.to_charlist()

    {:rdnSequence,
     [[{:"AttributeTypeAndValue", {2, 5, 4, 3}, {:printableString, cn_part}}]]}
  end

  defp asn1_time(unix_seconds) do
    {{y, mo, d}, {h, mi, s}} =
      :calendar.gregorian_seconds_to_datetime(unix_seconds + @gregorian_offset)

    if y >= 2050 do
      list =
        :io_lib.format(~c"~4.10.0B~2.10.0B~2.10.0B~2.10.0B~2.10.0B~2.10.0BZ", [y, mo, d, h, mi, s])
        |> IO.iodata_to_binary()
        |> String.to_charlist()

      {:generalizedTime, list}
    else
      # RFC 5280: UTCTime carries a TWO-digit year ("YYMMDDHHMMSSZ"). Encoding
      # the 4-digit year here made openssl answer "notBefore=Bad time value"
      # (witnessed on the KD-104 wire-fix re-witness, 2026-10-20).
      list =
        :io_lib.format(~c"~2.10.0B~2.10.0B~2.10.0B~2.10.0B~2.10.0B~2.10.0BZ", [
          rem(y, 100), mo, d, h, mi, s
        ])
        |> IO.iodata_to_binary()
        |> String.to_charlist()

      {:utcTime, list}
    end
  end

  defp add_months(unix_seconds, months) do
    {{y, m, d}, time} = :calendar.gregorian_seconds_to_datetime(unix_seconds + @gregorian_offset)

    total = (y - 1) * 12 + (m - 1) + months
    ny = div(total, 12) + 1
    nm = rem(total, 12) + 1
    nd = min(d, :calendar.last_day_of_the_month(ny, nm))

    :calendar.datetime_to_gregorian_seconds({{ny, nm, nd}, time}) - @gregorian_offset
  end

  defp certificate_error(code) do
    %{"error" => %{"code" => code, "message" => "#{code} on the certificates surface"}}
  end
end
