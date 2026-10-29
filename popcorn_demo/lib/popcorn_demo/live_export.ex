defmodule PopcornDemo.LiveExport do
  @moduledoc """
  X7 — resource-group exportTemplate leg (KD-59 export face) over the REAL
  smalt substrate (ARM control plane 9443). No mocks.

  One `run/0`:

    1. mint an STS bearer at `POST /{tenant}/oauth2/v2.0/token`
    2. ensure RG `popcorn-export-rg` via ARM PUT
    3. seed TWO registry-admitted resources with run-unique names:
       - `Microsoft.Storage/storageAccounts` (generic provider PUT)
       - `Microsoft.App/containerApps` (generic provider PUT)
    4. `POST .../exportTemplate` and assert 200 with a template whose
       `resources` array contains BOTH seeded resources (type+name match),
       each entry carrying type / apiVersion / name / location / properties
    5. negative: `POST .../exportTemplate` on an ABSENT resource group →
       typed 404 `ResourceGroupResourceNotFound` (router handle_export_template
       -> Smalt.Arm.ExportTemplate.export_rg/3 empty-prefix law).

  Wire seam: lib/smalt/arm_gateway/router.ex:3714 exportTemplate route ->
  handle_export_template -> Smalt.Arm.ExportTemplate.export_rg/3 (Store
  :smalt_resources prefix scan; empty -> typed 404).

  Receipts (run/0 return), house style:
    {:ok,    "export=OK(<n>-resources-exported)"}
    {:skip,  "export=SKIP(transport:<reason>)"}   -- substrate down
    {:error, "export=FAIL(<step>:<reason>)"}      -- any other failure

  Transport (single calculus): all HTTP rides `PopcornDemo.Transport`
  (host: `Transport.Httpc`), raw binary bodies, JSON decoded at THIS edge.
  Not wired into the supervision tree — coordinator integrates.
  Export `run/0` + test seams only.
  """

  @base "http://127.0.0.1:9443"
  @tenant "00000000-0000-0000-0000-000000000000"
  @scope "https://management.azure.com/.default"
  @api "api-version=2023-05-01"

  @sub_id "popcorn-export-rg-sub"
  @rg "popcorn-export-rg"
  @sa_type "Microsoft.Storage/storageAccounts"
  @ca_type "Microsoft.App/containerApps"

  @rg_base "/subscriptions/#{@sub_id}/resourceGroups/#{@rg}"
  @sa_base "#{@rg_base}/providers/Microsoft.Storage/storageAccounts"
  @ca_base "#{@rg_base}/providers/Microsoft.App/containerApps"

  # RUN-UNIQUE names (live_tags/live_lifecycle pattern): fixed names
  # self-collide under parallel full-suite runs.
  defp unique do
    "popcorn-export-" <> Integer.to_string(:erlang.unique_integer([:positive]))
  end

  defp sa, do: Process.get({__MODULE__, :sa}) || unique()
  defp ca, do: Process.get({__MODULE__, :ca}) || unique()

  @doc "Full walk: seed 2 resources + exportTemplate round-trip + typed-404 negative."
  @spec run() :: {:ok, binary()} | {:skip, binary()} | {:error, binary()}
  def run do
    Process.put({__MODULE__, :sa}, unique())
    Process.put({__MODULE__, :ca}, unique())

    with :ok <- mint(),
         :ok <- ensure_rg(),
         :ok <- put_storage_account(),
         :ok <- put_container_app(),
         {:ok, n} <- export_template(),
         :ok <- export_absent_rg() do
      {:ok, "export=OK(#{n}-resources-exported)"}
    end
  end

  # -- Steps -------------------------------------------------------------------

  defp slice(r) when is_binary(r), do: String.slice(r, 0, 120)
  defp slice(r), do: r |> inspect() |> String.slice(0, 120)

  defp mint do
    body =
      "grant_type=client_credentials&client_id=x&client_secret=y" <>
        "&scope=#{@scope}"

    case req(:post, "#{@base}/#{@tenant}/oauth2/v2.0/token",
            body: body,
            headers: [{"content-type", "application/x-www-form-urlencoded"}]
          ) do
      {:ok, %{status: 200, body: %{"access_token" => tok}}} when is_binary(tok) ->
        Process.put({__MODULE__, :token}, tok)
        :ok

      {:ok, %{status: s, body: b}} ->
        {:error, "export=FAIL(mint:STS-status-#{s}-body=#{slice(b)})"}

      {:error, reason} ->
        {:skip, "export=SKIP(transport:#{slice(reason)})"}
    end
  end

  defp ensure_rg do
    case arm_req(:put, @rg_base, %{"location" => "eastus", "properties" => %{}}) do
      {:ok, %{status: s}} when s in [200, 201] ->
        :ok

      {:ok, %{status: s, body: b}} ->
        {:error, "export=FAIL(ensure_rg:HTTP-#{s}-#{slice(b)})"}

      {:error, reason} ->
        {:skip, "export=SKIP(transport:#{slice(reason)})"}
    end
  end

  defp put_storage_account do
    body = %{
      "location" => "eastus",
      "kind" => "StorageV2",
      "properties" => %{"supportsHttpsTrafficOnly" => true}
    }

    case arm_req(:put, "#{@sa_base}/#{sa()}", body) do
      {:ok, %{status: s}} when s in [200, 201, 202] ->
        :ok

      {:ok, %{status: s, body: b}} ->
        {:error, "export=FAIL(put_storage_account:HTTP-#{s}-#{slice(b)})"}

      {:error, reason} ->
        {:skip, "export=SKIP(transport:#{slice(reason)})"}
    end
  end

  defp put_container_app do
    body = %{
      "location" => "eastus",
      "properties" => %{
        "environmentId" => "",
        "template" => %{"containers" => []},
        "configuration" => %{}
      }
    }

    case arm_req(:put, "#{@ca_base}/#{ca()}", body) do
      {:ok, %{status: s}} when s in [200, 201, 202] ->
        :ok

      {:ok, %{status: s, body: b}} ->
        {:error, "export=FAIL(put_container_app:HTTP-#{s}-#{slice(b)})"}

      {:error, reason} ->
        {:skip, "export=SKIP(transport:#{slice(reason)})"}
    end
  end

  # Export the seeded RG: 200 + template containing BOTH resources.
  defp export_template do
    case arm_req(:post, "#{@rg_base}/exportTemplate", %{}) do
      {:ok, %{status: 200, body: %{"resources" => resources} = tpl}} when is_list(resources) ->
        with :ok <- template_shape(tpl),
             :ok <- assert_both_seeded(resources) do
          {:ok, length(resources)}
        end

      {:ok, %{status: s, body: b}} ->
        {:error, "export=FAIL(export_template:HTTP-#{s}-#{slice(b)})"}

      {:error, reason} ->
        {:skip, "export=SKIP(transport:#{slice(reason)})"}
    end
  end

  # ARM template envelope: schema/contentVersion/parameters/variables/outputs.
  defp template_shape(tpl) do
    schema = tpl["$schema"]
    cv = tpl["contentVersion"]

    if is_binary(schema) and schema =~ "deploymentTemplate.json#" and
         is_binary(cv) and tpl["parameters"] == %{} and tpl["variables"] == %{} do
      :ok
    else
      {:error, "export=FAIL(template_shape:bad-envelope-#{slice(tpl)})"}
    end
  end

  defp assert_both_seeded(resources) do
    sa_entry =
      Enum.find(resources, &(&1["type"] == @sa_type and &1["name"] == sa()))

    ca_entry =
      Enum.find(resources, &(&1["type"] == @ca_type and &1["name"] == ca()))

    cond do
      is_nil(sa_entry) ->
        {:error,
         "export=FAIL(export_template:storage-account-missing-from-template)"}

      is_nil(ca_entry) ->
        {:error,
         "export=FAIL(export_template:container-app-missing-from-template)"}

      # Every entry carries the full export face (export_template.ex:82).
      Enum.all?(resources, fn r ->
        is_binary(r["type"]) and is_binary(r["name"]) and is_binary(r["apiVersion"]) and
          is_binary(r["location"]) and is_map(r["properties"])
      end) ->
        :ok

      true ->
        {:error,
         "export=FAIL(export_template:entry-missing-required-fields-#{slice(resources)})"}
    end
  end

  # Negative: absent RG exports to a typed 404 (empty :smalt_resources prefix).
  defp export_absent_rg do
    absent_base =
      "/subscriptions/#{@sub_id}/resourceGroups/popcorn-export-absent-#{Integer.to_string(:erlang.unique_integer([:positive]))}"

    case arm_req(:post, "#{absent_base}/exportTemplate", %{}) do
      {:ok, %{status: 404, body: %{"error" => %{"code" => "ResourceGroupResourceNotFound"}}}} ->
        :ok

      {:ok, %{status: s, body: b}} ->
        {:error, "export=FAIL(export_absent_rg:HTTP-#{s}-#{slice(b)})"}

      {:error, reason} ->
        {:skip, "export=SKIP(transport:#{slice(reason)})"}
    end
  end

  # -- Test seams (public) ------------------------------------------------------

  @doc "RG path of the export RG."
  def rg_path, do: @rg_base

  @doc "Seeded storage account ARM path."
  def sa_path, do: "#{@sa_base}/#{sa()}"

  @doc "Seeded containerApp ARM path."
  def ca_path, do: "#{@ca_base}/#{ca()}"

  @doc "Admitted ARM type under test: storage account."
  def sa_type, do: @sa_type

  @doc "Admitted ARM type under test: containerApp."
  def ca_type, do: @ca_type

  @doc """
  Real exportTemplate POST of the seeded RG over the live substrate (test
  seam). Requires run/0 (or the test's own mint) to have set the bearer.
  """
  def fetch_export do
    with :ok <- mint(),
         {:ok, %{status: 200, body: %{"resources" => _} = tpl}} <-
           arm_req(:post, "#{@rg_base}/exportTemplate", %{}) do
      {:ok, tpl}
    else
      {:ok, %{status: s, body: b}} ->
        {:error, "export=FAIL(fetch_export:HTTP-#{s}-#{slice(b)})"}

      {:skip, _} = skip ->
        skip

      {:error, reason} ->
        {:skip, "export=SKIP(transport:#{slice(reason)})"}
    end
  end

  @doc "Tokenless negative (test seam): exportTemplate with NO bearer -> 401."
  def fetch_tokenless do
    Process.delete({__MODULE__, :token})
    req(:post, "#{@base}#{@rg_base}/exportTemplate?#{@api}", body: "{}")
  end

  defp arm_req(method, path, body_map \\ nil) do
    url = "#{@base}#{path}?#{@api}"

    if body_map do
      req(method, url,
        body: Jason.encode!(body_map),
        headers: [{"content-type", "application/json"}]
      )
    else
      req(method, url)
    end
  end

  # -- Transport (single calculus, mirrors LiveTags) ----------------------------

  defp browser? do
    Code.ensure_loaded?(Popcorn.JS) and function_exported?(Popcorn.JS, :available?, 0) and
      Popcorn.JS.available?()
  end

  defp req(method, url, opts \\ []) do
    body =
      if method == :get and not Keyword.has_key?(opts, :body),
        do: nil,
        else: Keyword.get(opts, :body, "")

    request = %{
      method: String.upcase(to_string(method)),
      url: url,
      headers: headers_for(Keyword.get(opts, :headers, [])),
      body: body
    }

    if browser?() do
      request |> PopcornDemo.Transport.Fetch.request() |> decode_body()
    else
      request |> PopcornDemo.Transport.Httpc.request() |> decode_body()
    end
  end

  defp decode_body({:ok, %{body: body} = resp}) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, %{resp | body: decoded}}
      _ -> {:ok, resp}
    end
  end

  defp decode_body(other), do: other

  defp headers_for(extra) do
    bearer =
      case Process.get({__MODULE__, :token}) do
        nil -> []
        tok -> [{"authorization", "Bearer " <> tok}]
      end

    extra = List.wrap(extra)
    has_ct = Enum.any?(extra, fn {k, _} -> String.downcase(k) == "content-type" end)
    default = if has_ct, do: [], else: [{"content-type", "application/json"}]
    default ++ extra ++ bearer
  end
end
