defmodule Smalt.GCP.Router do
  @moduledoc """
  Host-based GCP dialect router. `dialect/1` maps a Host header to a dialect;
  as a Plug, non-GCP hosts pass through untouched (Azure ARM stays default).
  """
  @behaviour Plug
  alias Smalt.GCP.{Identity, IAM}

  def dialect(host) when is_binary(host) do
    case host |> String.split(":") |> hd() |> String.downcase() do
      "oauth2.googleapis.com" -> :oauth2
      "iam.googleapis.com" -> :iam
      "cloudresourcemanager.googleapis.com" -> :crm
      "metadata.google.internal" -> :metadata
      "169.254.169.254" -> :metadata
      _ -> :none
    end
  end

  def init(o), do: o

  def call(conn, _) do
    case dialect(conn.host) do
      :none -> conn
      d -> route(d, conn, conn.path_info) |> Plug.Conn.halt()
    end
  end

  defp route(:oauth2, conn, ["token"]), do: Identity.token(conn)
  defp route(:oauth2, conn, ["tokeninfo"]), do: Identity.tokeninfo(conn)
  defp route(:oauth2, conn, ["v3", "tokeninfo"]), do: Identity.tokeninfo(conn)
  defp route(:metadata, conn, segs), do: Identity.metadata(Plug.Conn.fetch_query_params(conn), segs)
  defp route(d, conn, segs) when d in [:iam, :crm] do
    conn = Plug.Conn.fetch_query_params(conn)

    case Identity.verify(bearer(conn)) do
      {:ok, _} -> IAM.serve(parse(conn), d, segs)
      _ -> IAM.err(conn, 401, "UNAUTHENTICATED", "Request had invalid authentication credentials.")
    end
  end

  defp route(_, conn, _), do: IAM.err(conn, 404, "NOT_FOUND", "Method not found.")

  defp bearer(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> t] -> t
      _ -> ""
    end
  end

  defp parse(%{body_params: %Plug.Conn.Unfetched{}} = conn) do
    Plug.Parsers.call(conn, Plug.Parsers.init(parsers: [:json], json_decoder: Jason, pass: ["*/*"]))
  end

  defp parse(conn), do: conn
end
