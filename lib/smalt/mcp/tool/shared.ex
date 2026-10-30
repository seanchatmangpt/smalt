defmodule Smalt.Mcp.Tool.Shared do
  @moduledoc """
  Cross-family helpers for the MCP tool families (`Smalt.Mcp.Tool.*`).

  The tool surface itself is defined by the generated
  `Smalt.Mcp.Descriptor` (projected from
  `lib/smalt/mcp/gen/smalt_mcp_surface.ttl`); families reference that TTL
  surface, they never redefine it — the drift fence
  (test/internal/mcpt1_dispatch_court_test.exs) pins
  length(Descriptor.capabilities()) to the TTL capabilityId count.
  """

  @doc "Default subscription id used by ARM-scope reads (was Router default_subscription/0)."
  @spec default_subscription() :: String.t()
  def default_subscription, do: "00000000-0000-0000-0000-000000000000"
end
