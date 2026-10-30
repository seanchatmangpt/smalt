defmodule Smalt.DataPlane.KeyVault.Certificates do
  @moduledoc """
  Key Vault certificates face: the ONE canonical SMALT-KVB1 backup envelope
  codec shared across keys and certificates (kind-tagged bundles). Consumed
  by `Smalt.DataPlane.Certificates` (the certificate backup/restore routes
  ride `KeyVaultActions.kv_backup_encode/decode`, which delegate here) and by
  `Smalt.DataPlane.KeyVault.Keys` for key backup/restore.
  """

  alias Smalt.DataPlane.KeyVault.Keys

  @backup_magic "SMALT-KVB1"

  # Shared envelope codec (kind-tagged so certificates ride the same shape).
  # Public cross-module seam (@doc false): Certificates reuses this codec so
  # there is ONE canonical SMALT-KVB1 envelope across keys/certificates.
  @doc false
  @spec kv_backup_encode(map()) :: binary()
  def kv_backup_encode(bundle), do: encode_backup(bundle)

  @doc false
  @spec kv_backup_decode(binary(), binary()) :: {:ok, map()} | {:error, 400, map()}
  def kv_backup_decode(blob, kind), do: decode_backup(blob, kind)

  defp encode_backup(bundle) do
    envelope = %{"checksum" => bundle_checksum(bundle), "bundle" => bundle}
    @backup_magic <> "." <> Base.encode64(Jason.encode!(envelope))
  end

  defp decode_backup(blob, kind) do
    with {:ok, _magic, json} <- split_magic(blob),
         {:ok, envelope} <- Smalt.JsonCompat.decode(json) do
      checksum = envelope["checksum"]
      bundle = envelope["bundle"]

      cond do
        not is_map(bundle) or is_nil(checksum) ->
          {:error, 400,
           Keys.bad_request(
             "MalformedBackupBlob",
             "backup blob is missing checksum or bundle fields"
           )}

        bundle_checksum(bundle) != checksum ->
          {:error, 400,
           Keys.bad_request(
             "MalformedBackupBlob",
             "backup blob checksum mismatch (tampered or truncated)"
           )}

        bundle["kind"] != kind ->
          {:error, 400,
           Keys.bad_request("MalformedBackupBlob", "backup blob kind mismatch (got #{inspect(bundle["kind"])}, want #{kind})")}

        true ->
          {:ok, bundle}
      end
    else
      {:error, :magic} ->
        {:error, 400, Keys.bad_request("MalformedBackupBlob", "backup blob magic prefix mismatch (not a SMALT-KVB1 blob)")}

      {:error, reason} ->
        {:error, 400,
         Keys.bad_request("MalformedBackupBlob", "backup blob is not base64-encoded JSON (#{inspect(reason)})")}
    end
  end

  defp split_magic(blob) do
    case :binary.split(blob, ".") do
      [@backup_magic, b64] ->
        case Base.decode64(b64) do
          {:ok, json} -> {:ok, @backup_magic, json}
          :error -> {:error, :base64}
        end

      _ ->
        {:error, :magic}
    end
  end

  defp bundle_checksum(bundle) do
    :crypto.hash(:sha256, Jason.encode!(bundle))
    |> Base.encode16(case: :lower)
  end
end
