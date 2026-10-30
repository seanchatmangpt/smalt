# scripts/r18-deploy/push_tags.exs — SharedKey-signed block-blob PUTs against
# the blob data plane: the emulated "docker push". The ACR emulation's tag
# face reads blob names as tags (acr_router.ex: repositories = blob containers
# of the registry-named account, tags = output of prefix_keys over
# :smalt_blobs), so landing the tag blobs IS the image-identity face.
#
# Real client work (Chicago: real collaborator, no mocks): canonical
# string-to-sign per Smalt.Auth.SharedKey (blob 2021-12-02 shape),
# HMAC-SHA256, raw :gen_tcp HTTP with byte-controlled headers so the
# signature covers exactly the bytes on the wire.
#
# Env: SMALT_BLOB_PORT (default 29445). Account/repos/tags mirror main.tf
# (local.registry / acr_repos / var.image_tag).
#
# Output: "ACR_PUSH_OK <n> tag blobs landed [...]" or "ACR_PUSH_FAULT ...".
# Exit 0 all pushes landed, 1 fault.

defmodule R18.AcrPush do
  @account "courtsmaltacr"
  @repos ["courtroom-api", "courtroom-web"]
  @tags ["338caed"]
  @version "2021-12-02"

  def run do
    key =
      case System.get_env("SMALT_BLOB_ACCOUNT_KEY") do
        k when is_binary(k) and k != "" -> Base.decode64!(k)
        _ -> :crypto.hash(:sha256, @account <> "smalt-dev-sb")
      end

    port = String.to_integer(System.get_env("SMALT_BLOB_PORT") || "29445")

    results = for repo <- @repos, tag <- @tags do
      push(key, port, repo, tag)
    end

    if Enum.all?(results, &(&1 == :ok)) do
      IO.puts("ACR_PUSH_OK #{length(results)} tag blobs landed #{inspect(results)}")
    else
      IO.puts("ACR_PUSH_FAULT #{inspect(results)}")
      System.stop(1)
    end
  end

  # Raw-TCP SharedKey PUT of one tag blob.
  defp push(key, port, repo, tag) do
    body = body(repo, tag)
    n = byte_size(body)
    httpdate = :httpd_util.rfc1123_date()

    xms =
      [
        {"x-ms-blob-type", "BlockBlob"},
        {"x-ms-date", httpdate},
        {"x-ms-version", @version}
      ]
      |> Enum.sort(fn {a, _}, {b, _} -> a <= b end)

    sts =
      Enum.join(
        [
          "PUT",
          "", # content-encoding
          "", # content-language
          to_string(n), # content-length (present, non-zero)
          "", # content-md5
          "application/octet-stream",
          "", # date (empty: x-ms-date present)
          "", # if-modified-since
          "", # if-match
          "", # if-none-match
          "", # if-unmodified-since
          "" # range
        ],
        "\n"
      )
      |> Kernel.<>("\n")
      |> Kernel.<>(Enum.map_join(xms, "", fn {k, v} -> "#{k}:#{v}\n" end))
      |> Kernel.<>("/#{@account}/#{repo}/#{tag}")

    sig = Base.encode64(:crypto.mac(:hmac, :sha256, key, sts))

    request =
      :io_lib.format(
        "PUT /#{@account}/#{repo}/#{tag} HTTP/1.1\r\n" <>
          "host: 127.0.0.1:~b\r\n" <>
          "content-type: application/octet-stream\r\n" <>
          "content-length: ~b\r\n" <>
          "x-ms-blob-type: BlockBlob\r\n" <>
          "x-ms-date: ~s\r\n" <>
          "x-ms-version: #{@version}\r\n" <>
          "authorization: SharedKey #{@account}:#{sig}\r\n" <>
          "connection: close\r\n\r\n",
        [port, n, httpdate]
      )
      |> IO.iodata_to_binary()

    {:ok, sock} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :raw, active: false], 5_000)

    :ok = :gen_tcp.send(sock, request)
    :ok = :gen_tcp.send(sock, body)

    response = recv_all(sock, <<>>)

    :ok = :gen_tcp.close(sock)

    case Regex.run(~r/HTTP\/1\.1 (\d{3})/, response) do
      [_, code] when code in ["201", "200"] ->
        IO.puts("  push #{repo}:#{tag} -> #{code}")
        :ok

      [_, code] ->
        IO.puts("  push #{repo}:#{tag} -> HTTP #{code} (FAULT)")
        :error

      nil ->
        IO.puts("  push #{repo}:#{tag} -> no HTTP status (FAULT)")
        :error
    end
  end

  defp recv_all(sock, acc) do
    case :gen_tcp.recv(sock, 0, 5_000) do
      {:ok, data} -> recv_all(sock, acc <> data)
      {:error, :closed} -> acc
      {:error, other} -> acc <> "\n[recv #{inspect(other)}]"
    end
  end

  defp body(repo, tag) do
    Jason.encode!(%{
      "schemaVersion" => 2,
      "mediaType" => "application/vnd.docker.distribution.manifest.v2+json",
      "config" => %{
        "mediaType" => "application/vnd.docker.container.image.v1+json",
        "digest" => "sha256:smalt-#{repo}-#{tag}",
        "size" => 702
      },
      "tag" => tag,
      "repo" => repo
    })
  end
end

R18.AcrPush.run()
