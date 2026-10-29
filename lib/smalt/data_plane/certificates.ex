defmodule Smalt.DataPlane.Certificates do
  # KD-COVERS: KD-104 (certificates plane: create/get/list/delete/purge;
  # flip-gated on the CertificateClient-tier witness receipt)
  @moduledoc """
  Minimal Azure Key Vault Certificates data plane (KD-104) over a
  module-owned, heir'd ETS table `:smalt_vault_certificates`.

  Strictly the verbs the KD-104 falsifier names (CertificateClient
  create/get + list, plus delete) plus the create-LRO operation face:
  NO versions/latest surface, NO merge — Azure's create here completes
  synchronously, but the operation record EXISTS and completes so the
  SDK poller terminates.

  Wire surface (routes live in `EgressRouter`; wiring seam is the same
  `{:ok, status, body}` tuple contract the `/keys` + `/secrets` siblings
  use, so a handler is one `case`):

    - `POST /certificates/:name/create` -> `create/3` (self-signed X.509
      minted from the request policy; ALSO plants the CertificateOperation
      record under `{:pending, name}`)
    - `GET  /certificates/:name/pending` -> `get_pending/1` (200
      CertificateOperation; the synchronous mint completes on first
      observation — `status` flips `in-progress` -> `completed`)
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
      :ok ->
        # LRO operation face (wf4 finding: the SDK poller hangs on a missing
        # pending face — GET .../pending answered 400 MissingXMsVersion as a
        # blob splat fallthrough, KD-104 witness step 2). The operation record
        # is planted ATOMICALLY with the certificate insert (same process,
        # after insert_new wins) and completes on first observation.
        Store.put(@table, {:pending, name}, pending_operation(host, name, now))

        {:ok, 201, record}

      {:error, :exists} ->
        {:error, 409, certificate_error("CertificateNameAlreadyExists")}
    end
  end

  defp pending_operation(host, name, now) do
    %{
      "id" => "https://#{host}:8443/certificates/#{name}/pending",
      "name" => name,
      "status" => "in-progress",
      "status_details" => [],
      "cancellation_requested" => false,
      "target" => "https://#{host}:8443/certificates/#{name}",
      "request_id" => Base.encode16(:crypto.strong_rand_bytes(8), case: :lower),
      "attributes" => %{
        "created" => now,
        "updated" => now,
        "recoveryLevel" => "Purgeable"
      }
    }
  end

  # ---------------------------------------------------------------------------
  # Pending operation (create LRO)
  # ---------------------------------------------------------------------------

  @doc """
  `GET /certificates/:name/pending`. The CertificateOperation for the create
  LRO. The mint here is synchronous, so the operation record exists (planted
  by `create/3`) and completes on first observation: the returned status is
  `"completed"` and the stored record is updated so later polls stay
  `"completed"` (the SDK poller needs the 200 + `status: "completed"` to
  terminate).

  Unknown or purged certificate -> typed
  `404 PendingCertificateNotFound`.
  """
  @spec get_pending(binary) :: {:ok, 200, map} | {:error, 404, map}
  def get_pending(name) do
    ensure_table()

    case Store.get(@table, {:pending, name}) do
      {:ok, op} ->
        completed =
          case op["status"] do
            "completed" ->
              op

            _ ->
              completed = Map.put(op, "status", "completed")
              Store.put(@table, {:pending, name}, completed)
              completed
          end

        {:ok, 200, completed}

      :error ->
        {:error, 404, certificate_error("PendingCertificateNotFound")}
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
        # The soft-deleted surface has no outstanding create operation.
        Store.delete(@table, {:pending, name})
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

  # ---------------------------------------------------------------------------
  # Issuers + contacts (wave-6 lane w6c) — Azure KV REST parity
  # ---------------------------------------------------------------------------

  # ---------------------------------------------------------------------------
  # Backup / restore (wave-6 lane w6ab) — Azure KV shape over the SAME
  # SMALT-KVB1 envelope contract as the keys backup (same magic + checksum);
  # kind-tagged "certificate" so a wrong-kind blob is a typed 400.
  # ---------------------------------------------------------------------------

  @doc """
  `POST /certificates/{name}/backup` face. Returns `{"value" => blob}`
  (`SMALT-KVB1.<base64 JSON envelope>`, kind "certificate") carrying the live
  certificate row (cer DER, policy, attributes). Unknown certificate ->
  `{:error, 404, CertificateNotFound}`.
  """
  @spec backup(binary) :: {:ok, 200, %{binary() => binary()}} | {:error, 404, map()}
  def backup(name) when is_binary(name) do
    ensure_table()

    case Store.get(@table, name) do
      {:ok, record} ->
        bundle = %{"kind" => "certificate", "name" => name, "record" => record}
        {:ok, 200, %{"value" => backup_codec().kv_backup_encode(bundle)}}

      :error ->
        {:error, 404, certificate_error("CertificateNotFound")}
    end
  end

  @doc """
  `POST /certificates/{name}/restore` face. `restore(blob)` /
  `restore(blob, force: true)`. Restores the encapsulated certificate under
  its own name. Typed refusals: malformed/tampered/wrong-kind blob ->
  `{:error, 400, MalformedBackupBlob}`; live name -> `{:error, 409,
  NameConflict}` unless `force: true`. Fresh restore -> 201; force
  overwrite -> 200.
  """
  @spec restore(binary, keyword) :: {:ok, 200 | 201, map()} | {:error, 400 | 409, map()}
  def restore(blob, opts \\ []) when is_binary(blob) and is_list(opts) do
    ensure_table()
    force = Keyword.get(opts, :force, false)

    case backup_codec().kv_backup_decode(blob, "certificate") do
      {:ok, bundle} ->
        name = bundle["name"]
        record = bundle["record"]

        case Store.get(@table, name) do
          {:ok, _existing} ->
            if force do
              Store.put(@table, name, record)
              {:ok, 200, record}
            else
              {:error, 409,
               %{
                 "error" => %{
                   "code" => "NameConflict",
                   "message" => "certificate #{name} exists and is live; delete (or purge) it before restore"
                 }
               }}
            end

          :error ->
            Store.put(@table, name, record)
            {:ok, 201, record}
        end

      {:error, 400, refusal} = refusal_tuple ->
        _ = refusal
        refusal_tuple
    end
  end

  # The keys module (KeyVaultActions) owns the envelope codec; reusing it
  # keeps ONE canonical SMALT-KVB1 envelope across keys/certificates/secrets
  # (same-checkout capital reuse — never re-implement the checksum).
  defp backup_codec, do: Smalt.DataPlane.KeyVaultActions

  @doc """
  `PUT /certificates/issuers/:name`. Create-or-replace issuer. `provider`
  required on every PUT (typed 400 BadRequest when absent/empty). Full-replace
  semantics; `created` preserved on replace, `updated` re-stamped. The issuer
  password (`pwd`) is stored but never echoed (real-service parity:
  write-only). GET/DELETE unknown -> typed `404 IssuerNotFound`.
  """
  @spec put_issuer(binary, Plug.Conn.t() | binary, map) ::
          {:ok, 200, map} | {:error, 400, map}
  def put_issuer(name, conn_or_host, body_params) do
    ensure_table()

    host =
      case conn_or_host do
        %Plug.Conn{host: host} -> host
        host when is_binary(host) -> host
      end

    body = body_params || %{}
    provider = body["provider"]

    if is_binary(provider) and provider != "" do
      now = System.system_time(:second)

      created =
        case Store.get(@table, {:issuer, name}) do
          {:ok, prev} -> get_in(prev, ["attributes", "created"]) || now
          :error -> now
        end

      creds_in = body["credentials"]
      creds_in = if is_map(creds_in), do: creds_in, else: %{}

      organization_details =
        if is_map(body["organization_details"]), do: body["organization_details"], else: %{}

      attrs_in = body["attributes"]
      attrs_in = if is_map(attrs_in), do: attrs_in, else: %{}

      record = %{
        "id" => "https://#{host}:8443/certificates/issuers/#{name}",
        "issuer" => name,
        "provider" => provider,
        "credentials" => %{
          "account_id" => creds_in["account_id"],
          "pwd" => creds_in["pwd"]
        },
        "organization_details" => organization_details,
        "attributes" => %{
          "enabled" => if(is_nil(attrs_in["enabled"]), do: true, else: attrs_in["enabled"]),
          "created" => created,
          "updated" => now
        },
        "is_issuer" => true
      }

      Store.put(@table, {:issuer, name}, record)
      {:ok, 200, issuer_wire(record)}
    else
      # provider-less PUT -> typed 400 BadRequest
      {:error, 400, certificate_error("BadRequest")}
    end
  end

  defp issuer_wire(record) do
    # pwd is write-only: the response never carries it (real-service parity).
    record
    |> Map.delete("is_issuer")
    |> Map.update!("credentials", &Map.delete(&1, "pwd"))
  end

  @doc """
  `GET /certificates/issuers/:name`. Unknown -> typed `404 IssuerNotFound`.
  """
  @spec get_issuer(binary) :: {:ok, 200, map} | {:error, 404, map}
  def get_issuer(name) do
    ensure_table()

    case Store.get(@table, {:issuer, name}) do
      {:ok, record} -> {:ok, 200, issuer_wire(record)}
      :error -> {:error, 404, certificate_error("IssuerNotFound")}
    end
  end

  @doc """
  `DELETE /certificates/issuers/:name`. Returns the issuer (200), then gone
  (next GET 404s). Unknown -> typed `404 IssuerNotFound`.
  """
  @spec delete_issuer(binary) :: {:ok, 200, map} | {:error, 404, map}
  def delete_issuer(name) do
    ensure_table()

    case Store.get(@table, {:issuer, name}) do
      {:ok, record} ->
        Store.delete(@table, {:issuer, name})
        {:ok, 200, issuer_wire(record)}

      :error ->
        {:error, 404, certificate_error("IssuerNotFound")}
    end
  end

  @doc """
  `GET /certificates/issuers` ->
  `{"value": [{"id", "provider"}]}` (CertificateIssuerItem envelope). Walks
  list_all/1 (tuple-keyed rows) filtering the `is_issuer` flag — the
  binary-key `Store.list/1` contract would silently drop tuple rows
  (same class as the deleted-certificates list fix).
  """
  @spec list_issuers :: {:ok, 200, map}
  def list_issuers do
    ensure_table()

    {:ok, 200,
     %{
       "value" =>
         Enum.flat_map(Store.list_all(@table), fn
           %{"is_issuer" => true} = r -> [%{"id" => r["id"], "provider" => r["provider"]}]
           _ -> []
         end)
     }}
  end

  @doc """
  `GET /certificates/contacts`. Never-set -> typed `404 ContactNotFound`.
  """
  @spec get_contacts :: {:ok, 200, map} | {:error, 404, map}
  def get_contacts do
    ensure_table()

    case Store.get(@table, {:contacts, :vault}) do
      {:ok, record} -> {:ok, 200, Map.delete(record, "is_contacts")}
      :error -> {:error, 404, certificate_error("ContactNotFound")}
    end
  end

  @doc """
  `PUT /certificates/contacts` (put_contacts/2). Full-replace of the
  vault-wide contacts resource; `contacts` must be a non-empty list of maps
  each carrying binary `email_address`; malformed -> typed 400 BadRequest.
  """
  @spec put_contacts(binary, map) :: {:ok, 200, map} | {:error, 400, map}
  def put_contacts(conn_or_host, body_params) do
    ensure_table()

    host =
      case conn_or_host do
        %Plug.Conn{host: host} -> host
        host when is_binary(host) -> host
      end

    body = body_params || %{}
    contacts = body["contacts"]

    valid =
      is_list(contacts) and contacts != [] and
        Enum.all?(contacts, fn c -> is_map(c) and is_binary(c["email_address"]) end)

    if valid do
      record = %{
        "id" => "https://#{host}:8443/certificates/contacts",
        "contacts" =>
          Enum.map(contacts, fn c ->
            %{
              "email_address" => c["email_address"],
              "name" => c["name"],
              "phone" => c["phone"]
            }
          end),
        "is_contacts" => true
      }

      Store.put(@table, {:contacts, :vault}, record)
      {:ok, 200, Map.delete(record, "is_contacts")}
    else
      # malformed -> typed 400 BadRequest
      {:error, 400, certificate_error("BadRequest")}
    end
  end

  @doc """
  `DELETE /certificates/contacts` → 204 when set; never-set -> typed 404
  ContactNotFound.
  """
  @spec delete_contacts :: {:ok, 204, map} | {:error, 404, map}
  def delete_contacts do
    ensure_table()

    case Store.get(@table, {:contacts, :vault}) do
      {:ok, _record} ->
        Store.delete(@table, {:contacts, :vault})
        {:ok, 204, %{}}

      :error ->
        {:error, 404, certificate_error("ContactNotFound")}
    end
  end

  @doc """
  Exports the stored certificate as PEM (`-----BEGIN CERTIFICATE-----`).

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
      # JA-R3-order fix (BK-VCOURTS): :RSAPublicKey is SEQUENCE { modulus,
      # publicExponent } — n first, e second. The previous {e, n} order
      # minted certs whose embedded key swapped modulus/exponent; OTP
      # pkix_path_validation refuses them {:bad_cert, :invalid_signature}
      # (openssl -CAfile verify is vacuous for self-anchors and did not
      # catch it). Witness: receipts/bkvc-consolidated-courts.md.
      :public_key.der_encode(:RSAPublicKey, {:"RSAPublicKey", n, e})
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
