defmodule Smalt.AWS.SecretsManager do
  @moduledoc """
  Secrets Manager core (AS3). Versions carry stage labels; PutSecretValue moves
  AWSCURRENT to the new version and demotes the prior holder to AWSPREVIOUS.
  Delete is soft (recovery window, RestoreSecret undoes) unless
  ForceDeleteWithoutRecovery. Pure functions over a state map + Agent wrapper.
  """
  use Agent
  @acct "000000000000"

  def start_link(opts), do: Agent.start_link(fn -> %{} end, name: Keyword.get(opts, :name, __MODULE__))
  def child_spec(opts), do: %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}

  def call(s, fun, args), do: Agent.get_and_update(s, fn st -> apply(__MODULE__, fun, [st | args]) end)

  def create(st, region, p) do
    name = p["Name"]
    cond do
      not is_binary(name) or name == "" -> {{:error, "InvalidParameterException", "Name required"}, st}
      match?(%{^name => %{deleted: nil}}, st) -> {{:error, "ResourceExistsException", "The operation failed because the secret #{name} already exists."}, st}
      match?(%{^name => _}, st) -> {{:error, "InvalidRequestException", "You can't create this secret because a secret with this name is already scheduled for deletion."}, st}
      true ->
        arn = "arn:aws:secretsmanager:#{region}:#{@acct}:secret:#{name}-#{suffix()}"
        sec = %{arn: arn, name: name, description: p["Description"], versions: %{}, deleted: nil, created: now()}
        {sec, vid} = put_version(sec, p, p["ClientRequestToken"])
        {{:ok, %{"ARN" => arn, "Name" => name, "VersionId" => vid}}, Map.put(st, name, sec)}
    end
  end

  def put_value(st, p) do
    with {:ok, sec} <- fetch(st, p["SecretId"]) do
      {sec2, vid} = put_version(sec, p, p["ClientRequestToken"])
      {{:ok, %{"ARN" => sec.arn, "Name" => sec.name, "VersionId" => vid, "VersionStages" => sec2.versions[vid].stages}}, Map.put(st, sec.name, sec2)}
    else
      e -> {e, st}
    end
  end

  def get_value(st, p) do
    with {:ok, sec} <- fetch(st, p["SecretId"]),
         :ok <- if(sec.deleted, do: {:error, "InvalidRequestException", "You can't perform this operation on the secret because it was marked for deletion."}, else: :ok),
         {:ok, vid, v} <- pick(sec, p["VersionId"], p["VersionStage"] || "AWSCURRENT") do
      base = %{"ARN" => sec.arn, "Name" => sec.name, "VersionId" => vid, "VersionStages" => v.stages, "CreatedDate" => v.created}
      {{:ok, Map.merge(base, v.value)}, st}
    else
      e -> {e, st}
    end
  end

  def describe(st, p) do
    case fetch(st, p["SecretId"]) do
      {:ok, sec} ->
        vs = Map.new(sec.versions, fn {id, v} -> {id, v.stages} end)
        d = %{"ARN" => sec.arn, "Name" => sec.name, "Description" => sec.description, "VersionIdsToStages" => vs, "CreatedDate" => sec.created}
        d = if sec.deleted, do: Map.put(d, "DeletedDate", sec.deleted), else: d
        {{:ok, d}, st}
      e -> {e, st}
    end
  end

  def delete(st, p) do
    with {:ok, sec} <- fetch(st, p["SecretId"]) do
      res = %{"ARN" => sec.arn, "Name" => sec.name, "DeletionDate" => now()}
      if p["ForceDeleteWithoutRecovery"] == true, do: {{:ok, res}, Map.delete(st, sec.name)}, else: {{:ok, res}, Map.put(st, sec.name, %{sec | deleted: now()})}
    else
      e -> {e, st}
    end
  end

  def restore(st, p) do
    with {:ok, sec} <- fetch(st, p["SecretId"]) do
      {{:ok, %{"ARN" => sec.arn, "Name" => sec.name}}, Map.put(st, sec.name, %{sec | deleted: nil})}
    else
      e -> {e, st}
    end
  end

  def list(st, _p) do
    {{:ok, %{"SecretList" => for({_, s} <- Enum.sort(st), is_nil(s.deleted), do: %{"ARN" => s.arn, "Name" => s.name})}}, st}
  end

  defp fetch(st, id) do
    found = Map.get(st, id) || Enum.find_value(st, fn {_, s} -> if s.arn == id, do: s end)
    if found, do: {:ok, found}, else: {:error, "ResourceNotFoundException", "Secrets Manager can't find the specified secret."}
  end

  defp put_version(sec, p, token) do
    vid = token || uuid()
    value = if p["SecretString"], do: %{"SecretString" => p["SecretString"]}, else: %{"SecretBinary" => p["SecretBinary"]}
    # prior AWSCURRENT holder becomes AWSPREVIOUS; any older AWSPREVIOUS label drops
    versions =
      Map.new(sec.versions, fn {id, v} ->
        rest = v.stages -- ["AWSCURRENT", "AWSPREVIOUS"]
        stages = if "AWSCURRENT" in v.stages and id != vid, do: ["AWSPREVIOUS" | rest], else: rest
        {id, %{v | stages: stages}}
      end)

    {%{sec | versions: Map.put(versions, vid, %{value: value, stages: ["AWSCURRENT"], created: now()})}, vid}
  end

  defp pick(sec, vid, _stage) when is_binary(vid) do
    case sec.versions do
      %{^vid => v} -> {:ok, vid, v}
      _ -> {:error, "ResourceNotFoundException", "Secrets Manager can't find the specified secret value for VersionId: #{vid}"}
    end
  end

  defp pick(sec, _, stage) do
    case Enum.find(sec.versions, fn {_, v} -> stage in v.stages end) do
      {id, v} -> {:ok, id, v}
      nil -> {:error, "ResourceNotFoundException", "Secrets Manager can't find the specified secret value for VersionStage: #{stage}"}
    end
  end

  defp now, do: System.system_time(:millisecond) / 1000
  defp suffix, do: :crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower)
  defp uuid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
    :io_lib.format("~8.16.0b-~4.16.0b-4~3.16.0b-~4.16.0b-~12.16.0b", [a, b, Bitwise.band(c, 0x0FFF), Bitwise.bor(Bitwise.band(d, 0x3FFF), 0x8000), e]) |> IO.iodata_to_binary()
  end
end
