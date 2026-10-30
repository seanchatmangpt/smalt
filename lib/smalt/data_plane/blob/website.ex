defmodule Smalt.DataPlane.Blob.Website do
  @moduledoc """
  Static-website face of the Blob data plane (capability wave 6, lane w6av):
  Azure Blob static website: Set/Get Blob Service Properties
  (?restype=service&comp=properties with a StaticWebsite block) + $web
  content serving. Storage is a per-account properties ETS (:heir 3-tuple
  owner init - shadow-table law).

  Extracted verbatim from Smalt.DataPlane.BlobStorage (T09 blob split, lane
  L09); the BlobStorage facade defdelegates this face's public functions, so
  wire behavior is unchanged and the existing blob courts gate byte parity.
  """

  alias Smalt.DataPlane.BlobService
  alias Smalt.DataPlane.BlobStorage

  # ---------------------------------------------------------------------------
  # Static website face (capability wave 6, lane w6av) - Azure Blob static
  # website: Set/Get Blob Service Properties (?restype=service&comp=properties
  # with a StaticWebsite block) + $web content serving. Storage is a
  # per-account properties ETS (:heir 3-tuple owner init - shadow-table law).
  # ---------------------------------------------------------------------------

  @sw_props_table :smalt_blob_service_props
  @sw_container "$web"

  @doc "The static-website content container (Azure parity: fixed name)."
  def static_website_container, do: @sw_container

  @doc "Ensure the per-account service-properties table exists (:heir 3-tuple)."
  def ensure_service_props_table do
    if :ets.info(@sw_props_table) == :undefined do
      :ets.new(@sw_props_table, [
        :set,
        :named_table,
        :public,
        {:heir, Process.whereis(:init), []},
        read_concurrency: true
      ])
    end

    :ok
  end

  @doc """
  Set Blob Service Properties (w6av): parse the request XML and store the
  StaticWebsite block per account. Returns :ok or
  {:error, 400, "InvalidXmlDocument", msg}. A valid body WITHOUT a
  StaticWebsite block disables the website (Azure parity: PUT clears what
  it omits).
  """
  def set_service_properties(account, xml_body) when is_binary(xml_body) do
    ensure_service_props_table()

    website =
      case Regex.run(~r/<StaticWebsite>(.*?)<\/StaticWebsite>/s, xml_body) do
        [_, block] ->
          enabled? = BlobStorage.xml_text(block, "Enabled") in ["true", "1"]
          index = BlobStorage.xml_text(block, "IndexDocument")
          err404 = BlobStorage.xml_text(block, "ErrorDocument404Path")

          cond do
            enabled? and is_binary(index) and index != "" ->
              %{"enabled" => true, "index_document" => index, "error_document404" => err404}

            enabled? ->
              {:error, 400, "InvalidXmlDocument",
               "StaticWebsite Enabled=true requires IndexDocument."}

            true ->
              %{"enabled" => false}
          end

        _ ->
          %{"enabled" => false}
      end

    case website do
      {:error, _s, _c, _m} = err ->
        err

      website when is_map(website) ->
        :ets.insert(@sw_props_table, {account, website})

        # Azure parity: enabling the static website auto-creates the $web
        # container (special-cased out of the name rules above).
        if website["enabled"] do
          BlobStorage.create_container(account, @sw_container)
        end

        :ok
    end
  end

  @doc "Stored StaticWebsite props for account, or nil (unset)."
  def website_props(account) do
    ensure_service_props_table()

    case :ets.lookup(@sw_props_table, account) do
      [{^account, props}] -> props
      [] -> nil
    end
  end

  @doc """
  Get Blob Service Properties XML: StorageServiceProperties with the stored
  StaticWebsite block (element omitted when unset - real Azure omits the
  block when the website was never enabled).
  """
  def service_properties_xml(account) do
    ensure_service_props_table()
    website = website_props(account)

    website_block =
      case website do
        %{"enabled" => true} = w ->
          [
            "<StaticWebsite><Enabled>true</Enabled>",
            "<IndexDocument>",
            BlobService.xml_escape(w["index_document"]),
            "</IndexDocument>",
            "<ErrorDocument404Path>",
            BlobService.xml_escape(w["error_document404"]),
            "</ErrorDocument404Path>",
            "</StaticWebsite>"
          ]

        _ ->
          []
      end

    IO.iodata_to_binary([
      "<?xml version=\"1.0\" encoding=\"utf-8\"?>",
      "<StorageServiceProperties>",
      website_block,
      cors_xml(account),
      "</StorageServiceProperties>"
    ])
  end

  # BK-132 (corpus triage): Get Blob Service Properties now echoes the stored
  # <Cors> rules (az `storage cors list` reads them here). Previously the PUT
  # stored rules (BlobCors.put_rules) but the GET omitted the block — a lying
  # empty read-back.
  defp cors_xml(account) do
    cors = Smalt.DataPlane.BlobCors.rules(account)

    case cors do
      [] ->
        []

      rules ->
        [
          "<Cors>",
          Enum.map(rules, fn r ->
            [
              "<CorsRule>",
              Enum.map(
                [
                  {"AllowedOrigins", r.allowed_origins},
                  {"AllowedMethods", r.allowed_methods},
                  {"AllowedHeaders", r.allowed_headers},
                  {"ExposedHeaders", r.exposed_headers},
                  {"MaxAgeInSeconds", r.max_age}
                ],
                fn {tag, val} ->
                  [ "<", tag, ">",
                    Enum.join(List.wrap(val), ","),
                    "</", tag, ">"
                  ]
                end
              ),
              "</CorsRule>"
            ]
          end),
          "</Cors>"
        ]
    end
  end

  @doc """
  Serve-decision for the static website face (w6av): :pass (website off /
  container not the web container / query present - normal blob handling),
  {:serve, blob, content_type}, {:serve_404, blob}, or {:plain_404, msg}.
  """
  def static_website_serve(account, container, blob, query_params) do
    ensure_service_props_table()
    container = container || ""
    blob = blob || ""

    props = website_props(account)
    web_container = static_website_container()

    cond do
      props == nil -> :pass
      match?(%{"enabled" => false}, props) -> :pass
      container != web_container -> :pass
      blob == "" and query_params == %{} -> serve_index(account)
      blob == "" -> :pass
      true -> serve_doc(account, blob)
    end
  end

  # Serve the configured index document at the $web container root.
  defp serve_index(account) do
    props = website_props(account)

    case BlobStorage.get_blob(account, @sw_container, props["index_document"]) do
      {:ok, blob} -> {:serve, blob, sniff_content_type(props["index_document"])}
      :error -> serve_404_doc(account)
    end
  end

  # Serve a content doc with content-type sniffed by extension.
  defp serve_doc(account, blob_name) do
    case BlobStorage.get_blob(account, @sw_container, blob_name) do
      {:ok, blob} -> {:serve, blob, sniff_content_type(blob_name)}
      :error -> serve_404_doc(account)
    end
  end

  # Serve the configured ErrorDocument404Path doc with 404 status, or a plain
  # 404 face when no error doc is configured.
  defp serve_404_doc(account) do
    props = website_props(account)

    case props["error_document404"] do
      path when is_binary(path) and path != "" ->
        case BlobStorage.get_blob(account, @sw_container, path) do
          {:ok, blob} -> {:serve_404, blob}
          _ -> {:plain_404, "The requested content does not exist."}
        end

      _ ->
        {:plain_404, "The requested content does not exist."}
    end
  end

  # Content-type by extension (static-website serving class).
  defp sniff_content_type(name) when is_binary(name) do
    ext = name |> Path.extname() |> String.downcase()

    %{
      ".html" => "text/html",
      ".htm" => "text/html",
      ".css" => "text/css",
      ".js" => "text/javascript",
      ".png" => "image/png",
      ".jpg" => "image/jpeg",
      ".jpeg" => "image/jpeg",
      ".svg" => "image/svg+xml",
      ".json" => "application/json",
      ".txt" => "text/plain"
    }
    |> Map.get(ext, "application/octet-stream")
  end
end
