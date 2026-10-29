defmodule PopcornDemo.LiveAcr do
  @moduledoc """
  Container Registry leg (X6, lane bench-runner) — typed UNSUPPORTED.

  Face audit (2026-10-20, repo root):
    - `lib/smalt/arm_gateway/router.ex`: 0 routes for
      `Microsoft.ContainerRegistry` provider namespaces; 0 `/v2/`
      docker-registry faces in the egress router.
    - `lib/smalt/registry.ex` / `popcorn_demo/lib/smalt/registry.ex`:
      no `Microsoft.ContainerRegistry/*` provider types.
    - Only match anywhere: the cloud-metadata envelope string
      `"containerRegistry" => "registry.smalt.local"` (dnsSuffixes block,
      router.ex ~line 3412) — a metadata dnsSuffix, not a routable face.

  Therefore `run/0` cannot exercise a registry leg and returns the typed
  skip `{:unsupported, :acr_face_absent}` — a loud skip, never a faked
  pass. If the ACR face lands in the ARM gateway or a `/v2/` docker
  registry route lands in the egress router, this module must be
  re-authored as a real leg: create registry resource → docker-style
  `GET /v2/` (expect 200) → manifest/catalog list → typed delete.
  """

  @spec run :: {:unsupported, :acr_face_absent}
  def run do
    {:unsupported, :acr_face_absent}
  end
end
