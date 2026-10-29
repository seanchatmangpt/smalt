# r17 — T-10: Container Instances control plane (execution out-of-scope)

- window: v26.10.28 · ticket: `tickets/T10-container-instances-control-plane.md` · date: 2026-10-29
- tier: beam (`test/integration/container_groups_test.exs`) · status: **CODE-COMPLETE (r17), awaiting integration run**

## landed

1. **ARM `Microsoft.ContainerInstance/containerGroups` CRUD** — engine
   `lib/smalt/data_plane/container_groups.ex` (rows in `:smalt_resources`,
   downcased full ARM ids, providers segment included) + pass-through plug
   `lib/smalt/arm_gateway/providers/container_groups_router.ex`. PUT
   validates the real containerGroup schema BEFORE any store write (typed
   400s: `InvalidRequestContent` for undecodable/non-map bodies,
   `InvalidParameter` with an ARM `target` path for containers array,
   container name, image, `resources.requests` cpu/memoryInGB, port ranges
   and TCP/UDP protocols, probe handlers exec/httpGet/tcpSocket + non-
   negative timings, osType, restartPolicy, ipAddress type + at-least-one
   port); create is 201 and the idempotent re-PUT is 200. GET renders the
   simulated control-plane-only lifecycle — `provisioningState: Succeeded`,
   `instanceView.state: Running`, every container's
   `containerStatus.currentState.state: Running` from the recorded start —
   echoes the developer's IP/port shape (a deterministic `10.96.a.b` is
   synthesized when no `ip` was pinned, as real ACI assigns one at
   provision), and never echoes credential secrets. LIST answers the ARM
   list envelope (value + nextLink, page size 100, `$skip`/`maxitempages`
   — the main router's law) at BOTH scopes: RG and subscription (`az
   container list`). DELETE is the ARM LRO face: record + child-key cascade
   removed, then 202 + Location + Retry-After through
   `Smalt.ArmGateway.LRO` (Sweeper-driven terminal, `az container delete`
   completes). api-version is gated against the real ACI ladder carried by
   the engine (`MissingApiVersionParameter` / `InvalidApiVersionParameter`
   naming the latest 2024-03-01) — the type has no Registry map row (the
   ticket's evidence), so the plug pins the ladder itself. Segment casing
   is matched case-insensitively; wire ids keep the client's casing. Any
   deeper unknown shape under the containerGroups subtree is owned too
   (typed 404, never a fall-through to the main router's unadmitted-type
   machinery); anything else returns the conn UNCHANGED.

2. **Logs: typed, honest refusal** — the `containers/<name>/logs` action
   answers the `NotSupportedOnSubstrate` constant
   (`ContainerGroups.logs_refusal_code/0`, rendered verbatim as the ARM
   error envelope): execution is not emulated by this substrate, the group
   never ran the container, and no log stream exists to read — none is ever
   fabricated (design-law permanent non-goal, fail-closed). A missing
   group/container is an honest 404 ResourceNotFound, never a
   refusal-shaped guess.

3. **`imageRegistryCredentials` validated at PUT time (T-01 seam)** — each
   credential's server resolves through
   `ContainerGroups.registry_row/1` to a real ACR control-plane row keyed
   `.../providers/Microsoft.ContainerRegistry/registries/<name>` in
   `:smalt_resources` (`myreg.azurecr.io` -> `myreg`, suffix regex);
   unknown server -> typed 400 `InaccessibleImageRegistry` naming the
   missing store row (the same failure a developer sees pointing
   `az container create` at a registry that does not exist); malformed
   credentials (missing server/username) -> 400
   `InvalidImageRegistryCredentialFormat`. Where the registry row publishes
   keys and the credential carries a password, the key must be one of its
   keys (ticket scope clause); rows without published keys admit on
   existence (T-01 may not land its key listing first). Refusals leave
   nothing stored.

File scope: exactly the three NEW files above (engine, pass-through plug,
court) + this receipt + the ticket stamp. `lib/smalt/arm_gateway/router.ex`
and `parity/` untouched — the mux wiring is the integrator's one-liner:

## wiring (EXACT patch, integrator applies — one plug line, mounted before :match)

```diff
--- a/lib/smalt/arm_gateway/router.ex
+++ b/lib/smalt/arm_gateway/router.ex
@@
   plug(Smalt.Egress.ThrottlePlug)
+  plug(Smalt.ArmGateway.Providers.ContainerGroupsRouter) # T-10 (r17): Microsoft.ContainerInstance containerGroups control plane pass-through (answers via Smalt.DataPlane.ContainerGroups; conn unchanged otherwise)
   plug(:match)
   plug(:dispatch)
```

Mount position is load-bearing: AFTER `Plug.Parsers` (body_params decoded /
body consumed — the plug's body seam dual-modes on `conn.body_params` vs a
raw read) and BEFORE `:match` so the main router never sees an owned shape.
Until integrated, the court dispatches the plug directly in-process — the
same Plug.Test discipline as `sb_arm_rules_test.exs` — so it stays green
before and after the line lands.

## court

`Smalt.Internal.ContainerGroupsTest` (in-process Plug.Test against
`ContainerGroupsRouter`, real `:smalt_resources` + `:smalt_operations`
rows, no mocks) — 7 tests:

1. PUT valid group 201 -> idempotent re-PUT 200 (plus a mixed-casing PUT
   leg) -> GET shape: provisioningState Succeeded, instanceView.state
   Running, containerStatus.currentState Running with a recorded start,
   echoed IP/port + container schema (image/resources/ports/probe),
   credentials echoed WITHOUT the secret.
2. PUT unknown registry credential -> 400 InaccessibleImageRegistry with
   target `properties.imageRegistryCredentials[0]`, nothing stored (GET
   404); credential against the seeded ACR row admits (201) — the store
   read is real.
3. LIST paginates: RG-scope value membership, NO fabricated nextLink on a
   complete page, `$skip=1` window drops the first record in deterministic
   store-key order, subscription-scope list surfaces the same groups.
4. DELETE 202 with Location (`/operations/`) + Retry-After 1 -> the op
   reads terminal Succeeded via `Smalt.ArmGateway.LRO.get_op/1` with the
   deleted group's resourceId -> GET 404 ResourceNotFound -> DELETE of the
   unknown group 404.
5. logs action -> 400 `NotSupportedOnSubstrate` (== the engine constant),
   target `containers/<name>/logs`, message names the non-emulation and
   the never-fabricated law, NO "content" member on the wire; unknown
   container -> honest 404.
6. Schema refusals: missing containers / missing image / port 0 /
   handler-less probe each 400 InvalidParameter with the exact ARM target
   path; missing api-version -> 400 MissingApiVersionParameter.
7. Pass-through law: foreign provider shapes (ServiceBus namespace paths)
   return the conn UNCHANGED (structural identity); an owned shape with an
   unsupported method answers typed 405 MethodNotAllowed (never falls
   through).

**Not yet executed** — r17 is code-only per the compile-freeze SLA (no
mix/test/git in this pass); the court runs with the next integration pass
and this receipt + the ticket stamp say so.

## DoD mapping (the Azure developer's view)

- "`az container create` (or the ARM SDK PUT) accepts a real
  container-group body" -> court 1 + 6 (schema validated, 201/200, typed
  refusals before any store write).
- "`az container show` returns the group with Running state and your
  IP/port shape" -> court 1 (Succeeded + instanceView Running + echoed
  IP/port, synthesized substrate ip when unpinned).
- "`az container list` paginates" -> court 3 (both scopes, $skip window,
  nextLink machinery).
- "`az container delete` completes its LRO" -> court 4 (202 + Location +
  Retry-After, op terminal Succeeded, record gone).
- "Pointing imageRegistryCredentials at a registry that does not exist
  fails at PUT with the same validation error Azure gives" -> court 2
  (400 InaccessibleImageRegistry — ACI's documented vocabulary; disclosed
  divergence: real Azure surfaces registry reachability during the async
  deployment, smalt pins the same typed code at the synchronous PUT
  validation, fail-closed).
- "If you ask for logs, you get a clear typed error saying execution is
  not emulated — never a fabricated log stream" -> court 5
  (NotSupportedOnSubstrate, no content member, permanent non-goal).

## notes

- **Execution stays out of scope by design law** (README: no container
  runtime, no host configuration for the native tier; this box has no
  Docker): nothing here runs, pulls, or streams — the DoD is honest about
  the simulated lifecycle faces it does serve.
- **api-version ladder pinned on the engine** (real ACI swagger releases
  2018-10-01 .. 2024-03-01) because `Smalt.Registry` carries no
  Microsoft.ContainerInstance map row (ticket evidence); when a future lane
  admits the type into the Registry, `check_api_version/1` can re-point at
  `Registry.latest_version/1` without wire changes.
- **ipAddress.ip synthesis** is deterministic (`phash2` of the group name,
  10.96.0.0/16) so repeated GETs are stable and refresh-only plans don't
  drift — a fabricated-but-stable substrate face, unlike logs which are
  never fabricated at all (that asymmetry is the design law, not an
  oversight).
- Registry-credential validation reads only generic store rows — no T-01
  module dependency; when T-01 lands registries/listKeys the same lookup
  keeps working (key membership already enforced for rows that publish
  keys).
