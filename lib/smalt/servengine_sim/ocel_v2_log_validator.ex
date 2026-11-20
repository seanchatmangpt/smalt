defmodule Smalt.ServengineSim.OcelV2LogValidator do
  @moduledoc """
  Validates OCEL v2 `jsonPayload` stdout log lines for servengine simulation
  surfaces, enforcing compatibility with:

    * **GCP Cloud Logging** structured stdout ingestion: single-line JSON
      object (`<= 256 KiB` default), `jsonPayload` (rejects unstructured
      `textPayload`-only entries), valid Cloud Logging `severity` when
      present, and optional `ocel:version` (`"2.0"`).
    * **wasm4pm** (`wasm4pm_compat::ocel::validate`) OCEDO / OCPQ Def. 2
      invariants: all four OCEL 2.0 arrays (`ocel:eventTypes`,
      `ocel:objectTypes`, `ocel:events`, `ocel:objects`), unique event/object
      IDs, declared event/object types, RFC-3339/ISO-8601 timestamps, non-empty
      qualified E2O relationships (`relationships`), E2O & O2O referential
      integrity, and optional object-type cardinality windows.
    * **ex4pm** (`Ex4pm.OCEL.normalize/1`): verifies the validated OCEL 2.0
      document lowers cleanly into `%Ex4pm.EventLog{}` without refusal.
    * **PII & secret redaction**: walks `jsonPayload` (both map keys and OCEL
      2.0 `[{"name": ..., "value": ...}]` attribute lists) and refuses
      unredacted PII/credential keys or raw PII/token values (emails, SSNs,
      phone numbers, Luhn-valid PANs, JWTs, Bearer tokens, PEM private keys)
      while allowing explicit redaction sentinels (`"[REDACTED]"`,
      `"[redacted]"`, `"<redacted>"`, masked `u***@domain.com`, `+1******1234`,
      `eyJ<redacted>`, etc.).
  """

  @default_max_bytes 262_144

  @gcp_severities MapSet.new(~w(
    DEFAULT DEBUG INFO NOTICE WARNING ERROR CRITICAL ALERT EMERGENCY
  ))

  @ocel_keys ~w(ocel:eventTypes ocel:objectTypes ocel:events ocel:objects)

  @sensitive_keys MapSet.new(~w(
    password passphrase secret token jwt bearer authorization
    access_token refresh_token id_token api_key apikey private_key
    admin_password temporary_password otp_code sf_task_token
    sp_pin gate_code door_code unit_access_code client_secret
    ssn ssn_itin ssn_itin_hash ein ein_number tax_id tin
    dob date_of_birth birth_date
    email email_address phone phone_number mobile mobile_number
    home_address street_address mailing_address ip_address
    bank_account account_number routing_number
    ach_routing_number ach_account_number
    credit_card card_number cvv passport passport_number drivers_license
    first_name last_name full_name
  ))

  @redacted_sentinels MapSet.new([
                        "[REDACTED]",
                        "[redacted]",
                        "<redacted>",
                        "REDACTED",
                        "redacted",
                        "***",
                        "****",
                        "eyJ<redacted>"
                      ])

  @masked_email_re ~r/^[A-Za-z0-9._%+-]?\*{3,}@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$/
  @masked_phone_re ~r/^(?:\+?\d{0,2})?\*{3,}[-]?\*{0,3}[-]?\d{2,4}$/
  @masked_ssn_re ~r/^\*{3}-\*{2}-\d{4}$/

  @email_re ~r/\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b/
  @ssn_re ~r/\b(?!000|666|9\d{2})\d{3}-(?!00)\d{2}-(?!0000)\d{4}\b/
  @phone_sep_re ~r/(?<!\w)(?:\+?1[-.\s]?)?(?:\(\d{3}\)|\d{3})[-.\s]\d{3}[-.\s]\d{4}(?!\w)/
  @phone_e164_re ~r/(?<!\w)\+1\d{10}(?!\w)/
  @jwt_re ~r/\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}(?:\.[A-Za-z0-9_-]+)?\b/
  @bearer_re ~r/\bBearer\s+[A-Za-z0-9._~+\/-]{12,}=*/i
  @private_key_re ~r/-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----/
  @pan_candidate_re ~r/(?<!\w)(?:\d[ -]?){13,19}(?!\w)/

  @type violation :: %{
          code: atom(),
          path: String.t(),
          reason: String.t()
        }

  @type report :: %{
          valid: true,
          document: map(),
          json_payload: map(),
          ex4pm_log: Ex4pm.EventLog.t() | nil,
          event_count: non_neg_integer(),
          object_count: non_neg_integer(),
          pii_clean: true
        }

  @doc """
  Validates a single stdout log line (JSON string) or decoded Cloud Logging
  entry / `jsonPayload` map.

  Options:
    * `:require_version` — require `"ocel:version"` (or `"ocel_version"`) == `"2.0"` (default `false`)
    * `:allow_empty_events` — allow `"ocel:events" => []` (default `false`)
    * `:require_e2o` — require every event to have `>= 1` relationship (default `true`)
    * `:check_pii` — enforce PII and secret redaction (default `true`)
    * `:check_ex4pm` — validate lowering through `Ex4pm.OCEL.normalize/1` (default `true`)
    * `:max_bytes` — maximum stdout line byte size (default `#{@default_max_bytes}`)
    * `:cardinality` — optional `%{object_type => %{min_count: n, max_count: m}}` bounds (default `%{}`)
  """
  @spec validate_line(String.t() | map(), keyword()) :: {:ok, report()} | {:error, [violation()]}
  def validate_line(input, opts \\ [])

  def validate_line(line, opts) when is_binary(line) do
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)

    with {:ok, clean_line} <- check_raw_line(line, max_bytes),
         {:ok, decoded} <- decode_json_object(clean_line) do
      validate_decoded(decoded, opts)
    end
  end

  def validate_line(%{} = map, opts) do
    validate_decoded(map, opts)
  end

  def validate_line(other, _opts) do
    {:error,
     [violation(:invalid_input, "$", "expected JSON line string or map, got: #{inspect(other)}")]}
  end

  @doc """
  Convenience predicate: `true` iff `validate_line/2` returns `{:ok, _}`.
  """
  @spec valid?(String.t() | map(), keyword()) :: boolean()
  def valid?(input, opts \\ []) do
    match?({:ok, _}, validate_line(input, opts))
  end

  @doc """
  Validates a sequence of stdout log lines (an enumerable of lines/maps, or a
  newline-delimited string).

  Options (in addition to `validate_line/2` opts):
    * `:skip_blank` — skip blank lines (default `true`)
  """
  @spec validate_lines(String.t() | Enumerable.t(), keyword()) ::
          {:ok, [report()]} | {:error, [map()]}
  def validate_lines(input, opts \\ [])

  def validate_lines(blob, opts) when is_binary(blob) do
    blob
    |> String.split(~r/\r?\n/)
    |> validate_lines(opts)
  end

  def validate_lines(lines, opts) do
    skip_blank? = Keyword.get(opts, :skip_blank, true)

    {reports, violations} =
      lines
      |> Enum.with_index(1)
      |> Enum.reduce({[], []}, fn {item, line_no}, {ok_acc, err_acc} ->
        if skip_blank? and is_binary(item) and String.trim(item) == "" do
          {ok_acc, err_acc}
        else
          case validate_line(item, opts) do
            {:ok, report} ->
              {[Map.put(report, :line, line_no) | ok_acc], err_acc}

            {:error, line_violations} ->
              tagged = Enum.map(line_violations, &Map.put(&1, :line, line_no))
              {ok_acc, err_acc ++ tagged}
          end
        end
      end)

    cond do
      violations != [] ->
        {:error, violations}

      reports == [] ->
        {:error, [violation(:empty_log_stream, "$", "no log lines to validate")]}

      true ->
        {:ok, Enum.reverse(reports)}
    end
  end

  @doc """
  Converts a canonical OCEL 2.0 document (`ocel:events` / `ocel:objects`) into
  the raw map shape accepted by `Ex4pm.OCEL.normalize/1`.
  """
  @spec to_ex4pm_raw(map()) :: map()
  def to_ex4pm_raw(%{"ocel:events" => events, "ocel:objects" => objects})
      when is_list(events) and is_list(objects) do
    mapped_events =
      Enum.map(events, fn e ->
        %{
          "id" => e["id"],
          "activity" => e["type"],
          "timestamp" => e["time"],
          "relationships" => e["relationships"] || [],
          "attributes" => e["attributes"] || %{}
        }
      end)

    mapped_objects =
      Enum.map(objects, fn o ->
        %{
          "id" => o["id"],
          "type" => o["type"],
          "attributes" => o["attributes"] || %{}
        }
      end)

    object_relationships =
      for o <- objects,
          r <- o["relationships"] || [],
          is_map(r) do
        %{
          "source_id" => o["id"],
          "target_id" => r["objectId"] || r["target_id"],
          "qualifier" => r["qualifier"] || "related"
        }
      end

    %{
      "events" => mapped_events,
      "objects" => mapped_objects,
      "object_relationships" => object_relationships
    }
  end

  @doc """
  Walks a `jsonPayload` map/value and returns a list of PII or credential
  redaction violations (`[]` when clean).
  """
  @spec inspect_pii(term(), String.t()) :: [violation()]
  def inspect_pii(value, path \\ "$.jsonPayload")

  def inspect_pii(%{} = map, path) do
    if ocel_attr_pair?(map) do
      attr_name = map["name"]
      attr_val = map["value"]
      val_path = "#{path}[#{attr_name}]"
      check_key_value_pii(attr_name, attr_val, val_path)
    else
      Enum.flat_map(map, fn {k, v} ->
        key_str = to_string(k)
        child_path = "#{path}.#{key_str}"
        check_key_value_pii(key_str, v, child_path)
      end)
    end
  end

  def inspect_pii(list, path) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, idx} -> inspect_pii(item, "#{path}[#{idx}]") end)
  end

  def inspect_pii(str, path) when is_binary(str) do
    scan_string_pii(str, path)
  end

  def inspect_pii(_other, _path), do: []

  # -- Layer 1: GCP Cloud Logging stdout framing ----------------------------

  defp check_raw_line(line, max_bytes) do
    trimmed = String.trim_trailing(line, "\r\n") |> String.trim_trailing("\n")

    cond do
      String.trim(trimmed) == "" ->
        {:error, [violation(:empty_line, "$", "stdout log line is empty")]}

      String.contains?(trimmed, "\n") or String.contains?(trimmed, "\r") ->
        {:error,
         [violation(:multiline_log_line, "$", "stdout log line must be single-line JSON")]}

      byte_size(trimmed) > max_bytes ->
        {:error,
         [
           violation(
             :payload_too_large,
             "$",
             "stdout log line exceeds Cloud Logging max_bytes (#{byte_size(trimmed)} > #{max_bytes})"
           )
         ]}

      true ->
        {:ok, trimmed}
    end
  end

  defp decode_json_object(json_line) do
    case Jason.decode(json_line) do
      {:ok, %{} = map} ->
        {:ok, map}

      {:ok, other} ->
        {:error,
         [
           violation(
             :non_object_json,
             "$",
             "stdout log line must decode to a JSON object, got: #{inspect(other)}"
           )
         ]}

      {:error, err} ->
        {:error, [violation(:invalid_json, "$", "malformed JSON: #{Exception.message(err)}")]}
    end
  end

  defp validate_decoded(map, opts) do
    with {:ok, json_payload, envelope_errors} <- unwrap_cloud_logging_entry(map),
         {:ok, doc, payload_errors} <- extract_ocel_document(json_payload, opts) do
      doc_errors = validate_ocel_document(doc, opts)

      pii_errors =
        if Keyword.get(opts, :check_pii, true) do
          inspect_pii(json_payload, "$.jsonPayload")
        else
          []
        end

      all_structural_errors = envelope_errors ++ payload_errors ++ doc_errors

      {ex4pm_log, ex4pm_errors} =
        if all_structural_errors == [] and Keyword.get(opts, :check_ex4pm, true) do
          validate_ex4pm_compat(doc)
        else
          {nil, []}
        end

      all_errors = all_structural_errors ++ ex4pm_errors ++ pii_errors

      case all_errors do
        [] ->
          {:ok,
           %{
             valid: true,
             document: doc,
             json_payload: json_payload,
             ex4pm_log: ex4pm_log,
             event_count: length(doc["ocel:events"]),
             object_count: length(doc["ocel:objects"]),
             pii_clean: true
           }}

        violations ->
          {:error, violations}
      end
    else
      {:error, violations} -> {:error, violations}
    end
  end

  defp unwrap_cloud_logging_entry(map) do
    cond do
      Map.has_key?(map, "jsonPayload") ->
        case map["jsonPayload"] do
          %{} = jp ->
            {:ok, jp, validate_envelope_metadata(map, "$")}

          other ->
            {:error,
             [
               violation(
                 :invalid_json_payload,
                 "$.jsonPayload",
                 "jsonPayload must be a JSON object, got: #{inspect(other)}"
               )
             ]}
        end

      Map.has_key?(map, "textPayload") ->
        {:error,
         [
           violation(
             :text_payload_only,
             "$.textPayload",
             "Cloud Logging entry uses textPayload instead of structured jsonPayload"
           )
         ]}

      true ->
        {:ok, map, validate_envelope_metadata(map, "$.jsonPayload")}
    end
  end

  defp validate_envelope_metadata(map, prefix) do
    sev_err =
      case Map.fetch(map, "severity") do
        :error ->
          []

        {:ok, sev} when is_binary(sev) ->
          if MapSet.member?(@gcp_severities, sev) do
            []
          else
            [
              violation(
                :invalid_severity,
                "#{prefix}.severity",
                "invalid GCP Cloud Logging severity: #{inspect(sev)}"
              )
            ]
          end

        {:ok, other} ->
          [
            violation(
              :invalid_severity,
              "#{prefix}.severity",
              "severity must be a string, got: #{inspect(other)}"
            )
          ]
      end

    ts_err =
      case Map.fetch(map, "timestamp") do
        :error ->
          []

        {:ok, ts} ->
          if valid_iso8601?(ts) do
            []
          else
            [
              violation(
                :invalid_envelope_timestamp,
                "#{prefix}.timestamp",
                "timestamp must be valid RFC-3339/ISO-8601, got: #{inspect(ts)}"
              )
            ]
          end
      end

    sev_err ++ ts_err
  end

  defp extract_ocel_document(jp, opts) do
    version_errors = validate_ocel_version(jp, opts)

    cond do
      Enum.any?(@ocel_keys, &Map.has_key?(jp, &1)) ->
        {:ok, Map.take(jp, @ocel_keys), version_errors}

      is_map(jp["ocel"]) ->
        nested = jp["ocel"]
        nested_ver_err = validate_ocel_version(nested, opts, "$.jsonPayload.ocel")

        ver_errs =
          if Keyword.get(opts, :require_version, false) and version_errors == [],
            do: nested_ver_err,
            else: version_errors ++ nested_ver_err

        {:ok, Map.take(nested, @ocel_keys), ver_errs}

      true ->
        {:error,
         [
           violation(
             :missing_ocel_top_level_keys,
             "$.jsonPayload",
             "jsonPayload must contain OCEL 2.0 keys (#{Enum.join(@ocel_keys, ", ")}) directly or under jsonPayload.ocel"
           )
         ]}
    end
  end

  defp validate_ocel_version(map, opts, prefix \\ "$.jsonPayload") do
    ver = Map.get(map, "ocel:version") || Map.get(map, "ocel_version")
    require_version? = Keyword.get(opts, :require_version, false)

    cond do
      is_nil(ver) and require_version? ->
        [
          violation(
            :missing_ocel_version,
            "#{prefix}.ocel:version",
            "missing required ocel:version == \"2.0\""
          )
        ]

      is_nil(ver) ->
        []

      ver == "2.0" ->
        []

      true ->
        [
          violation(
            :unsupported_ocel_version,
            "#{prefix}.ocel:version",
            "expected ocel:version \"2.0\", got: #{inspect(ver)}"
          )
        ]
    end
  end

  # -- Layer 2: OCEL v2 + wasm4pm OCEDO/OCPQ invariants ---------------------

  defp validate_ocel_document(doc, opts) do
    missing_or_bad =
      Enum.flat_map(@ocel_keys, fn key ->
        case Map.fetch(doc, key) do
          :error ->
            [violation(:missing_ocel_key, "$.#{key}", "missing required OCEL 2.0 array #{key}")]

          {:ok, val} when is_list(val) ->
            []

          {:ok, val} ->
            [
              violation(
                :invalid_ocel_key_type,
                "$.#{key}",
                "#{key} must be an array, got: #{inspect(val)}"
              )
            ]
        end
      end)

    if missing_or_bad != [] do
      missing_or_bad
    else
      event_types = doc["ocel:eventTypes"]
      object_types = doc["ocel:objectTypes"]
      events = doc["ocel:events"]
      objects = doc["ocel:objects"]

      {declared_et, et_errors} =
        validate_type_declarations(event_types, "ocel:eventTypes", :event)

      {declared_ot, ot_errors} =
        validate_type_declarations(object_types, "ocel:objectTypes", :object)

      {object_ids, obj_type_counts, obj_errors} = validate_objects(objects, declared_ot)
      o2o_errors = validate_o2o(objects, object_ids)

      empty_events_err =
        if not Keyword.get(opts, :allow_empty_events, false) and events == [] do
          [
            violation(
              :empty_events,
              "$.ocel:events",
              "ocel:events must contain at least one event"
            )
          ]
        else
          []
        end

      ev_errors = validate_events(events, declared_et, object_ids, opts)
      card_errors = validate_cardinality(obj_type_counts, Keyword.get(opts, :cardinality, %{}))

      et_errors ++
        ot_errors ++ obj_errors ++ o2o_errors ++ empty_events_err ++ ev_errors ++ card_errors
    end
  end

  defp validate_type_declarations(decls, key, kind) do
    {code_decl, code_dup} =
      case kind do
        :event -> {:invalid_event_type_declaration, :duplicate_event_type}
        :object -> {:invalid_object_type_declaration, :duplicate_object_type}
      end

    {names, errors} =
      decls
      |> Enum.with_index()
      |> Enum.reduce({MapSet.new(), []}, fn {decl, idx}, {seen, errs} ->
        path = "$.#{key}[#{idx}]"

        case decl do
          %{"name" => name} when is_binary(name) ->
            trimmed = String.trim(name)

            cond do
              trimmed == "" ->
                {seen,
                 errs ++
                   [
                     violation(
                       code_decl,
                       "#{path}.name",
                       "type declaration name must be non-empty"
                     )
                   ]}

              MapSet.member?(seen, name) ->
                {seen,
                 errs ++
                   [
                     violation(
                       code_dup,
                       "#{path}.name",
                       "duplicate #{kind} type declaration: #{inspect(name)}"
                     )
                   ]}

              true ->
                attr_errs =
                  validate_type_schema_attrs(
                    Map.get(decl, "attributes"),
                    "#{path}.attributes",
                    code_decl
                  )

                {MapSet.put(seen, name), errs ++ attr_errs}
            end

          _ ->
            {seen,
             errs ++
               [
                 violation(
                   code_decl,
                   path,
                   "type declaration must be an object with non-empty string \"name\""
                 )
               ]}
        end
      end)

    {names, errors}
  end

  defp validate_type_schema_attrs(nil, _path, _code), do: []

  defp validate_type_schema_attrs(attrs, path, code) when is_list(attrs) do
    attrs
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {%{"name" => n, "type" => t}, idx} when is_binary(n) and is_binary(t) ->
        if String.trim(n) == "" or String.trim(t) == "" do
          [
            violation(
              code,
              "#{path}[#{idx}]",
              "type attribute schema requires non-empty name and type"
            )
          ]
        else
          []
        end

      {_, idx} ->
        [
          violation(
            code,
            "#{path}[#{idx}]",
            "type attribute schema must have string name and type"
          )
        ]
    end)
  end

  defp validate_type_schema_attrs(_, path, code) do
    [violation(code, path, "type attribute schema must be an array")]
  end

  defp validate_objects(objects, declared_ot) do
    objects
    |> Enum.with_index()
    |> Enum.reduce({MapSet.new(), %{}, []}, fn {obj, idx}, {ids, counts, errs} ->
      path = "$.ocel:objects[#{idx}]"

      if not is_map(obj) do
        {ids, counts, errs ++ [violation(:invalid_object, path, "object must be a JSON object")]}
      else
        id = obj["id"]
        type = obj["type"]

        {ids2, id_errs} =
          cond do
            not non_empty_binary?(id) ->
              {ids,
               [
                 violation(
                   :missing_object_id,
                   "#{path}.id",
                   "object id must be a non-empty string"
                 )
               ]}

            MapSet.member?(ids, id) ->
              {ids,
               [
                 violation(
                   :duplicate_object_id,
                   "#{path}.id",
                   "duplicate object id: #{inspect(id)}"
                 )
               ]}

            true ->
              {MapSet.put(ids, id), []}
          end

        {counts2, type_errs} =
          cond do
            not non_empty_binary?(type) ->
              {counts,
               [
                 violation(
                   :missing_object_type,
                   "#{path}.type",
                   "object type must be a non-empty string"
                 )
               ]}

            not MapSet.member?(declared_ot, type) ->
              {Map.update(counts, type, 1, &(&1 + 1)),
               [
                 violation(
                   :undeclared_object_type,
                   "#{path}.type",
                   "object #{inspect(id)} has undeclared type #{inspect(type)}"
                 )
               ]}

            true ->
              {Map.update(counts, type, 1, &(&1 + 1)), []}
          end

        attr_errs =
          validate_record_attributes(Map.get(obj, "attributes"), "#{path}.attributes", :object)

        {ids2, counts2, errs ++ id_errs ++ type_errs ++ attr_errs}
      end
    end)
  end

  defp validate_o2o(objects, object_ids) do
    objects
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {%{} = obj, idx} ->
        path = "$.ocel:objects[#{idx}].relationships"

        case Map.get(obj, "relationships") do
          nil ->
            []

          rels when is_list(rels) ->
            rels
            |> Enum.with_index()
            |> Enum.flat_map(fn {rel, ridx} ->
              rpath = "#{path}[#{ridx}]"

              case rel do
                %{"objectId" => target_id, "qualifier" => qual}
                when is_binary(target_id) and is_binary(qual) ->
                  cond do
                    String.trim(target_id) == "" or String.trim(qual) == "" ->
                      [
                        violation(
                          :invalid_o2o_relationship,
                          rpath,
                          "O2O relationship requires non-empty objectId and qualifier"
                        )
                      ]

                    not MapSet.member?(object_ids, target_id) ->
                      [
                        violation(
                          :dangling_o2o,
                          "#{rpath}.objectId",
                          "object #{inspect(obj["id"])} references unknown object #{inspect(target_id)}"
                        )
                      ]

                    true ->
                      []
                  end

                _ ->
                  [
                    violation(
                      :invalid_o2o_relationship,
                      rpath,
                      "O2O relationship must be an object with string objectId and qualifier"
                    )
                  ]
              end
            end)

          other ->
            [
              violation(
                :invalid_o2o_relationships,
                path,
                "object relationships must be an array, got: #{inspect(other)}"
              )
            ]
        end

      _ ->
        []
    end)
  end

  defp validate_events(events, declared_et, object_ids, opts) do
    require_e2o? = Keyword.get(opts, :require_e2o, true)

    {_seen_ids, errors} =
      events
      |> Enum.with_index()
      |> Enum.reduce({MapSet.new(), []}, fn {ev, idx}, {seen, errs} ->
        path = "$.ocel:events[#{idx}]"

        if not is_map(ev) do
          {seen, errs ++ [violation(:invalid_event, path, "event must be a JSON object")]}
        else
          id = ev["id"]
          type = ev["type"]
          time = ev["time"]

          {seen2, id_errs} =
            cond do
              not non_empty_binary?(id) ->
                {seen,
                 [
                   violation(
                     :missing_event_id,
                     "#{path}.id",
                     "event id must be a non-empty string"
                   )
                 ]}

              MapSet.member?(seen, id) ->
                {seen,
                 [
                   violation(
                     :duplicate_event_id,
                     "#{path}.id",
                     "duplicate event id: #{inspect(id)}"
                   )
                 ]}

              true ->
                {MapSet.put(seen, id), []}
            end

          type_errs =
            cond do
              not non_empty_binary?(type) ->
                [
                  violation(
                    :missing_event_type,
                    "#{path}.type",
                    "event type must be a non-empty string"
                  )
                ]

              not MapSet.member?(declared_et, type) ->
                [
                  violation(
                    :undeclared_event_type,
                    "#{path}.type",
                    "event #{inspect(id)} has undeclared type #{inspect(type)}"
                  )
                ]

              true ->
                []
            end

          time_errs =
            if valid_iso8601?(time) do
              []
            else
              [
                violation(
                  :invalid_timestamp,
                  "#{path}.time",
                  "event #{inspect(id)} time must be a valid RFC-3339/ISO-8601 timestamp, got: #{inspect(time)}"
                )
              ]
            end

          attr_errs =
            validate_record_attributes(Map.get(ev, "attributes"), "#{path}.attributes", :event)

          rel_errs = validate_e2o(ev, path, object_ids, require_e2o?)

          {seen2, errs ++ id_errs ++ type_errs ++ time_errs ++ attr_errs ++ rel_errs}
        end
      end)

    errors
  end

  defp validate_e2o(ev, path, object_ids, require_e2o?) do
    rpath = "#{path}.relationships"

    case Map.fetch(ev, "relationships") do
      :error ->
        if require_e2o? do
          [
            violation(
              :e2o_empty,
              rpath,
              "event #{inspect(ev["id"])} has no relationships (OCPQ Def. 2)"
            )
          ]
        else
          []
        end

      {:ok, []} ->
        if require_e2o? do
          [
            violation(
              :e2o_empty,
              rpath,
              "event #{inspect(ev["id"])} has empty relationships (OCPQ Def. 2)"
            )
          ]
        else
          []
        end

      {:ok, rels} when is_list(rels) ->
        rels
        |> Enum.with_index()
        |> Enum.flat_map(fn {rel, ridx} ->
          epath = "#{rpath}[#{ridx}]"

          case rel do
            %{"objectId" => oid, "qualifier" => qual} when is_binary(oid) and is_binary(qual) ->
              cond do
                String.trim(oid) == "" or String.trim(qual) == "" ->
                  [
                    violation(
                      :invalid_e2o_relationship,
                      epath,
                      "E2O relationship requires non-empty objectId and qualifier"
                    )
                  ]

                not MapSet.member?(object_ids, oid) ->
                  [
                    violation(
                      :dangling_e2o,
                      "#{epath}.objectId",
                      "event #{inspect(ev["id"])} references unknown object #{inspect(oid)}"
                    )
                  ]

                true ->
                  []
              end

            _ ->
              [
                violation(
                  :invalid_e2o_relationship,
                  epath,
                  "E2O relationship must be an object with string objectId and qualifier"
                )
              ]
          end
        end)

      {:ok, other} ->
        [
          violation(
            :invalid_e2o_relationships,
            rpath,
            "event relationships must be an array, got: #{inspect(other)}"
          )
        ]
    end
  end

  defp validate_record_attributes(nil, _path, _kind), do: []
  defp validate_record_attributes(%{} = _attrs, _path, _kind), do: []

  defp validate_record_attributes(attrs, path, kind) when is_list(attrs) do
    attrs
    |> Enum.with_index()
    |> Enum.flat_map(fn {entry, idx} ->
      epath = "#{path}[#{idx}]"

      case entry do
        %{"name" => name} = pair when is_binary(name) ->
          cond do
            String.trim(name) == "" ->
              [
                violation(
                  :invalid_attributes,
                  "#{epath}.name",
                  "attribute name must be non-empty"
                )
              ]

            not Map.has_key?(pair, "value") ->
              [violation(:invalid_attributes, epath, "attribute entry must include \"value\"")]

            kind == :object and Map.has_key?(pair, "time") and not valid_iso8601?(pair["time"]) ->
              [
                violation(
                  :invalid_timestamp,
                  "#{epath}.time",
                  "object attribute time must be valid ISO-8601, got: #{inspect(pair["time"])}"
                )
              ]

            true ->
              []
          end

        _ ->
          [
            violation(
              :invalid_attributes,
              epath,
              "attribute list entry must be an object with \"name\" and \"value\""
            )
          ]
      end
    end)
  end

  defp validate_record_attributes(other, path, _kind) do
    [
      violation(
        :invalid_attributes,
        path,
        "attributes must be a JSON object or array of {name, value} pairs, got: #{inspect(other)}"
      )
    ]
  end

  defp validate_cardinality(_counts, cardinality) when map_size(cardinality) == 0, do: []

  defp validate_cardinality(counts, cardinality) do
    Enum.flat_map(cardinality, fn {type_name, bounds} ->
      count = Map.get(counts, to_string(type_name), 0)
      min_c = Map.get(bounds, :min_count) || Map.get(bounds, "min_count")
      max_c = Map.get(bounds, :max_count) || Map.get(bounds, "max_count")

      min_err =
        if is_integer(min_c) and count < min_c do
          [
            violation(
              :cardinality_min,
              "$.ocel:objects",
              "object type #{inspect(type_name)} count #{count} < min_count #{min_c}"
            )
          ]
        else
          []
        end

      max_err =
        if is_integer(max_c) and count > max_c do
          [
            violation(
              :cardinality_max,
              "$.ocel:objects",
              "object type #{inspect(type_name)} count #{count} > max_count #{max_c}"
            )
          ]
        else
          []
        end

      min_err ++ max_err
    end)
  end

  # -- ex4pm compatibility ---------------------------------------------------

  defp validate_ex4pm_compat(doc) do
    if Code.ensure_loaded?(Ex4pm.OCEL) do
      case Ex4pm.OCEL.normalize(to_ex4pm_raw(doc)) do
        {:ok, log} ->
          {log, []}

        {:error, refusal} ->
          {nil,
           [
             violation(
               :ex4pm_incompatible,
               "$",
               "Ex4pm.OCEL.normalize/1 refused document: #{inspect(refusal)}"
             )
           ]}
      end
    else
      {nil, []}
    end
  end

  # -- Layer 3: PII & secret redaction --------------------------------------

  defp check_key_value_pii(key, value, path) do
    if sensitive_key?(key) do
      if redacted_value?(value) do
        []
      else
        [
          violation(
            :unredacted_pii_key,
            path,
            "sensitive/PII field #{inspect(key)} is not redacted"
          )
        ]
      end
    else
      inspect_pii(value, path)
    end
  end

  defp ocel_attr_pair?(%{"name" => name, "value" => _}) when is_binary(name), do: true
  defp ocel_attr_pair?(_), do: false

  defp sensitive_key?(key) when is_binary(key) do
    normalized = normalize_key(key)
    MapSet.member?(@sensitive_keys, normalized)
  end

  defp normalize_key(key) do
    key
    |> String.replace(~r/([a-z0-9])([A-Z])/, "\\1_\\2")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end

  defp redacted_value?(nil), do: true
  defp redacted_value?(""), do: true

  defp redacted_value?(val) when is_binary(val) do
    trimmed = String.trim(val)

    MapSet.member?(@redacted_sentinels, trimmed) or
      String.starts_with?(trimmed, "[REDACTED") or
      String.starts_with?(trimmed, "[redacted") or
      Regex.match?(@masked_email_re, trimmed) or
      Regex.match?(@masked_phone_re, trimmed) or
      Regex.match?(@masked_ssn_re, trimmed)
  end

  defp redacted_value?(_other), do: false

  defp scan_string_pii(str, path) do
    if redacted_value?(str) do
      []
    else
      []
      |> maybe_flag(
        Regex.match?(@private_key_re, str),
        :pii_private_key_leaked,
        path,
        "PEM private key leaked in log value"
      )
      |> maybe_flag(
        Regex.match?(@jwt_re, str),
        :pii_jwt_leaked,
        path,
        "unredacted JWT token leaked in log value"
      )
      |> maybe_flag(
        Regex.match?(@bearer_re, str),
        :pii_bearer_leaked,
        path,
        "unredacted Bearer credential leaked in log value"
      )
      |> maybe_flag(
        Regex.match?(@email_re, str),
        :pii_email_leaked,
        path,
        "unredacted email address leaked in log value"
      )
      |> maybe_flag(
        Regex.match?(@ssn_re, str),
        :pii_ssn_leaked,
        path,
        "unredacted SSN leaked in log value"
      )
      |> maybe_flag(
        Regex.match?(@phone_sep_re, str) or Regex.match?(@phone_e164_re, str),
        :pii_phone_leaked,
        path,
        "unredacted phone number leaked in log value"
      )
      |> maybe_flag(
        luhn_pan_match?(str),
        :pii_pan_leaked,
        path,
        "unredacted payment card PAN leaked in log value"
      )
    end
  end

  defp maybe_flag(errs, true, code, path, reason), do: errs ++ [violation(code, path, reason)]
  defp maybe_flag(errs, false, _code, _path, _reason), do: errs

  defp luhn_pan_match?(str) do
    Regex.scan(@pan_candidate_re, str)
    |> Enum.any?(fn [candidate] ->
      digits = String.replace(candidate, ~r/[ -]/, "")
      len = byte_size(digits)
      len >= 13 and len <= 19 and luhn_valid?(digits)
    end)
  end

  defp luhn_valid?(digits) do
    sum =
      digits
      |> String.graphemes()
      |> Enum.reverse()
      |> Enum.with_index()
      |> Enum.reduce(0, fn {ch, idx}, acc ->
        d = String.to_integer(ch)

        val =
          if rem(idx, 2) == 1 do
            doubled = d * 2
            if doubled > 9, do: doubled - 9, else: doubled
          else
            d
          end

        acc + val
      end)

    rem(sum, 10) == 0
  end

  # -- helpers ---------------------------------------------------------------

  defp non_empty_binary?(v), do: is_binary(v) and String.trim(v) != ""

  defp valid_iso8601?(v) when is_binary(v) do
    match?({:ok, _, _}, DateTime.from_iso8601(v))
  end

  defp valid_iso8601?(_), do: false

  defp violation(code, path, reason), do: %{code: code, path: path, reason: reason}
end
