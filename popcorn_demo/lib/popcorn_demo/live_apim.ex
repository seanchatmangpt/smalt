defmodule PopcornDemo.LiveApim do
  @moduledoc """
  LANE X2 — API Management service loop leg (face-probe branch: UNSUPPORTED).

  ## UNSUPPORTED(apim-face-absent)

  The smalt ARM gateway (`lib/smalt/arm_gateway/router.ex`) routes these
  Microsoft faces: Resources/resourceGroups, Resources/tags(+tagValues),
  Authorization/locks, EventHub namespaces/eventhubs/consumergroups,
  ServiceBus namespaces/topics/subscriptions/rules, DocumentDB
  databaseAccounts/sqlDatabases/sqlContainers, KeyVault vaults/secrets,
  Network/dnsZones(+recordsets), Storage, ManagedIdentity — but NO
  `Microsoft.ApiManagement` route family (services/apis/products/
  subscriptions).

  Witnessed on the live wire (2026-10-20, substrate 9443, never restarted):
  with a real STS bearer minted at `POST /{tenant}/oauth2/v2.0/token`, a
  PUT of a would-be `Microsoft.ApiManagement/service` resource is refused
  with a TYPED refusal — HTTP 400 `InvalidResourceShape`, message
  "GraphLaw validation failure: Resource type Microsoft.ApiManagement/
  service is not an admitted ontology individual in smalt-substrate-pack"
  (AshGraphLaw.Enforcement) — and a follow-up GET of the same URI is 404
  (no residue). The leg therefore cannot walk the bearer→create→list→GET→
  delete loop and is typed UNSUPPORTED — never a fake pass.

  Close condition: when an ApiManagement route family / ontology individual
  lands, the probe PUT flips to 2xx and run/0 returns
  `apim=FAIL(face-now-present:HTTP-<s>)` — the loud signal to re-author the
  walk branch (bearer → create → list → GET → delete) and flip to
  `apim=OK(...)`.

  Receipts (run/0 return), house style:
    {:skip,  "apim=SKIP(apim-face-absent)"}           -- the only passing outcome while absent
    {:error, "apim=FAIL(face-now-present:HTTP-<s>)"}  -- face landed; re-author the walk
    {:error, "apim=FAIL(mint|probe:<reason>)"}        -- absence proof broke (e.g. substrate down)

  Not wired into the supervision tree — coordinator integrates.
  Export `run/0` only.
  """

  @arm "http://127.0.0.1:9443"
  @tenant "00000000-0000-0000-0000-000000000000"
  @apim_type "Microsoft.ApiManagement/service"

  @doc "Typed UNSUPPORTED while no ApiManagement face exists in the ARM gateway."
  @spec run() :: {:skip, binary()} | {:error, binary()}
  def run do
    with {:ok, _tok} <- mint(),
         :absent <- probe_face_absent() do
      {:skip, "apim=SKIP(apim-face-absent)"}
    end
  end

  # -- Steps ----------------------------------------------------------------

  defp mint do
    form =
      "grant_type=client_credentials&client_id=x&client_secret=y" <>
        "&scope=https://management.azure.com/.default"

    url = "#{@arm}/#{@tenant}/oauth2/v2.0/token"

    case :httpc.request(
           :post,
           {String.to_charlist(url), [],
            ~c"application/x-www-form-urlencoded", String.to_charlist(form)},
           [],
           body_format: :binary
         ) do
      {:ok, {{_, 200, _}, _, body}} ->
        case Jason.decode(body) do
          {:ok, %{"access_token" => tok}} when is_binary(tok) ->
            Process.put({__MODULE__, :token}, tok)
            {:ok, tok}
          other -> {:error, "apim=FAIL(mint:no-access_token:#{slice(inspect(other))})"}
        end

      {:ok, {{_, status, _}, _, body}} ->
        {:error, "apim=FAIL(mint:STS-status-#{status}:#{slice(body)})"}

      {:error, reason} ->
        {:error, "apim=FAIL(mint:transport:#{slice(inspect(reason))})"}
    end
  end

  # The absence proof: with a real bearer, a PUT of a would-be Apim resource
  # must be refused by ontology enforcement (400 InvalidResourceShape — not
  # an admitted individual). Any 2xx means the face landed; a transport
  # error means the substrate is down. Both are FAIL, never a silent SKIP.
  defp probe_face_absent do
    body =
      Jason.encode!(%{
        "id" => @apim_type <> "/x2-probe",
        "name" => "x2-probe",
        "type" => @apim_type,
        "properties" => %{"publisherEmail" => "x2@smalt.local", "publisherName" => "x2"}
      })

    url =
      "#{@arm}/subscriptions/00000000-0000-0000-0000-000000000000/" <>
        "resourceGroups/x2/providers/#{@apim_type}/x2-probe?api-version=2022-08-01"

    case :httpc.request(
           :put,
           {String.to_charlist(url), bearer_headers(), ~c"application/json",
            String.to_charlist(body)},
           [],
           body_format: :binary
         ) do
      {:ok, {{_, status, _}, _, _resp}} when status in 200..299 ->
        {:present, status}

      {:ok, {{_, _status, _}, _, _resp}} ->
        :absent

      {:error, reason} ->
        {:error, "apim=FAIL(probe:transport:#{slice(inspect(reason))})"}
    end
  end

  # -- Helpers ---------------------------------------------------------------

  defp bearer_headers do
    tok = Process.get({__MODULE__, :token})
    if is_binary(tok), do: [{~c"authorization", String.to_charlist("Bearer " <> tok)}], else: []
  end

  defp slice(b), do: String.slice(b, 0, 120)
end
