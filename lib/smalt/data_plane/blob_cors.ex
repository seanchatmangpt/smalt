defmodule Smalt.DataPlane.BlobCors do
  @moduledoc """
  Azure Blob service CORS rules (capability wave 6, lane w6ay) — Set/Get Blob
  Service Properties `<Cors>` block + OPTIONS preflight evaluation.

  Parity: max 5 rules/service (rule 6+ -> 400 InvalidInput); AllowedMethods
  tokens must be a subset of GET,PUT,HEAD,POST,DELETE,MERGE,OPTIONS,PATCH
  (bad token -> 400 InvalidXmlDocument); OPTIONS preflight matched on Origin
  (+ wildcard `*`) and Access-Control-Request-Method (+ wildcard method `*`)
  -> 200 with Access-Control-* headers, else 403; matching actual requests
  get Access-Control-Expose-Headers echoed.
  """

  @table :smalt_blob_cors
  @valid_methods ~w(GET PUT HEAD POST DELETE MERGE OPTIONS PATCH)

  @doc "Ensure the CORS rules table exists (`:heir` 3-tuple — shadow-table law)."
  def ensure_table do
    if :ets.info(@table) == :undefined do
      :ets.new(@table, [
        :set,
        :named_table,
        :public,
        {:heir, Process.whereis(:init), []},
        read_concurrency: true
      ])
    end

    :ok
  end

  @doc "Store validated rules for `account` (maps from parse_cors_xml/1)."
  def put_rules(account, rules) when is_list(rules) do
    ensure_table()

    if length(rules) > 5 do
      {:error, 400, "InvalidInput", "TooManyCorsRules — max 5 per service"}
    else
      case validate_rules(rules) do
        :ok -> :ets.insert(@table, {account, rules}) && :ok
        err -> err
      end
    end
  end

  @doc "Stored CORS rules for `account` (empty list when unset)."
  def rules(account) do
    ensure_table()

    case :ets.lookup(@table, account) do
      [{^account, rules}] -> rules
      [] -> []
    end
  end

  @doc "OPTIONS preflight: {:ok, headers_map} | :forbidden."
  def preflight(account, origin, method) do
    case Enum.find(rules(account), fn r ->
           origin_match?(r, origin) and method_match?(r, method)
         end) do
      nil ->
        :forbidden

      rule ->
        {:ok,
         %{
           "Access-Control-Allow-Origin" => origin,
           "Access-Control-Allow-Methods" => Enum.join(rule.allowed_methods, ","),
           "Access-Control-Allow-Headers" => Enum.join(rule.allowed_headers, ","),
           "Access-Control-Max-Age" => Integer.to_string(rule.max_age),
           "Access-Control-Expose-Headers" => Enum.join(rule.exposed_headers, ",")
         }}
    end
  end

  @doc "Access-Control-Expose-Headers value for `origin`, or nil when no rule admits it."
  def expose_headers(account, origin) do
    case Enum.find(rules(account), &origin_match?(&1, origin)) do
      nil -> nil
      rule -> Enum.join(rule.exposed_headers, ",")
    end
  end

  @doc """
  Parse the `<Cors>` block from Set Blob Service Properties XML -> rule maps.
  Absent block -> [] (parity: PUT without Cors clears rules).
  Malformed -> {:error, 400, "InvalidXmlDocument", msg}.
  """
  def parse_cors_xml(xml_body) when is_binary(xml_body) do
    case Regex.run(~r/<Cors>(.*?)<\/Cors>/s, xml_body) do
      nil ->
        []

      [_, block] ->
        Regex.scan(~r/<CorsRule>(.*?)<\/CorsRule>/s, block)
        |> Enum.map(fn [_, r] ->
          %{
            allowed_origins: xml_list(r, "AllowedOrigins"),
            allowed_methods: xml_list(r, "AllowedMethods") |> Enum.map(&String.upcase/1),
            allowed_headers: xml_list(r, "AllowedHeaders"),
            exposed_headers: xml_list(r, "ExposedHeaders"),
            max_age: xml_int(r, "MaxAgeInSeconds") || 0
          }
        end)
    end
  end

  defp origin_match?(rule, origin) do
    "*" in rule.allowed_origins or origin in rule.allowed_origins
  end

  defp method_match?(rule, method) do
    "*" in rule.allowed_methods or
      String.upcase(method) in rule.allowed_methods
  end

  defp xml_list(r, tag) do
    case Regex.run(~r/<#{tag}>(.*?)<\/#{tag}>/s, r) do
      [_, v] ->
        v |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

      nil ->
        []
    end
  end

  defp xml_int(r, tag) do
    case Regex.run(~r/<#{tag}>(.*?)<\/#{tag}>/s, r) do
      [_, v] ->
        case Integer.parse(v) do
          {n, _} -> n
          :error -> nil
        end

      nil ->
        nil
    end
  end

  defp validate_rules(rules) do
    bad =
      rules
      |> Enum.flat_map(& &1.allowed_methods)
      |> Enum.reject(&(&1 in @valid_methods))

    if bad == [] do
      :ok
    else
      {:error, 400, "InvalidXmlDocument", "bad method tokens: #{inspect(bad)}"}
    end
  end
end
