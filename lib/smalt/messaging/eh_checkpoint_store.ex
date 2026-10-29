defmodule Smalt.Messaging.EhCheckpointStore do
  @moduledoc """
  EventProcessorClient-style blob checkpoint store (wave-6 lane w6z).

  Implemented natively over smalt's own `Smalt.BlobStorage` (real
  collaborator, no mocks): checkpoints live as blobs under
  `eh-checkpoints/{eventhub}/{consumergroup}/{partition}` and ownership
  records under `eh-ownership/{eventhub}/{consumergroup}`, each holding a
  JSON body with the blob's `etag` as the CAS token - the same optimistic
  concurrency shape real Azure blobs give the Event Hubs SDK's
  BlobCheckpointStore.
  """

  alias Smalt.DataPlane.BlobStorage

  @account "smalt-eh"
  @ckpt_container "eh-checkpoints"
  @own_container "eh-ownership"

  # -- Checkpoints -----------------------------------------------------------

  def put_checkpoint(hub, group, partition, checkpoint, opts \\ []) do
    seq = checkpoint[:sequence_number] || checkpoint["sequence_number"]
    offset = checkpoint[:offset] || checkpoint["offset"]

    cond do
      not is_integer(seq) or seq < 0 ->
        {:error, :invalid_checkpoint}

      not is_binary(offset) or offset == "" ->
        {:error, :invalid_checkpoint}

      true ->
        ensure_containers()
        do_put(hub, group, partition, seq, offset, opts[:if_match])
    end
  end

  defp do_put(hub, group, partition, seq, offset, expected_etag) do
    body = Jason.encode!(%{"sequence_number" => seq, "offset" => offset})
    headers = if expected_etag in [nil, ""], do: %{}, else: %{"if-match" => expected_etag}

    case BlobStorage.put_blob(@account, @ckpt_container, ckpt_blob(hub, group, partition), body, headers) do
      {:ok, blob} ->
        {:ok, %{sequence_number: seq, offset: offset, etag: blob["etag"]}}

      {:error, :precondition_failed, _} ->
        {:error, :etag_mismatch}

      {:error, 400, code, msg} ->
        {:error, {:blob_refused, code, msg}}

      _ ->
        {:error, :internal}
    end
  end

  def get_checkpoint(hub, group, partition) do
    case BlobStorage.get_blob(@account, @ckpt_container, ckpt_blob(hub, group, partition)) do
      {:ok, blob} -> decode_ckpt(blob)
      :error -> {:error, :not_found}
    end
  end

  defp decode_ckpt(blob) do
    with {:ok, body} <- Jason.decode(blob["content"]),
         seq when is_integer(seq) <- body["sequence_number"],
         offset when is_binary(offset) <- body["offset"] do
      {:ok, %{sequence_number: seq, offset: offset, etag: blob["etag"]}}
    else
      _ -> {:error, :internal}
    end
  end

  def list_checkpoints(hub, group) do
    ensure_containers()
    prefix = "#{@account}/#{@ckpt_container}/#{hub}/#{group}/"

    rows =
      :smalt_blobs
      |> table_rows()
      |> Enum.filter(fn {k, _} -> String.starts_with?(k, prefix) end)
      |> Enum.map(fn {k, blob} ->
        case decode_ckpt(blob) do
          {:ok, m} ->
            partition = k |> String.slice(String.length(prefix)..-1//1)
            Map.put(m, :partition, partition)

          _ ->
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(& &1.partition)

    {:ok, rows}
  end

  # -- Ownership -------------------------------------------------------------

  def claim_ownership(hub, group, owner, opts \\ []) do
    ensure_containers()

    case BlobStorage.get_blob(@account, @own_container, own_blob(hub, group)) do
      {:ok, current} ->
        current_owner = owner_of(current)

        cond do
          current_owner == owner ->
            refresh(hub, group, owner, current)

          opts[:force] ->
            force_steal(hub, group, owner, current)

          true ->
            {:error, :owned, current_owner}
        end

      :error ->
        write_owner(hub, group, owner, nil)
    end
  end

  def list_ownership(hub) do
    ensure_containers()
    prefix = "#{@account}/#{@own_container}/#{hub}/"

    rows =
      :smalt_blobs
      |> table_rows()
      |> Enum.filter(fn {k, _} -> String.starts_with?(k, prefix) end)
      |> Enum.map(fn {k, blob} ->
        case decode_owner(blob) do
          {:ok, m} -> Map.put(m, :consumergroup, k |> String.slice(String.length(prefix)..-1//1))
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(& &1.consumergroup)

    {:ok, rows}
  end

  # -- Internals ---------------------------------------------------------------

  defp ckpt_blob(hub, group, partition), do: "#{hub}/#{group}/#{partition}"
  defp own_blob(hub, group), do: "#{hub}/#{group}"

  # Default-immutable container class (pinned, docs/jira/v26.10.16
  # sdk-results/ts-storage-blob.md): create with the explicit opt-out so
  # checkpoint CAS overwrites are not worm-blocked.
  defp ensure_containers do
    BlobStorage.create_container(@account, @ckpt_container, %{"immutable" => false})
    BlobStorage.create_container(@account, @own_container, %{"immutable" => false})
    :ok
  end

  defp owner_of(blob) do
    case Jason.decode(blob["content"]) do
      {:ok, %{"owner" => o}} when is_binary(o) -> o
      _ -> nil
    end
  end

  defp decode_owner(blob) do
    case owner_of(blob) do
      o when is_binary(o) -> {:ok, %{owner: o, etag: blob["etag"]}}
      _ -> {:error, :internal}
    end
  end

  defp refresh(hub, group, owner, current) do
    case write_owner(hub, group, owner, current["etag"]) do
      {:ok, m} -> {:ok, m}
      {:error, :etag_mismatch} -> {:error, :owned, owner_of(current)}
      other -> other
    end
  end

  defp force_steal(hub, group, owner, current) do
    case write_owner(hub, group, owner, current["etag"]) do
      {:ok, m} -> {:ok, Map.put(m, :stole_from, owner_of(current))}
      {:error, :etag_mismatch} -> {:error, :owned, owner_of(current)}
      other -> other
    end
  end

  defp write_owner(hub, group, owner, expected_etag) do
    body = Jason.encode!(%{"owner" => owner})
    headers = if expected_etag in [nil, ""], do: %{}, else: %{"if-match" => expected_etag}

    case BlobStorage.put_blob(@account, @own_container, own_blob(hub, group), body, headers) do
      {:ok, blob} -> {:ok, %{owner: owner, etag: blob["etag"]}}
      {:error, :precondition_failed, _} -> {:error, :etag_mismatch}
      _ -> {:error, :internal}
    end
  end

  defp table_rows(table) do
    if :ets.info(table) == :undefined do
      []
    else
      :ets.tab2list(table)
    end
  end
end
