defmodule Smalt.DataPlane.Apim do
  @moduledoc """
  `Microsoft.ApiManagement` resource model + real-dialect policy XML parsing
  (ticket T-07, receipt r16).

  ARM resource CRUD over the standard `:smalt_resources` table (downcased
  resource-id keys, same convention as every other provider family in
  `Smalt.ArmGateway.Router`):

  - `Microsoft.ApiManagement/service`
  - `Microsoft.ApiManagement/service/apis`
  - `Microsoft.ApiManagement/service/apis/operations`
  - `Microsoft.ApiManagement/service/{,apis/{,apis/operations/}}policies`

  Every mutator returns `{:ok, 200 | 201, record} | {:error, status, code,
  message}` so the ARM router route handlers (wired by the integrator — see
  `docs/jira/v26.10.28/receipts/r16-t07-apim.md`) are single-case matches.

  Policy documents are stored exactly as PUT (`properties.format = "xml"`,
  `properties.value` = raw XML) and parsed on the wire path by
  `parse_policy/1`, which understands the real APIM inbound subset the
  gateway executes:

      <policies>
        <inbound>
          <base/>
          <rate-limit calls="5" renewal-period="60" retry-after="1"/>
          <set-header name="X-Smalt" exists-action="overwrite">wired</set-header>
          <validate-jwt header-name="Authorization"
                        failed-validation-httpcode="401"
                        failed-validation-error-message="...">
            <required-claims>
              <claim name="role" match="any">
                <value>reader</value>
              </claim>
            </required-claims>
          </validate-jwt>
        </inbound>
        <backend>
          <forward-request timeout="30"/>
        </backend>
      </policies>

  Parsing rides SweetXml (vendored transitive dep, promoted to a direct dep
  at integration — see the receipt). Malformed XML (xmerl fatal), a
  non-`<policies>` root, an unsupported inbound policy element, or a missing
  / non-integer required attribute all return the typed refusal

      {:error, 400, "InvalidPolicyXml", message}

  — the same face real APIM gives a bad policy PUT — never a crash.

  Non-goals (ticket): full APIM expression language; outbound/on-error
  sections (parsed tolerantly and skipped, never executed).
  """

  alias Smalt.Store
  import SweetXml

  @provider "Microsoft.ApiManagement"
  @service_type "Microsoft.ApiManagement/service"
  @api_type "Microsoft.ApiManagement/service/apis"
  @operation_type "Microsoft.ApiManagement/service/apis/operations"
  @service_policy_type "Microsoft.ApiManagement/service/policies"
  @api_policy_type "Microsoft.ApiManagement/service/apis/policies"
  @operation_policy_type "Microsoft.ApiManagement/service/apis/operations/policies"

  # The only inbound policy elements the gateway executes (plus the
  # `<base/>` no-op). Anything else in <inbound> is a typed 400 — real APIM
  # refuses unknown policy elements at PUT time as well.
  @supported_inbound ["base", "rate-limit", "set-header", "validate-jwt"]

  @exists_actions ~w(append overwrite skip delete)

  # ---------------------------------------------------------------------------
  # ARM resource ids + Store keys (downcased — house router convention)
  # ---------------------------------------------------------------------------

  def service_id(sub, rg, svc),
    do: "/subscriptions/#{sub}/resourceGroups/#{rg}/providers/#{@provider}/service/#{svc}"

  def api_id(sub, rg, svc, api),
    do: service_id(sub, rg, svc) <> "/apis/#{api}"

  def operation_id(sub, rg, svc, api, op),
    do: api_id(sub, rg, svc, api) <> "/operations/#{op}"

  def policy_id(sub, rg, svc, scope, api_name, op_name, name)
  def policy_id(sub, rg, svc, :service, _api, _op, name),
    do: service_id(sub, rg, svc) <> "/policies/#{name}"
  def policy_id(sub, rg, svc, :api, api, _op, name),
    do: api_id(sub, rg, svc, api) <> "/policies/#{name}"
  def policy_id(sub, rg, svc, :operation, api, op, name),
    do: operation_id(sub, rg, svc, api, op) <> "/policies/#{name}"

  defp store_key(id), do: String.downcase(id)

  # ---------------------------------------------------------------------------
  # service
  # ---------------------------------------------------------------------------

  def put_service(sub, rg, svc, body) when is_map(body) do
    id = service_id(sub, rg, svc)
    existed? = match?({:ok, _}, Store.get(:smalt_resources, store_key(id)))

    props = Map.get(body, "properties") || %{}

    properties =
      Map.merge(
        %{
          "provisioningState" => "Succeeded",
          "publisherEmail" => "admin@smalt.local",
          "publisherName" => "smalt",
          "gatewayUrl" => "https://#{svc}.azure-api.net",
          "hostnameConfiguration" => nil
        },
        props
      )

    record = %{
      "id" => id,
      "name" => svc,
      "type" => @service_type,
      "location" => Map.get(body, "location") || "eastus",
      "tags" => Map.get(body, "tags") || %{},
      "sku" => Map.get(body, "sku") || %{"name" => "Developer", "capacity" => 1},
      "properties" => properties
    }

    Store.put(:smalt_resources, store_key(id), record)
    {:ok, if(existed?, do: 200, else: 201), record}
  end

  def get_service(sub, rg, svc) do
    get_by_key(store_key(service_id(sub, rg, svc)), @service_type, svc)
  end

  def delete_service(sub, rg, svc) do
    # Real APIM DELETE removes the whole instance: cascade the child tree so
    # a recreated service never resurrects stale apis/operations/policies.
    key = store_key(service_id(sub, rg, svc))

    with {:ok, _record} <- Store.get(:smalt_resources, key) do
      keys =
        Store.prefix_keys(:smalt_resources, key <> "/")
        |> Enum.concat([key])

      Enum.each(keys, &Store.delete(:smalt_resources, &1))

      {:ok, 200, %{}}
    else
      :error ->
        {:error, 404, "ResourceNotFound",
         "The service '#{svc}' could not be found under resource group '#{rg}'."}
    end
  end

  def list_services(sub, rg) do
    prefix = store_key(service_id(sub, rg, ""))

    Store.list_prefix(:smalt_resources, prefix)
    |> Enum.filter(&(&1["type"] == @service_type))
  end

  # ---------------------------------------------------------------------------
  # apis
  # ---------------------------------------------------------------------------

  def put_api(sub, rg, svc, api, body) when is_map(body) do
    with {:ok, _svc_record} <- get_service(sub, rg, svc) do
      id = api_id(sub, rg, svc, api)
      existed? = match?({:ok, _}, Store.get(:smalt_resources, store_key(id)))

      props = Map.get(body, "properties") || %{}

      properties =
        Map.merge(
          %{
            "displayName" => Map.get(props, "displayName") || api,
            "path" => Map.get(props, "path") || api,
            "protocols" => ["https"]
          },
          Map.drop(props, ["displayName", "path", "protocols"])
        )

      record = %{
        "id" => id,
        "name" => api,
        "type" => @api_type,
        "properties" => properties
      }

      Store.put(:smalt_resources, store_key(id), record)
      {:ok, if(existed?, do: 200, else: 201), record}
    else
      {:error, _status, _code, _msg} = refusal -> refusal
      :error -> service_missing(sub, rg, svc)
    end
  end

  def get_api(sub, rg, svc, api) do
    get_by_key(store_key(api_id(sub, rg, svc, api)), @api_type, api)
  end

  def delete_api(sub, rg, svc, api) do
    key = store_key(api_id(sub, rg, svc, api))

    with {:ok, _record} <- Store.get(:smalt_resources, key) do
      keys = Store.prefix_keys(:smalt_resources, key <> "/") |> Enum.concat([key])
      Enum.each(keys, &Store.delete(:smalt_resources, &1))
      {:ok, 200, %{}}
    else
      :error ->
        {:error, 404, "ResourceNotFound", "The api '#{api}' could not be found."}
    end
  end

  def list_apis(sub, rg, svc) do
    prefix = store_key(api_id(sub, rg, svc, ""))

    Store.list_prefix(:smalt_resources, prefix)
    |> Enum.filter(&(&1["type"] == @api_type))
  end

  # ---------------------------------------------------------------------------
  # operations
  # ---------------------------------------------------------------------------

  def put_operation(sub, rg, svc, api, op, body) when is_map(body) do
    with {:ok, _api_record} <- get_api(sub, rg, svc, api) do
      id = operation_id(sub, rg, svc, api, op)
      existed? = match?({:ok, _}, Store.get(:smalt_resources, store_key(id)))

      props = Map.get(body, "properties") || %{}
      template = Map.get(props, "urlTemplate") || "/"

      properties =
        Map.merge(
          %{
            "displayName" => Map.get(props, "displayName") || op,
            "method" => Map.get(props, "method") || "GET",
            "urlTemplate" => template,
            "templateParameters" => template_parameters(template)
          },
          Map.drop(props, ["displayName", "method", "urlTemplate", "templateParameters"])
        )

      record = %{
        "id" => id,
        "name" => op,
        "type" => @operation_type,
        "properties" => properties
      }

      Store.put(:smalt_resources, store_key(id), record)
      {:ok, if(existed?, do: 200, else: 201), record}
    else
      {:error, _status, _code, _msg} = refusal -> refusal
      :error -> api_missing(sub, rg, svc, api)
    end
  end

  def get_operation(sub, rg, svc, api, op) do
    get_by_key(store_key(operation_id(sub, rg, svc, api, op)), @operation_type, op)
  end

  def delete_operation(sub, rg, svc, api, op) do
    key = store_key(operation_id(sub, rg, svc, api, op))

    with {:ok, _record} <- Store.get(:smalt_resources, key) do
      keys = Store.prefix_keys(:smalt_resources, key <> "/") |> Enum.concat([key])
      Enum.each(keys, &Store.delete(:smalt_resources, &1))
      {:ok, 200, %{}}
    else
      :error ->
        {:error, 404, "ResourceNotFound", "The operation '#{op}' could not be found."}
    end
  end

  def list_operations(sub, rg, svc, api) do
    prefix = store_key(operation_id(sub, rg, svc, api, ""))

    Store.list_prefix(:smalt_resources, prefix)
    |> Enum.filter(&(&1["type"] == @operation_type))
  end

  # ---------------------------------------------------------------------------
  # policies (real-dialect policy XML; malformed -> typed 400 InvalidPolicyXml)
  # ---------------------------------------------------------------------------

  @doc """
  PUTs a policy document at the named scope. `xml` is parsed EAGERLY here —
  malformed XML refuses the PUT with the typed 400 before anything is
  stored (the real service's InvalidPolicyXml face).
  """
  def put_policy(sub, rg, svc, scope, api_name, op_name, name, xml)
      when is_binary(xml) and scope in [:service, :api, :operation] do
    with {:ok, _parsed} <- parse_policy(xml) do
      case scope_target(sub, rg, svc, scope, api_name, op_name) do
        {:ok, _target} ->
          id = policy_id(sub, rg, svc, scope, api_name, op_name, name)
          type = policy_type(scope)
          existed? = match?({:ok, _}, Store.get(:smalt_resources, store_key(id)))

          # Wire record stays ARM-exact (properties.format/value only). The
          # parsed form is recomputed from properties.value on the gateway
          # request path — a single source of truth in the Store, no derived
          # state to invalidate.
          record = %{
            "id" => id,
            "name" => name,
            "type" => type,
            "properties" => %{"format" => "xml", "value" => xml}
          }

          Store.put(:smalt_resources, store_key(id), record)
          {:ok, if(existed?, do: 200, else: 201), record}

        {:error, _status, _code, _msg} = refusal ->
          refusal
      end
    end
  end

  def get_policy(sub, rg, svc, scope, api_name, op_name, name) when scope in [:service, :api, :operation] do
    get_by_key(store_key(policy_id(sub, rg, svc, scope, api_name, op_name, name)), policy_type(scope), name)
  end

  def delete_policy(sub, rg, svc, scope, api_name, op_name, name) when scope in [:service, :api, :operation] do
    key = store_key(policy_id(sub, rg, svc, scope, api_name, op_name, name))

    with {:ok, _record} <- Store.get(:smalt_resources, key) do
      Store.delete(:smalt_resources, key)
      {:ok, 200, %{}}
    else
      :error ->
        {:error, 404, "ResourceNotFound", "The policy '#{name}' could not be found."}
    end
  end

  def list_policies(sub, rg, svc, scope, api_name, op_name) when scope in [:service, :api, :operation] do
    prefix = store_key(policy_id(sub, rg, svc, scope, api_name, op_name, ""))

    Store.list_prefix(:smalt_resources, prefix)
    |> Enum.filter(&(&1["type"] == policy_type(scope)))
  end

  defp policy_type(:service), do: @service_policy_type
  defp policy_type(:api), do: @api_policy_type
  defp policy_type(:operation), do: @operation_policy_type

  defp scope_target(sub, rg, svc, :service, _api, _op), do: get_service(sub, rg, svc)
  defp scope_target(sub, rg, svc, :api, api, _op), do: get_api(sub, rg, svc, api)

  defp scope_target(sub, rg, svc, :operation, api, op),
    do: get_operation(sub, rg, svc, api, op)

  # ---------------------------------------------------------------------------
  # policy XML parsing (SweetXml / xmerl — malformed -> typed InvalidPolicyXml)
  # ---------------------------------------------------------------------------

  @doc """
  Parses a real-dialect APIM policy document.

  Returns `{:ok, parsed}` where

      parsed = %{
        "inbound" => [policy_map, ...],        # document order, :base skipped
        "backend" => %{"forward-request" => boolean, "timeout" => seconds | nil}
      }

  or `{:error, 400, "InvalidPolicyXml", message}` on: empty document,
  xmerl parse fatals (malformed XML), non-`<policies>` root, unsupported
  inbound policy elements, missing attributes, or non-integer `calls` /
  `renewal-period` / `retry-after` / `failed-validation-httpcode`.
  """
  def parse_policy(xml) when is_binary(xml) do
    case String.trim(xml) do
      "" ->
        invalid_policy("policy document is empty")

      trimmed ->
        parse_policy_doc(trimmed)
    end
  end

  defp parse_policy_doc(trimmed) do
    doc = SweetXml.parse(trimmed, dtd: :none, quiet: true)

    case String.downcase(SweetXml.xpath(doc, ~x"name()"s)) do
      "policies" ->
        with {:ok, inbound} <- parse_inbound(doc),
             {:ok, backend} <- parse_backend(doc) do
          {:ok, %{"inbound" => inbound, "backend" => backend}}
        end

      other ->
        invalid_policy(
          "policy document must be rooted at <policies>, got <#{other}>"
        )
    end
  rescue
    e in SweetXml.XmerlFatal ->
      invalid_policy("policy XML is not well-formed: #{e.message}")

    e ->
      invalid_policy("policy XML is not well-formed: #{Exception.message(e)}")
  catch
    kind, reason ->
      invalid_policy("policy XML is not well-formed: #{kind} #{inspect(reason)}")
  end

  # Document order matters (rate-limit before validate-jwt changes which
  # refusal a combined policy serves), so the children are enumerated with
  # `./*` and classified one by one.
  defp parse_inbound(doc) do
    case SweetXml.xpath(doc, ~x"./inbound"o) do
      nil ->
        {:ok, []}

      inbound ->
        SweetXml.xpath(inbound, ~x"./*"l)
        |> Enum.reduce_while({:ok, []}, fn el, {:ok, acc} ->
          case parse_inbound_policy(el) do
            {:ok, nil} -> {:cont, {:ok, acc}}
            {:ok, policy} -> {:cont, {:ok, acc ++ [policy]}}
            {:error, _, _, _} = refusal -> {:halt, refusal}
          end
        end)
    end
  end

  defp parse_inbound_policy(el) do
    name = String.downcase(SweetXml.xpath(el, ~x"name()"s))

    case name do
      "base" ->
        # Real APIM inheritance marker: at these scopes there is no parent
        # policy document, so <base/> is a tolerated no-op.
        {:ok, nil}

      "rate-limit" ->
        with {:ok, calls} <- required_int_attr(el, name, "calls"),
             {:ok, window} <- required_int_attr(el, name, "renewal-period"),
             {:ok, retry_after} <- optional_int_attr(el, name, "retry-after") do
          {:ok,
           %{
             "type" => "rate-limit",
             "calls" => calls,
             "renewal-period" => window,
             "retry-after" => retry_after
           }}
        end

      "set-header" ->
        with {:ok, header} <- required_string_attr(el, name, "name"),
             {:ok, action} <- exists_action(el, name),
             {:ok, value} <- {:ok, text_content(el)} do
          {:ok,
           %{
             "type" => "set-header",
             "name" => header,
             "exists-action" => action,
             "value" => value
           }}
        end

      "validate-jwt" ->
        with {:ok, httpcode} <- optional_int_attr(el, name, "failed-validation-httpcode"),
             {:ok, claims} <- parse_required_claims(el, name) do
          {:ok,
           %{
             "type" => "validate-jwt",
             "header-name" =>
               optional_string_attr(el, "header-name") || "authorization",
             "failed-validation-httpcode" => httpcode,
             "failed-validation-error-message" =>
               optional_string_attr(el, "failed-validation-error-message"),
             "issuer" => optional_string_attr(el, "issuer"),
             "required-claims" => claims
           }}
        end

      other ->
        invalid_policy(
          "unsupported inbound policy element <#{other}> (supported: #{Enum.join(@supported_inbound, ", ")})"
        )
    end
  end

  defp parse_required_claims(el, policy_name) do
    SweetXml.xpath(el, ~x"./required-claims/claim"l)
    |> Enum.reduce_while({:ok, []}, fn claim_el, {:ok, acc} ->
      name = optional_string_attr(claim_el, "name")
      match = optional_string_attr(claim_el, "match") || "all"

      cond do
        is_nil(name) or name == "" ->
          {:halt,
           invalid_policy(
             "<claim> under <#{policy_name}> requires a 'name' attribute"
           )}

        match not in ~w(all any) ->
          {:halt,
           invalid_policy(
             "<claim name=\"#{name}\"> match must be \"all\" or \"any\", got \"#{match}\""
           )}

        true ->
          values =
            SweetXml.xpath(claim_el, ~x"./value/text()"l)
            |> Enum.map(&to_string/1)

          {:cont, {:ok, acc ++ [%{"name" => name, "match" => match, "values" => values}]}}
      end
    end)
  end

  defp parse_backend(doc) do
    case SweetXml.xpath(doc, ~x"./backend"o) do
      nil ->
        {:ok, nil}

      backend ->
        timeout =
          case SweetXml.xpath(backend, ~x"./forward-request/@timeout"so) do
            nil ->
              nil

            raw ->
              case Integer.parse(String.trim(to_string(raw))) do
                {n, ""} when n > 0 -> n
                _ -> nil
              end
          end

        forward? = match?({_elem, _}, SweetXml.xpath(backend, ~x"./forward-request"o))

        {:ok, %{"forward-request" => forward?, "timeout" => timeout}}
      end
  end

  # -- attribute / text helpers ------------------------------------------------

  defp required_int_attr(el, policy_name, attr) do
    case optional_int_attr(el, attr) do
      {:ok, nil} ->
        invalid_policy("<#{policy_name}> requires attribute '#{attr}'")

      {:ok, _int} = ok ->
        ok

      {:error, _, _, _} = refusal ->
        refusal
    end
  end

  defp optional_int_attr(el, attr) do
    case SweetXml.xpath(el, ~x"./@#{attr}"so) do
      nil ->
        {:ok, nil}

      raw ->
        case Integer.parse(String.trim(to_string(raw))) do
          {n, ""} when n > 0 ->
            {:ok, n}

          _ ->
            invalid_policy("attribute '#{attr}' must be a positive integer, got \"#{raw}\"")
        end
    end
  end

  defp required_string_attr(el, policy_name, attr) do
    case optional_string_attr(el, attr) do
      nil -> invalid_policy("<#{policy_name}> requires attribute '#{attr}'")
      "" -> invalid_policy("<#{policy_name}> attribute '#{attr}' must not be empty")
      value -> {:ok, value}
    end
  end

  defp optional_string_attr(el, attr) do
    case SweetXml.xpath(el, ~x"./@#{attr}"so) do
      nil -> nil
      raw -> to_string(raw)
    end
  end

  defp exists_action(el, policy_name) do
    case optional_string_attr(el, "exists-action") do
      nil ->
        {:ok, "overwrite"}

      action ->
        if action in @exists_actions do
          {:ok, action}
        else
          invalid_policy(
            "<#{policy_name}> exists-action must be one of #{Enum.join(@exists_actions, ", ")}, got \"#{action}\""
          )
        end
    end
  end

  # All contiguous text children joined — xmerl already decoded XML entities
  # (&lt; &amp; ...) before this runs, so the value is the real header value.
  defp text_content(el) do
    SweetXml.xpath(el, ~x"./text()"l)
    |> Enum.map(&to_string/1)
    |> Enum.join("")
    |> String.trim()
  end

  defp invalid_policy(msg), do: {:error, 400, "InvalidPolicyXml", msg}

  # ---------------------------------------------------------------------------
  # gateway lookup helpers (resource-model side of the execution plane)
  # ---------------------------------------------------------------------------

  @doc """
  Resolves the api referenced by a gateway path segment: by resource NAME
  first (`.../apis/{segment}`), then by its `properties.path` gateway alias
  (real APIM addresses an API by its configured path on the gateway URL).
  """
  def find_api(sub, rg, svc, segment) do
    case get_api(sub, rg, svc, segment) do
      {:ok, record} ->
        {:ok, record}

      _ ->
        prefix = store_key(api_id(sub, rg, svc, ""))

        apis = Store.list_prefix(:smalt_resources, prefix)
        seg = String.downcase(segment)

        Enum.find(apis, fn api ->
          path = api["properties"]["path"]
          is_binary(path) and String.downcase(path) == seg
        end)
        |> case do
          nil -> {:error, 404, "ResourceNotFound", "The api '#{segment}' could not be found."}
          record -> {:ok, record}
        end
    end
  end

  @doc """
  Picks the operation whose `method` + `urlTemplate` match `segments` (the
  path segments after the api segment). `{param}` matches one segment;
  `{*param}` / `{**param}` / a literal `*` tail absorb the remainder (and
  match empty). First match in Store listing order wins.
  """
  def find_operation(sub, rg, svc, api, method, segments) do
    decoded = Enum.map(segments, &uri_decode_maybe/1)

    case match_operations(list_operations(sub, rg, svc, api), method, decoded) do
      nil ->
        {:error, 404, "ResourceNotFound",
         "No operation matches #{method} /#{Enum.join(segments, "/")} on api '#{api}'."}

      op ->
        {:ok, op}
    end
  end

  defp match_operations([], _method, _segments), do: nil

  defp match_operations(ops, method, segments) do
    Enum.find(ops, fn op ->
      props = op["properties"] || %{}

      String.downcase(props["method"] || "") == String.downcase(method) and
        template_matches?(props["urlTemplate"] || "/", segments)
    end)
  end

  defp template_matches?(template, segments) do
    parts =
      template
      |> String.split("/", trim: true)
      |> Enum.map(&String.trim/1)

    {literals, wildcards} = split_template(parts, [])
    literal_count = length(literals)

    cond do
      literals == [] and wildcards == [] ->
        segments == []

      wildcards == [] ->
        length(segments) == literal_count and
          Enum.zip(literals, segments) |> Enum.all?(fn {lit, seg} -> literal_matches?(lit, seg) end)

      true ->
        # Wildcard tail: every literal prefix must match, the tail absorbs the rest.
        prefix = Enum.take(segments, literal_count)

        Enum.length(segments) >= literal_count and
          Enum.zip(literals, prefix) |> Enum.all?(fn {lit, seg} -> literal_matches?(lit, seg) end)
    end
  end

  defp split_template([], literals), do: {Enum.reverse(literals), []}

  defp split_template([part | rest], literals) do
    if part == "*" or String.starts_with?(part, "{*") do
      {Enum.reverse(literals), [part]}
    else
      split_template(rest, [part | literals])
    end
  end

  defp literal_matches?(part, seg) do
    if String.starts_with?(part, "{") and String.ends_with?(part, "}") and byte_size(part) > 2 do
      true
    else
      String.downcase(part) == String.downcase(seg)
    end
  end

  # ---------------------------------------------------------------------------
  # shared helpers
  # ---------------------------------------------------------------------------

  defp get_by_key(key, type, name) do
    case Store.get(:smalt_resources, key) do
      {:ok, %{"type" => ^type} = record} ->
        {:ok, record}

      {:ok, _other_type} ->
        {:error, 404, "ResourceNotFound", "The resource '#{name}' could not be found."}

      :error ->
        {:error, 404, "ResourceNotFound", "The resource '#{name}' could not be found."}
    end
  end

  defp service_missing(sub, rg, svc),
    do:
      {:error, 404, "ResourceNotFound",
       "The parent #{service_id(sub, rg, svc)} could not be found."}

  defp api_missing(sub, rg, svc, api),
    do: {:error, 404, "ResourceNotFound", "The parent #{api_id(sub, rg, svc, api)} could not be found."}

  defp template_parameters(template) do
    Regex.scan(~r/\{([^}]+)\}/, template)
    |> Enum.map(fn [_, name] ->
      name = String.trim_leading(name, "*")
      %{"name" => name, "required" => true, "type" => "string"}
    end)
  end

  defp uri_decode_maybe(seg) when is_binary(seg) do
    if String.contains?(seg, "%") do
      URI.decode(seg)
    else
      seg
    end
  end
end
