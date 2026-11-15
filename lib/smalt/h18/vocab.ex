defmodule Smalt.H18.Vocab do
  @moduledoc "H18 named-constant vocabulary: error types and probe paths emitted by the plane face."

  def not_found_type, do: "plane_route_not_found"
  def unknown_plane_type, do: "unknown_plane"
  def health_segment, do: "healthz"
  def ready_segment, do: "readyz"
  def inventory_segment, do: "planes"
  def content_type, do: "application/json"
end
