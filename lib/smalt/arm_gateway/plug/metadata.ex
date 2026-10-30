
defmodule Smalt.ArmGateway.Plug.Metadata do
  @moduledoc """
  Route-family plug (T06, v26.10.29): IMDS/metadata + health faces.

  Pass-through dispatch: routes were extracted verbatim from the monolithic
  router; a conn no route claims returns UNCHANGED (not halted) via the
  trailing pass-through match, so the front pipeline composes unchanged.
  """
  import Smalt.ArmGateway.Plug.Common


  use Plug.Router
  require Logger
  plug(:match)
  plug(:dispatch)

  # T06 dispatch law: a family route that ANSWERED (state :sent) must halt, or
  # the front pipeline would keep piping and the front catch-all would
  # re-dispatch on a sent conn (Plug.Conn.AlreadySentError). Answered conns
  # halt here; unclaimed conns (state :unset) pass through untouched.
  def call(conn, opts) do
    case super(conn, opts) do
      %Plug.Conn{state: :sent, halted: false} = c -> halt(c)
      c -> c
    end
  end

  # -- IMDS / managed identity (w6r) -------------------------------------------
  # Leaf route ahead of the bearer-guarded generic routes; Plug.Router matched
  # the path only (query string excluded). Serves ARM 9443 and the TLS twin.
  get "/metadata/identity/oauth2/token" do
    Smalt.Auth.Imds.handle_token(conn)
  end

  # -- Bootstrap / discovery endpoints ----------------------------------------
  get "/metadata/endpoints" do
    authority = request_authority(conn)

    body =
      Jason.encode!(%{
        # 2022-09-01 schema (go-azure-sdk metadata.Client.GetMetaData; the
        # azurerm ARM_METADATA_HOSTNAME path requires name, resourceManager
        # and a TOP-LEVEL microsoftGraphResourceId — the parser reads
        # metadata.MicrosoftGraphResourceId (json "microsoftGraphResourceId",
        # flat), NOT a nested "resourceIdentifiers" object; witnessed by
        # azurerm 4.54.0 "no `microsoftGraphResourceId` was returned" until
        # the flat key landed (tf-plan probe lane, 2026-10-16).
        "name" => "smalt-sovereign",
        # Echo the request authority, not a hardcoded 9443: the metadata doc
        # is what go-azure-sdk builds its Environment from, so a hardcoded
        # port silently re-points every lane-private substrate's clients at
        # the shared 9443 substrate (witnessed: cross-substrate STS
        # SignatureVerificationFailed 401s, tf-plan probe lane 2026-10-16).
        # KD-T5-F2: azurerm joins resourceManager verbatim with "/subscriptions/..."
        # (no TrimSuffix "/") — a trailing slash built
        # https://localhost:39391//subscriptions/... and the connection was
        # reset (T5 cleanroom tf-apply.log). The management-plane roots are
        # emitted WITHOUT the trailing slash; real Azure's roots carry it,
        # so this is a join-semantics deviation, deliberate.
        "resourceManagerEndpoint" => String.trim_trailing(authority, "/"),
        # KD-COVERS: KD-80 (metadata resourceManager trailing-slash join semantics)
        "resourceManager" => String.trim_trailing(authority, "/"),
        "managementEndpoint" => String.trim_trailing(authority, "/"),
        "activeDirectoryEndpoint" => "#{authority}/",
        "microsoftGraphResourceId" => "https://graph.smalt.local/",
        # legacy consumers (SDK docs surface a resourceIdentifiers object);
        # go-azure-sdk itself ignores this nesting, kept for shape parity.
        "resourceIdentifiers" => %{
          "microsoftGraphResourceId" => "https://graph.smalt.local/"
        },
        # go-azure-sdk metadata parser reads json key "suffixes" (flat Azure
        # suffix names); "dnsSuffixes" is the shape OTHER clients document but
        # the Go parser never reads it — witnessed: azurerm 4.54.0 Storage
        # authorizer "endpoint AzureStorage is not supported" until the
        # suffixes map landed (tf-plan probe lane, 2026-10-16).
        "suffixes" => %{
          "keyVaultDns" => "vault.smalt.local",
          "storage" => "smalt.local",
          "sqlServerHostname" => "database.smalt.local",
          "acrLoginServer" => "registry.smalt.local",
          "mhsmDns" => "managedhsm.smalt.local",
          "attestationEndpoint" => "attest.smalt.local",
          "azureFrontDoorEndpointSuffix" => "afd.smalt.local",
          "storageSyncEndpointSuffix" => "afshare.smalt.local",
          "synapseAnalytics" => "dev.smalt.local",
          "mysqlServerEndpoint" => "mysql.smalt.local",
          "postgresqlServerEndpoint" => "postgres.smalt.local",
          "mariadbServerEndpoint" => "mariadb.smalt.local",
          "azureDataLakeStoreFileSystem" => "azuredatalakestore.smalt.local"
        },
        "dnsSuffixes" => %{
          "keyVault" => "vault.smalt.local",
          "storage" => "smalt.local",
          "sqlServer" => "database.smalt.local",
          "containerRegistry" => "registry.smalt.local",
          "attestation" => "attest.smalt.local",
          "frontDoor" => "afd.smalt.local",
          "managedHSM" => "managedhsm.smalt.local",
          "storageSync" => "afshare.smalt.local",
          "synapse" => "dev.smalt.local",
          "dataLakeStore" => "azuredatalakestore.smalt.local",
          "mariaDb" => "mariadb.smalt.local",
          "mySql" => "mysql.smalt.local",
          "postgresql" => "postgres.smalt.local"
        },
        "authentication" => %{
          # Same host the client used (TLS-twin clients get a working
          # https envelope; azidentity permits plaintext http only for
          # localhost, which is the documented local form).
          "loginEndpoint" => "#{request_authority(conn)}/",
          "audiences" => ["https://management.azure.com"],
          # go-azure-sdk Environment.IsAzureStack() classifies the
          # environment as Azure Stack (hard-rejected by azurerm) unless
          # identityProvider == "AAD" and tenant == "common".
          "identityProvider" => "AAD",
          "tenant" => "common"
        },
        # legacy (api-version<=2018-01) shape kept for older consumers
        # (managementEndpoint/resourceManager/activeDirectoryEndpoint now echo
        # the request authority — see above).
        "graphEndpoint" => "https://graph.smalt.local/",
        "graph" => "https://graph.smalt.local/",
        "sqlManagement" => "https://management.core.smalt.local/",
        "galleryEndpoint" => "https://gallery.smalt.local/",
        "activeDirectoryResourceId" => "https://management.azure.com/"
      })

    send_json(conn, 200, body)
  end

  # -- Health probe faces (BK-PROBE, BK-ARM1 F-1) ------------------------------
  # The kernel's self-report (Smalt.Health) rendered as typed HTTP: 200/503.
  # kubelet's probes point here (k8s/smalt-backend.yaml) — previously both
  # probes polled /metadata/endpoints, a static always-200 metadata handler,
  # so kubelet could only ever detect a dead listener, never a degraded BEAM.
  # Declared before the flat ATOM aliases and the /:entity_name catch-alls;
  # the three-segment paths cannot collide with them regardless. Paths sit in
  # the /.well-known/ bearer-exempt namespace (Smalt.Auth.Bearer
  # @exempt_prefixes) — kubelet probes are tokenless bootstrap-class
  # requests, same as /metadata/endpoints.
  get "/.well-known/health/live" do
    case Smalt.Health.liveness() do
      :alive -> send_json(conn, 200, Jason.encode!(%{status: "alive"}))
    end
  end

  get "/.well-known/health/ready" do
    verdict = Smalt.Health.readiness()

    send_json(
      conn,
      Smalt.Health.http_status(verdict),
      Jason.encode!(Smalt.Health.to_json_map(verdict))
    )
  end


  # Pass-through tail (T06): a conn no route above claimed returns UNCHANGED
  # (not halted) so the next plug in the front pipeline complies unchanged.
  match _ do
    conn
  end
end
