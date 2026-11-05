defmodule Smalt.Aoq.Quic.Certs do
  @moduledoc """
  PEM-to-DER for the AoQ QUIC TLS face (v26.11.6 LANE-4).

  Pure binary pattern-match + Base64: no `:public_key` dependency, no
  openssl subprocess. Takes the FIRST `-----BEGIN ...-----` /
  `-----END ...-----` span in the file (the leaf in a chain PEM).
  A missing/corrupted block answers a typed refusal, fail-closed.
  """

  @typedoc "Refusal: typed, never a raise."
  @type refusal :: {:error, {:cert_refusal, reason :: term}}

  @doc "Extracts the first PEM block as raw DER."
  @spec pem_to_der(binary()) :: {:ok, binary()} | refusal()
  def pem_to_der(pem) when is_binary(pem) do
    case pem_body(pem) do
      {:ok, body} ->
        case Base.decode64(body, ignore: :whitespace) do
          {:ok, der} -> {:ok, der}
          :error -> {:error, {:cert_refusal, :pem_body_not_base64}}
        end

      refusal ->
        refusal
    end
  end

  def pem_to_der(_), do: {:error, {:cert_refusal, :pem_not_a_binary}}

  @doc "Reads `path`, extracts the first PEM block as DER."
  @spec pem_to_der!(String.t() | charlist()) :: {:ok, binary()} | refusal()
  def pem_to_der!(path) do
    case File.read(path) do
      {:ok, pem} -> pem_to_der(pem)
      {:error, reason} -> {:error, {:cert_refusal, {:pem_read_failed, reason}}}
    end
  end

  # DER = bytes after the BEGIN marker line, up to the END marker.
  defp pem_body(pem) do
    case :binary.split(pem, "-----BEGIN ") do
      [_ | [rest]] ->
        case :binary.split(rest, "-----") do
          [_ | [after_label]] ->
            case :binary.split(after_label, "-----END") do
              [b64, _] -> {:ok, b64}
              [_] -> {:error, {:cert_refusal, :unterminated_block}}
            end

          _ ->
            {:error, {:cert_refusal, :unterminated_begin_marker}}
        end

      _ ->
        {:error, {:cert_refusal, :no_pem_block}}
    end
  end
end
