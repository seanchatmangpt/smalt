# BK-JUSTK — kind/swarm Justfile recipes (v26.10.22)

Standing: PARTIAL_ALIVE. Context: solo.

Module `justfile.d/52-kind.just` (landed via tick checkpoint 05ff07b2; repaired
in-flight by co-lane BK-JUSTK2, whose version is canonical). Root import
`import 'justfile.d/52-kind.just'` present; module parses clean.

## Verified (real output)

1. **`just --list`**: 10 kind*/swarm* recipes listed, exit 0 (excerpt):
   `kind-console kind-deploy kind-deploy-console kind-down kind-images
   kind-status kind-up swarm-status swarm-up` (all present).
2. **Prereq fail-closed (exit 3)**:
   `env PATH=/usr/bin:/bin just _check_kind_tools` ->
   `[KIND-PREREQ-FAIL] tool not on PATH: kind — install: brew install kind`,
   `error: recipe _check_kind_tools failed ... exit code 3`.
3. **`just kind-up`**: cluster created (`kind-smalt-control-plane Ready
   v1.34.0`); idempotent re-run: `[KIND-UP] cluster ... already exists —
   idempotent no-op`, exit 0. `just kind-status`: nodes + swarm surface
   report, exit 0.
4. **`just kind-images` — typed BLOCKED at HEAD (fail-closed, exit 1)**:
   `#32 0.411 ** (Mix) You're trying to run :smalt on Elixir v1.19.5 but it
   has declared in its mix.exs file it supports only Elixir ~> 1.20`
   -> `[KIND-IMAGES-FAIL] docker build failed: docker/Dockerfile.hermetic ->
   smalt:hermetic`. Root cause: both docker/Dockerfile{,.hermetic} pin the
   1.19.5 base while mix.exs moved to `~> 1.20` in bb26c6b6 (2026-10-21).
   Pre-existing defect, owner lane BK-IMG. Full log: tmp/kind-images-run4.log.
   Side witness: docker host enospc, reclaimed 3.4 GiB build cache
   (`docker builder prune`; no tagged images touched).
5. **`just kind-deploy`**: applied `k8s/smalt-backend.yaml` (cookie Secret
   seeded first). First wait failed fail-closed (exit 1): manifest pins
   `image: smalt:local` + `imagePullPolicy: Never`; `kind load` of the 7.4 GiB
   smalt:local hit node-disk enospc (node 95% full, 54G/59G). Typed
   remediation: publish the slim hermetic runtime image (BK-IMG).
6. **Live swarm witness (real, degraded subject disclosed)**: the cluster's
   running swarm is co-lane's `smalt-swarm` StatefulSet (2 pods, image
   `smalt-hermetic:v261019`, `-name smalt@<pod>.smalt-swarm-headless.default.svc.cluster.local`,
   cookie `bkswarm-cookie`, dist port pin 9000-9009). Hidden-node `erl` probe
   (script in pods, tmp/kind/probe.sh):
   `PROBE smalt-swarm-0 -> smalt-swarm-1 : pong`
   `PROBE smalt-swarm-1 -> smalt-swarm-0 : pong`
   Bidirectional net_adm:ping pong/pong — the Erlang swarm is ALIVE on kind.

## Witness-channel finding (for the next lane)

`bin/smalt eval` boots a nonode (always pang) and `bin/smalt rpc` returns
`:noconnection` against these VMs — neither is a valid swarm-witness channel.
Lawful channel: hidden-node `erl` reusing the release boot
(`-boot_var RELEASE_LIB /app/_release/lib -boot releases/<v>/start -name
probe@<pod> -setcookie <cookie>`); a cosmetic `:eaddrinuse` from the probe's
app-start is expected noise.

## Disclosures

1. Co-tenancy: module file, kind cluster, and shared kubeconfig were
   concurrently mutated by lanes BK-JUSTK2/BK-K8SM/BK-BKSWARM; my smalt-backend
   image override was reverted in-flight by a concurrent re-apply. No git
   commands run beyond read-only inspection; coordinator owns git.
2. Degraded subject: live swarm runs smalt-hermetic:v261019 (pre-1.20 bump).
   Close condition for PARTIAL_ALIVE: BK-IMG lands the 1.20 base pin and
   `just kind-images` exits 0, then kind-deploy/swarm-status run on a HEAD
   subject.
