defmodule Smalt.Azure.KvCertificates do
  @moduledoc """
  Key Vault certificates parity gaps (mirrors arcus AX1 kvcerts): policy
  get/update, attribute update, import, and version listing, layered over the
  real `Smalt.DataPlane.Certificates` store row (same heir'd ETS table).
  Returns the `{:ok, status, body}` / `{:error, status, body}` seam tuples.
  """

  alias Smalt.DataPlane.Certificates
  alias Smalt.Store

  @table :smalt_vault_certificates

  @spec get_policy(binary) :: {:ok, 200, map} | {:error, 404, map}
  def get_policy(name) do
    with {:ok, 200, rec} <- Certificates.get(name), do: {:ok, 200, rec["policy"]}
  end

  @spec update_policy(binary, map) :: {:ok, 200, map} | {:error, 404, map}
  def update_policy(name, body) when is_map(body) do
    with {:ok, 200, rec} <- Certificates.get(name) do
      now = System.system_time(:second)
      x509 = Map.merge(rec["policy"]["x509_props"], Map.get(body, "x509_props", %{}))

      policy =
        rec["policy"]
        |> Map.put("x509_props", x509)
        |> put_in(["attributes", "updated"], now)

      Store.put(@table, name, Map.put(rec, "policy", policy))
      {:ok, 200, policy}
    end
  end

  @spec update_attributes(binary, map) :: {:ok, 200, map} | {:error, 404, map}
  def update_attributes(name, body) when is_map(body) do
    with {:ok, 200, rec} <- Certificates.get(name) do
      attrs =
        rec["attributes"]
        |> Map.merge(Map.take(Map.get(body, "attributes", %{}), ["enabled"]))
        |> Map.put("updated", System.system_time(:second))

      new = Map.put(rec, "attributes", attrs)
      Store.put(@table, name, new)
      {:ok, 200, new}
    end
  end

  @doc "Import a base64 DER certificate (`value`); 400 on undecodable input, 409 on existing name."
  @spec import(binary, binary, map) :: {:ok, 201, map} | {:error, 400 | 409, map}
  def import(name, host, %{"value" => value}) when is_binary(value) do
    Certificates.ensure_table()

    with {:ok, der} <- Base.decode64(value),
         {:ok, nb, na} <- validity(der) do
      now = System.system_time(:second)
      id = "https://#{host}:8443/certificates/#{name}"

      rec = %{
        "id" => id,
        "name" => name,
        "cer" => Base.encode64(der),
        "attributes" => %{
          "enabled" => true, "created" => now, "updated" => now,
          "nbf" => nb, "exp" => na, "recoveryLevel" => "Purgeable"
        },
        "policy" => %{
          "id" => id <> "/policy",
          "x509_props" => %{},
          "attributes" => %{"created" => now, "updated" => now, "recoveryLevel" => "Purgeable"}
        }
      }

      if :ets.insert_new(@table, {name, rec}) do
        {:ok, 201, rec}
      else
        {:error, 409, err("CertificateNameAlreadyExists")}
      end
    else
      _ -> {:error, 400, err("BadParameter")}
    end
  end

  def import(_name, _host, _body), do: {:error, 400, err("BadParameter")}

  @doc "Single-version listing (this store keeps one version per name)."
  @spec list_versions(binary) :: {:ok, 200, map} | {:error, 404, map}
  def list_versions(name) do
    with {:ok, 200, rec} <- Certificates.get(name) do
      {:ok, 200,
       %{"value" => [%{"id" => rec["id"] <> "/v1", "attributes" => rec["attributes"]}]}}
    end
  end

  defp validity(der) do
    cert = :public_key.pkix_decode_cert(der, :otp)
    {:Validity, nb, na} = elem(elem(cert, 1), 5)
    {:ok, to_unix(nb), to_unix(na)}
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp to_unix({_, t}), do: to_unix(t)

  defp to_unix(t) do
    s = List.to_string(t)

    {y, rest} =
      case byte_size(s) do
        13 ->
          <<yy::binary-2, r::binary>> = s
          y = String.to_integer(yy)
          {if(y >= 50, do: 1900 + y, else: 2000 + y), r}

        _ ->
          <<yyyy::binary-4, r::binary>> = s
          {String.to_integer(yyyy), r}
      end

    <<mo::binary-2, d::binary-2, h::binary-2, mi::binary-2, se::binary-2, _::binary>> = rest

    :calendar.datetime_to_gregorian_seconds(
      {{y, String.to_integer(mo), String.to_integer(d)},
       {String.to_integer(h), String.to_integer(mi), String.to_integer(se)}}
    ) - 62_167_219_200
  end

  defp err(code), do: %{"error" => %{"code" => code, "message" => code}}
end
