defmodule Smalt.Messaging.EgAdvancedFilters do
  @moduledoc """
  Event Grid advanced-filter evaluation (Azure parity, v26.10.20 lane w6af).

  `matches?/2` evaluates the ARM `advancedFilters` shape against a delivered
  CloudEvents-shaped envelope map. ARM path syntax over the event:

    - `data.key1.key2` — nested data lookup
    - `data.array[0]`  — array index into data
    - bare `subject` / `topic` / `eventType` — envelope attributes

  Operators (ARM names, one key per filter map entry):

    - string:  `stringEquals`, `stringNotEquals`, `stringIn`, `stringNotIn`,
      `stringBeginsWith`, `stringEndsWith`, `stringContains`
    - number:  `numberIn`, `numberNotIn`, `numberLessThan`,
      `numberLessThanOrEquals`, `numberGreaterThan`, `numberGreaterThanOrEquals`
    - bool:    `boolEquals`

  `values` is always a LIST in the ARM shape (even for the scalar comparators,
  which take single-element lists). A filter whose operator is unknown raises
  `ArgumentError` — real Event Grid refuses an unknown operator at
  subscription-create, so the subscribe path validates via `validate!/1` and
  refuses identically.
  """

  @operators ~w(
    stringEquals stringNotEquals stringIn stringNotIn
    stringBeginsWith stringEndsWith stringContains
    numberIn numberNotIn numberLessThan numberLessThanOrEquals
    numberGreaterThan numberGreaterThanOrEquals
    boolEquals
  )

  @typedoc "One ARM advanced-filter entry, e.g. %{\"key\" => \"data.severity\", \"operator\" => \"stringEquals\", \"values\" => [\"high\"]}"
  @type filter :: %{required(String.t()) => term()}

  @doc "Known operator names (subscription-create validation surface)."
  @spec operators() :: [String.t()]
  def operators, do: @operators

  @doc """
  Validates a filters list; raises ArgumentError on a malformed entry
  (unknown operator, missing key/operator, bad values shape).
  """
  @spec validate!([filter()]) :: :ok
  def validate!(filters) when is_list(filters) do
    Enum.each(filters, &validate_filter!/1)
    :ok
  end

  def validate!(filters),
    do: raise(ArgumentError, "advancedFilters must be a list, got: #{inspect(filters)}")

  defp validate_filter!(%{"operator" => op} = f) when op in @operators do
    unless is_binary(f["key"]) do
      raise ArgumentError, "advancedFilters entry needs a string \"key\", got: #{inspect(f)}"
    end

    values = Map.get(f, "values")

    unless is_list(values) do
      raise ArgumentError,
            "advancedFilters #{op} entry needs a \"values\" list, got: #{inspect(f)}"
    end
  end

  defp validate_filter!(f) do
    raise ArgumentError,
          "advancedFilters unknown operator #{inspect(f["operator"])} " <>
            "(supported: #{Enum.join(@operators, ", ")}): #{inspect(f)}"
  end

  @doc """
  True when EVERY filter matches the event envelope. An empty list matches
  everything (no filter = receive all, ARM default).
  """
  @spec matches?([filter()], map()) :: boolean()
  def matches?(filters, event) when is_list(filters) and is_map(event) do
    Enum.all?(filters, &match_filter?(&1, event))
  end

  def matches?(nil, _event), do: true

  defp match_filter?(%{"operator" => op, "key" => key} = f, event) do
    values = Map.get(f, "values", [])
    actual = lookup(key, event)
    apply_op(op, actual, values)
  end

  # -- ARM path lookup -------------------------------------------------------------

  # Bare attribute: subject/topic/eventType/eventTime/id map onto the envelope
  # fields (CloudEvents + Event Grid schema spellings); "data.*" descends into
  # the data payload.
  defp lookup("data." <> path, event) do
    data = event["data"] || event[:data] || %{}
    path_lookup(split_path(path), data)
  end

  defp lookup(attr, event)
       when attr in ~w(subject topic eventType eventTime id dataVersion) do
    # Envelope attribute: check binary keys and the known atom spellings
    # explicitly (no atom minting from filter-controlled input).
    value =
      event[attr] || event[camelize_attr(attr)] ||
        case attr do
          "eventType" -> event[:type]
          "eventTime" -> event[:time]
          "dataVersion" -> event[:dataVersion]
          "subject" -> event[:subject]
          "topic" -> event[:topic]
          "id" -> event[:id]
        end

    normalize(value)
  end

  defp lookup(path, event), do: path_lookup(normalize(path), event)

  # "key1.key2" and "arr[0].x" → segment list. Array indices are split into
  # their own segments so the list clause can consume them.
  defp split_path(path) do
    path
    |> String.split(".", trim: true)
    |> Enum.flat_map(fn seg ->
      case Regex.run(~r/^([^\[\]]+)\[(\d+)\](\[\d+\])*$/, seg) do
        [_, name, idx, extra] ->
          [name, idx] ++ split_indices(extra)

        [_, name, idx] ->
          [name, idx]

        _ ->
          case Regex.run(~r/^\[(\d+)\]$/, seg) do
            [_, idx] -> [idx]
            _ -> [seg]
          end
      end
    end)
  end

  defp split_indices(""), do: []
  defp split_indices(extra) do
    Regex.scan(~r/\[(\d+)\]/, extra) |> Enum.map(&String.slice(&1 |> hd(), 1..-2//1))
  end
  defp path_lookup([], acc), do: normalize(acc)

  defp path_lookup([seg | rest], acc) when is_map(acc) do
    case Enum.find_value(acc, fn {k, v} -> if normalize(k) == seg, do: v end) do
      nil -> nil
      v -> path_lookup(rest, v)
    end
  end

  defp path_lookup([seg | rest], acc) when is_list(acc) do
    case Integer.parse(seg) do
      {idx, ""} -> path_lookup(rest, Enum.at(acc, idx))
      _ -> nil
    end
  end

  defp path_lookup(_, _), do: nil

  defp normalize(v) when is_binary(v), do: v
  defp normalize(v) when is_atom(v) and not is_boolean(v), do: Atom.to_string(v)
  defp normalize(v) when is_number(v) and is_integer(v), do: Integer.to_string(v)
  defp normalize(v) when is_number(v), do: Float.to_string(v)
  defp normalize(true), do: "true"
  defp normalize(false), do: "false"
  defp normalize(v), do: v

  defp camelize_attr("eventType"), do: "type"
  defp camelize_attr("eventTime"), do: "time"
  defp camelize_attr(attr), do: attr

  # -- Operators -------------------------------------------------------------------

  defp apply_op("stringEquals", actual, values),
    do: actual != nil and normalize(actual) in Enum.map(values, &normalize/1)

  defp apply_op("stringNotEquals", actual, values),
    do: actual == nil or normalize(actual) not in Enum.map(values, &normalize/1)

  defp apply_op("stringIn", actual, values),
    do: actual != nil and normalize(actual) in Enum.map(values, &normalize/1)

  defp apply_op("stringNotIn", actual, values),
    do: actual == nil or normalize(actual) not in Enum.map(values, &normalize/1)

  defp apply_op("stringBeginsWith", actual, prefixes) when actual != nil,
    do: Enum.any?(prefixes, &String.starts_with?(normalize(actual), normalize(&1)))

  defp apply_op("stringBeginsWith", _actual, _prefixes), do: false

  defp apply_op("stringEndsWith", actual, suffixes) when actual != nil,
    do: Enum.any?(suffixes, &String.ends_with?(normalize(actual), normalize(&1)))

  defp apply_op("stringEndsWith", _actual, _suffixes), do: false

  defp apply_op("stringContains", actual, needles) when actual != nil,
    do: Enum.any?(needles, &String.contains?(normalize(actual), normalize(&1)))

  defp apply_op("stringContains", _actual, _needles), do: false

  defp apply_op(op, actual, values) when op in ~w(numberIn numberNotIn),
    do: number_cmp(op, to_number(actual), Enum.map(values, &to_number/1))

  defp apply_op(op, actual, [bound]) when op in ~w(numberLessThan numberLessThanOrEquals numberGreaterThan numberGreaterThanOrEquals),
    do: number_bound(op, to_number(actual), to_number(bound))

  defp apply_op("boolEquals", actual, [wanted]) when is_boolean(wanted),
    do: to_bool(actual) == wanted

  defp apply_op("boolEquals", _actual, _wanted), do: false

  defp apply_op(_op, _actual, _values), do: false

  defp to_bool(true), do: true
  defp to_bool(false), do: false
  defp to_bool("true"), do: true
  defp to_bool("false"), do: false
  defp to_bool(_), do: nil

  defp number_cmp(_op, nil, _nums), do: false
  defp number_cmp("numberIn", n, nums), do: n in Enum.reject(nums, &is_nil/1)
  defp number_cmp("numberNotIn", n, nums), do: n not in Enum.reject(nums, &is_nil/1)

  defp number_bound(_op, nil, _bound), do: false
  defp number_bound("numberLessThan", n, b), do: n < b
  defp number_bound("numberLessThanOrEquals", n, b), do: n <= b
  defp number_bound("numberGreaterThan", n, b), do: n > b
  defp number_bound("numberGreaterThanOrEquals", n, b), do: n >= b

  defp to_number(n) when is_number(n), do: n
  defp to_number(b) when is_binary(b) do
    case Integer.parse(b) do
      {i, ""} -> i
      _ ->
        case Float.parse(b) do
          {f, ""} -> f
          _ -> nil
        end
    end
  end

  defp to_number(_), do: nil
end
