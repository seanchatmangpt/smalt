defmodule Smalt.DataPlane.AppConfigFeatures do
  @moduledoc """
  Azure App Configuration feature-flag convention (v26.10.20, wave-6 lane w6ax).

  Azure parity surface (Azure.AppConfiguration feature flags + the
  Microsoft.FeatureManagement evaluation semantics):

    - Flags are kv rows under the reserved key prefix
      `.appconfig.featureflag/{name`, with content type
      `application/vnd.microsoft.appconfig.ff+json` and a JSON value:
        {"enabled": true|false,
         "conditions": {"client_filters": [{"name": "TimeWindowFilter", ...}]}}

    - `put_flag/4`   — write/replace a flag row (JSON-validated, typed 400 face).
    - `get_flag/2`   — read one flag (JSON-validated on read too).
    - `list_flags/1` — all flags for a label, key-sorted.
    - `delete_flag/2` — remove a flag row.
    - `evaluate/3`   — FeatureManagement semantics:
        missing flag  → :undefined
        disabled flag → false
        enabled, no client_filters → true
        enabled, with filters → AND-composition of all filter verdicts
        unknown filter name → false (conservative)
        known-class filter eval error (ArgumentError/ErlangError) → false with
        `[:smalt, :appconfig, :filter_error]` telemetry; unknown raises propagate

  Storage: flags ARE kv rows in the appconfig kv plane (`:smalt_appconfig`,
  keyed {key, label}); no new ETS table needed (the flag surface is a
  projection of the kv store). Writes ride the lawful path
  (`AppConfigRevisions.write/4` — Store.put then revision record) so flag
  writes appear in the revisions history.

  Typed errors: `{:error, {code, message}}` (HTTP-mappable, 400 face) or
  `{:error, :not_found}` (404 face).
  """

  alias Smalt.AppConfigRevisions

  @flag_prefix ".appconfig.featureflag/"
  @content_type "application/vnd.microsoft.appconfig.ff+json;charset=utf-8"

  # ------------------------------------------------------------------
  # CRUD
  # ------------------------------------------------------------------

  @doc "Write/replace a feature flag row. body is a binary JSON or a map."
  @spec put_flag(String.t(), String.t() | map(), String.t(), map()) ::
          {:ok, map()} | {:error, {String.t(), String.t()}}
  def put_flag(name, body, label \\ "", tags \\ %{}) do
    with :ok <- valid_name?(name),
         {:ok, flag} <- parse_body(body) do
      row = %{
        "key" => @flag_prefix <> name,
        "label" => label,
        "value" => Jason.encode!(flag),
        "contentType" => @content_type,
        "tags" => tags,
        "etag" => quote_etag(name, label, flag),
        "new_etag" => true,
        "locked" => false,
        "last_modified" => System.system_time(:second)
      }

      AppConfigRevisions.write(@flag_prefix <> name, label, read_existing(name, label), row)
    end
  end

  @doc "Read one flag: {:ok, flag_map} | {:error, :not_found} | {:error, {code, msg}}."
  @spec get_flag(String.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found | {String.t(), String.t()}}
  def get_flag(name, label \\ "") do
    case read_existing(name, label) do
      {:ok, row} -> decode_value(row)
      :error -> {:error, :not_found}
    end
  end

  @doc "List flags for a label (key-sorted). Each element is {:ok, flag} | {:error, ...} per row."
  @spec list_flags(String.t()) :: [map()]
  def list_flags(label \\ "") do
    if store_ready?() do
      :ets.tab2list(:smalt_appconfig)
      |> Enum.filter(fn {{k, l}, _rec} -> l == label and String.starts_with?(k, @flag_prefix) end)
      |> Enum.map(fn {{k, _l}, rec} ->
        name = String.replace_prefix(k, @flag_prefix, "")
        {:ok, flag} = decode_value(rec)
        %{"name" => name, "label" => label} |> Map.merge(flag)
      end)
      |> Enum.sort_by(& &1["name"])
    else
      []
    end
  end
  @doc """
  Evaluate a feature flag per Microsoft.FeatureManagement semantics.
  ctx: %{"user_id" => binary|nil, "groups" => [binary]}. Returns
  true | false | :undefined (missing or unreadable flag).
  """
  @spec evaluate(String.t(), map(), String.t()) :: boolean() | :undefined
  def evaluate(name, ctx \\ %{}, label \\ "") do
    case get_flag(name, label) do
      {:ok, flag} -> eval_enabled(flag, name, ctx)
      _missing_or_malformed -> :undefined
    end
  end

  @doc "Delete a flag row. {:ok, name} | {:error, :not_found}."
  @spec delete_flag(String.t(), String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def delete_flag(name, label \\ "") do
    case read_existing(name, label) do
      {:ok, _row} ->
        true = :ets.delete(:smalt_appconfig, {@flag_prefix <> name, label})
        {:ok, name}

      _ ->
        {:error, :not_found}
    end
  end

  # ------------------------------------------------------------------
  # Evaluation
  # ------------------------------------------------------------------

  defp eval_enabled(flag, name, ctx) do
    if flag["enabled"] === true do
      flag_filters(flag)
      |> Enum.reduce_while(true, fn f, _acc ->
        case eval_filter(f, name, ctx) do
          true -> {:cont, true}
          false -> {:halt, false}
        end
      end)
    else
      false
    end
  end

  defp flag_filters(flag) do
    flag
    |> Map.get("conditions", %{})
    |> Map.get("client_filters", [])
    |> List.wrap()
  end

  # AND-composition; unknown filter name or evaluation error → false.
  defp eval_filter(%{"name" => fname} = f, flag_name, ctx) do
    try do
      case fname do
        "TimeWindowFilter" -> eval_time_window(f["parameters"] || %{})
        "TargetingFilter" -> eval_targeting(flag_name, f["parameters"] || %{}, ctx)
        _unknown -> false
      end
    rescue
      # ARMSTRONG fix 2: narrowed rescue. Only known eval-data exception
      # classes (badmap on malformed filter parameters, raw :erlang errors)
      # fold to the conservative `false` verdict — with telemetry, so a
      # filter error is never silent. Unknown raises propagate (let-it-crash):
      # an evaluation bug must not be absorbed into a business verdict.
      e in [ArgumentError, ErlangError] ->
        :telemetry.execute([:smalt, :appconfig, :filter_error], %{count: 1}, %{
          flag: flag_name,
          filter: fname,
          error: Exception.format(:error, e)
        })

        false
    end
  end

  defp eval_filter(_, _, _), do: false

  defp eval_time_window(params) do
    now = DateTime.utc_now()
    from = parse_rfc3339(params["From"] || params["from"])
    to = parse_rfc3339(params["To"] || params["to"])

    cond do
      from != nil and to != nil ->
        DateTime.compare(now, from) != :lt and DateTime.compare(now, to) != :gt

      from != nil ->
        DateTime.compare(now, from) != :lt

      to != nil ->
        DateTime.compare(now, to) != :gt

      :else ->
        false
    end
  end

  defp parse_rfc3339(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _off} -> dt
      _ -> nil
    end
  end

  defp parse_rfc3339(_), do: nil

  defp eval_targeting(flag_name, params, ctx) do
    audience = params["Audience"] || params["audience"] || %{}
    user_id = ctx["user_id"]

    cond do
      not is_binary(user_id) ->
        false

      user_id in List.wrap(audience["Users"]) ->
        true

      :else ->
        pct =
          audience["Groups"]
          |> List.wrap()
          |> Enum.find_value(fn
            %{"Name" => gname, "RolloutPercentage" => p} ->
              if user_group_member?(ctx, gname), do: p, else: nil

            %{name: gname, rollout_percentage: p} ->
              if user_group_member?(ctx, gname), do: p, else: nil

            _ ->
              nil
          end) || audience["DefaultRolloutPercentage"] || 0

        rollout_hit?(flag_name, user_id, pct)
    end
  end

  defp user_group_member?(ctx, gname) do
    gname != nil and to_string(gname) in Enum.map(List.wrap(ctx["groups"] || []), &to_string/1)
  end

  @doc """
  Deterministic rollout: MD5(name <> 0xFF <> user_id) first 4 bytes as uint32
  mod 100. MD5 is chosen (not crypto strength — stability): it is deterministic
  across runs/nodes and does not mint atoms; any stable digest would do and the
  hash function is an implementation detail behind rollout_hit?/3.
  """
  def rollout_hit?(flag_name, user_id, pct) when pct in 0..100 do
    bucket =
      :crypto.hash(:md5, to_string(flag_name) <> <<0xFF>> <> to_string(user_id))
      |> :binary.part(0, 4)
      |> :binary.decode_unsigned()

    rem(bucket, 100) < pct
  end

  def rollout_hit?(_, _, pct) when is_integer(pct), do: pct <= 0
  def rollout_hit?(_, _, _), do: false

  # ------------------------------------------------------------------
  # Internals
  # ------------------------------------------------------------------

  defp valid_name?(name) when is_binary(name) and byte_size(name) > 0, do: :ok
  defp valid_name?(_), do: {:error, {"InvalidFeatureFlagName", "feature flag name must be a non-empty string"}}

  defp parse_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, m} -> parse_body(m)
      _ -> {:error, {"InvalidFeatureFlag", "value must be valid feature-flag JSON"}}
    end
  end

  defp parse_body(%{} = m) do
    with {:ok, _} <- require_enabled(m) do
      filters =
        case get_in(m, ["conditions", "client_filters"]) do
          nil -> []
          fl when is_list(fl) -> Enum.map(fl, &normalize_filter/1)
          _ -> {:error, {"InvalidFeatureFlag", "conditions.client_filters must be a list"}}
        end

      case filters do
        {:error, _} = err -> err
        fl -> {:ok, %{"enabled" => m["enabled"], "conditions" => %{"client_filters" => fl}}}
      end
    end
  end

  defp parse_body(_), do: {:error, {"InvalidFeatureFlag", "value must be a JSON object"}}

  defp require_enabled(%{"enabled" => e}) when is_boolean(e), do: {:ok, e}
  defp require_enabled(_), do: {:error, {"InvalidFeatureFlag", "\"enabled\" must be a boolean"}}

  defp normalize_filter(%{"name" => n} = f) when is_binary(n) do
    %{"name" => n, "parameters" => (is_map(f["parameters"]) && f["parameters"]) || %{}}
  end

  defp normalize_filter(%{name: n} = f) when is_binary(n) do
    %{"name" => n, "parameters" => (is_map(f.parameters) && f.parameters) || %{}}
  end

  defp normalize_filter(_), do: {:error, {"InvalidFeatureFlag", "each client_filter needs a string name"}}

  defp decode_value(row) do
    case Jason.decode(row["value"]) do
      {:ok, m} when is_map(m) -> {:ok, m}
      _ -> {:error, {"InvalidFeatureFlag", "stored value is not valid feature-flag JSON"}}
    end
  end

  defp read_existing(name, label) do
    if store_ready?() do
      Smalt.Store.get(:smalt_appconfig, {@flag_prefix <> name, label})
    else
      :error
    end
  end

  defp store_ready?, do: :ets.info(:smalt_appconfig) != :undefined

  defp quote_etag(name, label, flag) do
    "\""
      <> Base.encode64(:crypto.hash(:md5, :erlang.term_to_binary({name, label, flag})))
      <> "\""
  end
end
