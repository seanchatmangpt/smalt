defmodule Smalt.H18.Router do
  @moduledoc """
  Plane face: `GET /planes` (inventory from `Smalt.H18.PlaneTable`),
  `GET /<plane>/healthz`, `GET /<plane>/readyz`, typed 404 for unknown planes,
  and delegation of every other `/<plane>/...` path to `Smalt.Planes.Router`.

  MOUNT (coordinator): replace `Smalt.Planes.Router` at its mount point with
  `Smalt.H18.Router` (same opts), or place it in front: `plug(Smalt.H18.Router)`.
  """
  @behaviour Plug
  import Plug.Conn
  alias Smalt.H18.{PlaneTable, Vocab}

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: "GET", path_info: [seg]} = conn, _opts) when seg == "planes" do
    json(conn, 200, %{
      "planes" => Enum.map(PlaneTable.all(), &describe/1),
      "boot_planes" => Enum.map(Smalt.Planes.known(), &Atom.to_string/1)
    })
  end

  def call(%Plug.Conn{path_info: [prefix | rest]} = conn, opts) do
    case PlaneTable.fetch(prefix) do
      nil -> unknown(conn, prefix)
      plane -> plane_call(conn, plane, rest, opts)
    end
  end

  def call(conn, _opts), do: unknown(conn, nil)

  defp plane_call(%{method: "GET"} = conn, plane, [seg], _opts) when seg in ["healthz", "readyz"] do
    ready = PlaneTable.ready?(plane)

    cond do
      seg == Vocab.health_segment() -> json(conn, 200, %{"plane" => plane.prefix, "status" => "alive"})
      ready -> json(conn, 200, %{"plane" => plane.prefix, "status" => "ready"})
      true -> json(conn, 503, %{"plane" => plane.prefix, "status" => "not_ready"})
    end
  end

  defp plane_call(conn, _plane, _rest, opts) do
    Smalt.Planes.Router.call(conn, Smalt.Planes.Router.init(opts))
  end

  defp describe(plane) do
    %{
      "prefix" => plane.prefix,
      "path" => "/" <> plane.prefix,
      "handler" => inspect(plane.module),
      "health" => "/#{plane.prefix}/#{Vocab.health_segment()}",
      "readiness" => "/#{plane.prefix}/#{Vocab.ready_segment()}",
      "ready" => PlaneTable.ready?(plane)
    }
  end

  defp unknown(conn, prefix) do
    json(conn, 404, %{
      "type" => Vocab.unknown_plane_type(),
      "plane" => prefix,
      "known" => PlaneTable.prefixes()
    })
  end

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type(Vocab.content_type())
    |> send_resp(status, Jason.encode!(body))
    |> halt()
  end
end
