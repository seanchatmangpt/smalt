defmodule Smalt.Egress.AppConfigRoutes do
  @moduledoc """
  w6R structural split of Smalt.EgressRouter (BEAM implementation limit,
  function '__MODULE__'/1+14): App Configuration (/kv, /snapshots) arm, verbatim relocation.
  Fallthrough router — unmatched conns pass through un-halted; the main
  router's blob splat + 404 catch-all handle everything else, unchanged.
  """
  use Plug.Router
  # public_secret_record/list_secret_record are local (they shadow the
  # EgressRouter originals), so they are excluded from the import.
  import Smalt.EgressRouter,
    except: [
      match: 2,
      match: 3,
      dispatch: 2,
      public_secret_record: 1,
      list_secret_record: 1,
      secret_params: 1,
      secret_expiry: 1,
      maybe_put_content_type: 2
    ]
  alias Smalt.Store
  alias Smalt.DataPlane.AppConfigSnapshots
  plug :match
  plug :dispatch



  get "/kv" do
    if :ets.info(:smalt_appconfig) == :undefined do
      route_not_ready(conn)
    else
      key_filter = conn.query_params["key"]
      label_filter = conn.query_params["label"]
      fields = kv_fields(conn.query_params["fields"])
      tags_filter = kv_tags_filter(conn.query_string)
      after_token = conn.query_params["after"]

      items =
        Store.list_all(:smalt_appconfig)
        |> Enum.filter(fn record ->
          kv_glob_match?(record["key"], key_filter) and
            kv_glob_match?(record["label"], label_filter) and
            kv_tags_match?(record, tags_filter)
        end)
        |> Enum.sort_by(&{&1["key"], &1["label"]})
        |> kv_page(after_token)

      {page_items, next_after} = items

      body = %{
        "items" => Enum.map(page_items, &public_kv_record(&1, fields))
      }

      conn
      |> kv_next_link(next_after)
      |> put_resp_header("sync-token", kv_sync_token(Store.list_all(:smalt_appconfig)))
      |> send_json(200, body)
    end
  end

  put "/kv/:key" do
    if :ets.info(:smalt_appconfig) == :undefined do
      route_not_ready(conn)
    else
      with_valid_body(conn, fn conn ->
        label = conn.query_params["label"] || ""
        existing = Store.get(:smalt_appconfig, {key, label})
        if_match = if_match_value(conn)
        if_none_match = if_none_match_value(conn)

        cond do
          # create-only: refuse overwrite of an existing kv with 412
          if_none_match == "*" and existing != :error ->
            send_json(conn, 412, %{
              "error" => %{
                "code" => "PreconditionFailed",
                "message" => "kv #{key} (label #{label}) already exists"
              }
            })

          # T24WIRE 2026-10-21: an exact If-None-Match on PUT is a real
          # precondition (RFC 7232) — @azure/app-configuration onlyIfChanged
          # sends If-None-Match: <etag>; a match must 412, not be ignored.
          if_none_match not in [nil, "*"] and existing != :error and
              if_none_match == elem(existing, 1)["etag"] ->
            send_json(conn, 412, %{
              "error" => %{
                "code" => "PreconditionFailed",
                "message" => "If-None-Match precondition failed for kv #{key} (label #{label})"
              }
            })

          # CAS / unconditional-overwrite rules
          kv_precondition(existing, if_match) == :stale ->
            send_json(conn, 412, %{
              "error" => %{
                "code" => "PreconditionFailed",
                "message" => "If-Match precondition failed for kv #{key} (label #{label})"
              }
            })

          existing != :error and is_nil(if_match) and is_nil(if_none_match) ->
            send_json(conn, 409, %{
              "error" => %{
                "code" => "WriteConflict",
                "message" =>
                  "kv #{key} (label #{label}) exists; supply If-Match to overwrite " <>
                    "or If-None-Match: * for create-only"
              }
            })

          true ->
            # KD-COVERS: KD-109 — feature-flag keys are typed, not opaque:
            # `.appconfig.featureflag/{name}` writes ride the typed flag
            # engine (AppConfigFeatures.put_flag/4); an invalid flag body is
            # a typed 400 InvalidFeatureFlag refusal, never a silent store.
            if String.starts_with?(key, ".appconfig.featureflag/") do
              name = String.replace_prefix(key, ".appconfig.featureflag/", "")
              tags = kv_tags_from_body(conn.body_params)

              case Smalt.DataPlane.AppConfigFeatures.put_flag(name, conn.body_params["value"], label, tags) do
                {:ok, record} ->
                  emit_kv_event(record)
                  # D6/KD-LITH-WIRE-3 2026-10-25: documented real-Azure contract —
                  # 201 on create, 200 on update.
                  send_json(conn, kv_put_status(existing), public_kv_record(record))

                {:error, {code, msg}} ->
                  send_json(conn, 400, %{"error" => %{"code" => code, "message" => msg}})
              end
            else
              {:ok, record} = kv_write(conn, key, label, existing)
              emit_kv_event(record)
              # D6/KD-LITH-WIRE-3 2026-10-25: 201 on create, 200 on update.
              send_json(conn, kv_put_status(existing), public_kv_record(record))
            end
        end
      end)
    end
  end

  get "/kv/:key" do
    if :ets.info(:smalt_appconfig) == :undefined do
      route_not_ready(conn)
    else
      label = conn.query_params["label"] || ""

      case Store.get(:smalt_appconfig, {key, label}) do
        {:ok, record} ->
          if if_none_match_value(conn) == record["etag"] do
            conn
            |> put_resp_header("etag", record["etag"])
            |> send_resp(304, "")
          else
            conn
            |> put_resp_header("etag", record["etag"])
            |> send_json(200, public_kv_record(record))
          end

        :error ->
          blob_error(conn, 404, not_found_error("KvNotFound"))
      end
    end
  end

  delete "/kv/:key" do
    if :ets.info(:smalt_appconfig) == :undefined do
      route_not_ready(conn)
    else
      label = conn.query_params["label"] || ""

      case Store.get(:smalt_appconfig, {key, label}) do
        :error ->
          blob_error(conn, 404, not_found_error("KvNotFound"))

        {:ok, record} ->
          if_match = if_match_value(conn)

          if is_nil(if_match) do
            # Real App Configuration: delete REQUIRES an If-Match (a missing
            # header is a 409, unlike PUT where absence imposes no
            # precondition and upsert is legal).
            blob_error(conn, 409, %{
              "code" => "MissingIfMatch",
              "message" => "If-Match header must be specified for the delete operation"
            })
          else
            if kv_precondition({:ok, record}, if_match) == :stale do
              send_json(conn, 412, %{
                "error" => %{
                  "code" => "PreconditionFailed",
                  "message" => "If-Match precondition failed for kv #{key} (label #{label})"
                }
              })
            else
              Store.delete(:smalt_appconfig, {key, label})
              send_resp(conn, 204, "")
            end
          end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Azure App Configuration snapshots (v26.10.19 capability wave-2, W2N
  # fragment on the KD-53 plane). AppConfigSnapshots owns the typed state
  # machine; this fragment is wire-only. ROUTE ORDER IS LOAD-BEARING: this
  # block sits BEFORE the blob catch-all family — `/snapshots/:name` is
  # shape-identical to the blob splat `/:account/:container`, and when the
  # blob family claimed the path the PY wf7 lane witnessed MissingXMsVersion
  # instead of the snapshot surface (v26.10.19 wave-2 dispatch note).
  # ---------------------------------------------------------------------------
  get "/snapshots" do
    if :ets.info(:smalt_appconfig) == :undefined do
      route_not_ready(conn)
    else
      send_json(conn, 200, %{"items" => AppConfigSnapshots.list()})
    end
  end

  put "/snapshots/:name" do
    if :ets.info(:smalt_appconfig) == :undefined do
      route_not_ready(conn)
    else
      with_valid_body(conn, fn conn ->
        live_records = Store.list_all(:smalt_appconfig)

        case AppConfigSnapshots.create(name, conn.body_params, live_records) do
          {:ok, record} -> send_json(conn, 201, record)
          {:error, reason} -> snapshots_error(conn, reason)
        end
      end)
    end
  end

  get "/snapshots/:name" do
    if :ets.info(:smalt_appconfig) == :undefined do
      route_not_ready(conn)
    else
      case AppConfigSnapshots.get(name) do
        {:ok, record} -> send_json(conn, 200, record)
        {:error, reason} -> snapshots_error(conn, reason)
      end
    end
  end

  get "/snapshots/:name/kv" do
    if :ets.info(:smalt_appconfig) == :undefined do
      route_not_ready(conn)
    else
      case AppConfigSnapshots.kv_view(name) do
        {:ok, items} -> send_json(conn, 200, %{"items" => items})
        {:error, reason} -> snapshots_error(conn, reason)
      end
    end
  end

  post "/snapshots/:name/archive" do
    if :ets.info(:smalt_appconfig) == :undefined do
      route_not_ready(conn)
    else
      case AppConfigSnapshots.archive(name) do
        {:ok, record} -> send_json(conn, 200, record)
        {:error, reason} -> snapshots_error(conn, reason)
      end
    end
  end

  delete "/snapshots/:name" do
    if :ets.info(:smalt_appconfig_snapshots) == :undefined and
         :ets.info(:smalt_appconfig) == :undefined do
      route_not_ready(conn)
    else
      case AppConfigSnapshots.purge(name) do
        :ok -> send_resp(conn, 204, "")
        {:error, reason} -> snapshots_error(conn, reason)
      end
    end
  end

  # Typed snapshot error mapping: validation -> 400, absence -> 404,
  # state-machine conflicts -> 409 (the module emits {code, message} tuples;
  # the HTTP mapping is egress-owned by design, per the module's @moduledoc).
  defp snapshots_error(conn, {code, message}) do
    status =
      case code do
        c when c in ["InvalidFilter", "InvalidComposition"] -> 400
        c when c in ["SnapshotNotFound"] -> 404
        _ -> 409
      end

    send_json(conn, status, %{"error" => %{"code" => code, "message" => message}})
  end

  def secret_subverb_refusal(conn, verb) do
    send_json(conn, 501, %{
      "error" => %{
        "code" => "NotImplemented",
        "message" =>
          "#{conn.method} #{conn.request_path} (#{verb}) is not implemented on " <>
            "the /secrets plane; nothing was stored."
      }
    })
  end

  # Accepts {value, attributes?} — attributes may carry enabled, expires|exp,
  # and contentType may ride top-level or inside attributes.
  def secret_params(%{"value" => value} = params) when is_binary(value) do
    attrs =
      params["attributes"]
      |> coerce_secret_attrs()
      |> Map.merge(Map.take(params, ["contentType"]))

    {:ok, value, attrs}
  end

  def secret_params(_), do: :error

  def coerce_secret_attrs(%{} = attrs), do: attrs
  def coerce_secret_attrs(_), do: %{}

  def secret_expiry(attrs_in) do
    case attrs_in["expires"] || attrs_in["exp"] do
      nil -> %{}
      exp -> %{"expires" => exp}
    end
  end

  def maybe_put_content_type(record, attrs_in) do
    case attrs_in["contentType"] do
      nil -> record
      ct -> Map.put(record, "contentType", ct)
    end
  end

  # List renders omit the secret value (Azure contract); GET keeps it.
  # KD-S3/KD-S4: internal version-history bookkeeping (versions index,
  # created_seq, is_version_row) never leaves the vault on the wire.
  def public_secret_record(record),
    do: Map.drop(record, ["version", "versions", "created_seq", "is_version_row"])

  def list_secret_record(record), do: record |> public_secret_record() |> Map.drop(["value"])

  # --- /kv (App Configuration) helpers ------------------- (KD-COVERS: KD-53)

  def if_match_value(conn) do
    case get_req_header(conn, "if-match") do
      [v | _] -> v
      [] -> nil
    end
  end

  def if_none_match_value(conn) do
    case get_req_header(conn, "if-none-match") do
      [v | _] -> v
      [] -> nil
    end
  end

  # :ok when the precondition permits the write, :stale when it fails.
  # `*` matches anything (including absent); an exact etag matches only that
  # etag; a missing header imposes no precondition.
  def kv_precondition(_existing, nil), do: :ok

  # If-Match: * asserts the resource EXISTS (RFC 7232); on an absent kv the
  # precondition fails (412), even on the create path.
  def kv_precondition(:error, "*"), do: :stale
  def kv_precondition({:ok, _}, "*"), do: :ok

  def kv_precondition({:ok, %{"etag" => etag}}, if_match) when is_binary(if_match) do
    if if_match == etag, do: :ok, else: :stale
  end

  def kv_precondition(:error, _if_match), do: :stale

  # PRD-APPCONF push face: every successful key-value write emits a typed
  # Event Grid envelope to AppConfigEvents subscribers (fail-safe: a broken
  # registry must never fail the write).
  defp emit_kv_event(record) do
    Smalt.DataPlane.AppConfigEvents.emit(record["key"], record["label"], record["etag"])
  catch
    _, _ -> :ok
  end

  defp kv_write(conn, key, label, _existing) do
    value = conn.body_params["value"]

    # D6 2026-10-25: request-body member is the documented `content_type`;
    # camelCase `contentType` remains accepted for lenient-input parity.
    content_type =
      conn.body_params["content_type"] || conn.body_params["contentType"]

    etag =
      :crypto.hash(:sha256, :erlang.term_to_binary({key, label, value, content_type}))
      |> Base.encode16()

    last_modified = System.system_time(:second)

    record = %{
      "key" => key,
      "label" => label,
      "value" => value,
      "contentType" => content_type,
      "tags" => kv_tags_from_body(conn.body_params),
      "locked" => false,
      "etag" => "\"" <> etag <> "\"",
      "last_modified" => last_modified
    }

    Store.put(:smalt_appconfig, {key, label}, record)
    {:ok, record}
  end

  # D6/KD-LITH-WIRE-3/4 2026-10-25: the wire envelope is the documented
  # real-Azure KV shape {key,label,content_type,etag,last_modified,value,tags}
  # (tapes 12/13- + lith-12/13-appconfig-kv). Internal record keys stay
  # camelCase ("contentType"); remap happens only at this envelope boundary.
  # `locked` is substrate-internal and never emitted on the plain kv face.
  @kv_wire_content_type "content_type"

  def public_kv_record(record) when is_map(record) do
    record
    |> Map.drop(["locked"])
    |> kv_wire_member("contentType", @kv_wire_content_type)
  end

  defp kv_wire_member(record, from, to) do
    case Map.fetch(record, from) do
      {:ok, v} -> record |> Map.delete(from) |> Map.put(to, v)
      :error -> record
    end
  end

  # D6 2026-10-25: documented real-Azure contract — 201 on first create,
  # 200 on update.
  defp kv_put_status(:error), do: 201
  defp kv_put_status({:ok, _}), do: 200

  # Body `tags` passthrough (w6l): must be a JSON object of string->string;
  # anything else is an empty map (parity: real service validates, emulator
  # keeps the write face lenient — the tags FILTER grammar is strict, the
  # stored payload is opaque).
  defp kv_tags_from_body(%{"tags" => tags}) when is_map(tags) do
    Map.new(tags, fn {k, v} -> {k, if(is_binary(v), do: v, else: Jason.encode!(v))} end)
  end

  defp kv_tags_from_body(_), do: %{}

  defp kv_sync_token(records) do
    max =
      records
      |> Enum.map(fn r -> r["last_modified"] || 0 end)
      |> Enum.max(fn -> 0 end)

    # T24WIRE 2026-10-21: official App Configuration sync-token wire contract is
    # `{id}={value};sn={seq}` (regex ^([^=]+)=([^;]+);sn=(\d+)$ — witnessed:
    # @azure/app-configuration@1.13.0 syncTokenPolicy hard-crashes on any other
    # shape). Bare "smalt-<ts>" is a divergence; emit the real shape.
    "smalt=#{max};sn=#{max}"
  end

  # Field selection (App Config `fields` query param, v26.10.20 w6l): a
  # comma-separated subset of the documented real-Azure wire vocabulary
  # {key,label,content_type,value,tags,last_modified,etag} (D6 2026-10-25:
  # content_type snake_case, no locked member on the plain kv face). The
  # allowed vocabulary is closed; unknown names are dropped (real service
  # ignores unknown field names).
  @kv_field_names ~w(key label content_type value tags last_modified etag)
  @kv_default_fields MapSet.new(@kv_field_names)

  defp kv_fields(nil), do: @kv_default_fields

  defp kv_fields(raw) when is_binary(raw) do
    selected =
      raw
      |> String.downcase()
      |> String.split(",", trim: true)
      |> MapSet.new(&String.trim/1)

    MapSet.new(
      for n <- @kv_field_names,
          MapSet.member?(selected, String.downcase(n)),
          do: n
    )
  end

  # Glob match: exact when no `*`, trailing-`*` prefix (or leading-`*`
  # suffix) match otherwise. A nil filter matches everything.
  defp kv_glob_match?(_value, nil), do: true
  defp kv_glob_match?(_value, "*"), do: true

  defp kv_glob_match?(value, pattern) when is_binary(value) and is_binary(pattern) do
    case String.split(pattern, "*", parts: 2) do
      [exact] -> value == exact
      [prefix, ""] -> String.starts_with?(value, prefix)
      [prefix, suffix] -> String.starts_with?(value, prefix) and String.ends_with?(value, suffix)
    end
  end

  defp kv_glob_match?(_non_binary, _pattern), do: false

  # Repeated `tags=k=v` query params (App Config tag-filter grammar, w6l):
  # AND semantics across pairs; a record matches when every demanded pair is
  # present-and-equal in its tags map. Parsed from the raw query string so
  # repeated params survive Plug's last-wins collapse.
  defp kv_tags_filter(query_string) do
    query_string
    |> Plug.Conn.Query.decode()
    |> Map.get("tags", [])
    |> List.wrap()
    |> Enum.map(fn pair ->
      case String.split(pair, "=", parts: 2) do
        [k, v] -> {k, v}
        [k] -> {k, ""}
      end
    end)
  end

  defp kv_tags_match?(_record, []), do: true

  defp kv_tags_match?(record, pairs) do
    tags = record["tags"] || %{}

    Enum.all?(pairs, fn {k, v} -> Map.get(tags, k) == v end)
  end

  # Deterministic paging (w6l): items sorted by {key, label}; `after` is the
  # opaque continuation token minted from the LAST item of the prior page
  # (base64url JSON {key,label}); the next page starts strictly after that
  # composite key. Page size 50 (real-service default).
  @kv_page_size 50

  defp kv_page(records, nil) do
    kv_mint_page(records, nil)
  end

  defp kv_page(records, after_token) when is_binary(after_token) do
    case kv_decode_after(after_token) do
      {:ok, {key, label}} ->
        rest = Enum.drop_while(records, fn r -> {r["key"], r["label"]} <= {key, label} end)
        kv_mint_page(rest, nil)

      :error ->
        # A forged/stale token never resurrects items (Azure parity).
        {[], nil}
    end
  end

  # Split into a page + remainder; when a remainder exists, mint the
  # continuation token from the page's LAST composite key.
  defp kv_mint_page(records, _none) do
    {page, remainder} = Enum.split(records, @kv_page_size)

    next =
      case remainder do
        [] -> nil
        _ -> {last_key, last_label} = List.last(page) |> kv_composite(); kv_encode_after(last_key, last_label)
      end

    {page, next}
  end

  defp kv_composite(%{"key" => k, "label" => l}), do: {k, l}

  defp kv_encode_after(key, label) do
    Jason.encode!(%{key: key, label: label})
    |> Base.url_encode64(padding: false)
  end

  defp kv_decode_after(token) do
    case Base.url_decode64(token, padding: false) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, %{"key" => key, "label" => label}} when is_binary(key) and is_binary(label) ->
            {:ok, {key, label}}

          _ ->
            :error
        end

      _ ->
        :error
    end
  end

  defp kv_next_link(conn, nil), do: conn

  defp kv_next_link(conn, after_token) do
    base = "#{conn.scheme}://#{conn.host}:#{conn.port}"

    link_query =
      conn.query_string
      |> Plug.Conn.Query.decode()
      |> Map.drop(["after"])
      |> Map.put("after", after_token)
      |> URI.encode_query()

    put_resp_header(conn, "link", "<#{base}#{conn.request_path}?#{link_query}>; rel=\"next\"")
  end

  defp public_kv_record(record, fields) do
    record
    |> public_kv_record()
    |> Map.take(MapSet.to_list(fields))
  end

  # ---------------------------------------------------------------------------
  # Event Grid / Event Hubs CloudEvents ingestion (/topics/:topic/events)
  # ---------------------------------------------------------------------------
end
