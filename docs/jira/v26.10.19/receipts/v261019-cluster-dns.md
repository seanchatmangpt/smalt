# Receipt: v261019-cluster-dns — Smalt.Cluster native DNS interconnect

- **Date**: 2026-10-19
- **Lane**: lane-clu (cluster interconnect, phase 4)
- **Subject**: `lib/smalt/cluster.ex` (NEW), `test/cluster/cluster_test.exs` (NEW, disclosed seam move — see Deviations)
- **Standing**: ALIVE
- **Context**: solo

## What landed

`Smalt.Cluster` — stdlib-only (no libcluster; none in mix.exs deps) GenServer
DNS poller:

- Config `config :smalt, :cluster` with `enabled: false` default — solo boot
  is byte-identical: nothing starts, and `start_link` REFUSES when disabled
  (raise ArgumentError in init), so an accidental wiring cannot silently
  half-enable. Requires `dns_name` when enabled.
- DNS A-record polling via `:inet.gethostbyname/3` (BEAM resolver reads
  `/etcresolve.conf`; hosts-table fallback covers `localhost`). NOTE:
  `:inet_res.resolve/3` was tried first but `:inet_rr` record module does not
  exist on this OTP — `gethostbyname` is the shipped path.
- `Node.connect/1` per resolved address with a bounded reconnect budget
  (`max_retries`, default 3) per address; an exhausted address is dropped
  until it leaves the DNS answer set (re-resolution is the retry, not a
  clock — no sleeps; poll pacing is `Process.send_after` scheduling).
- `Smalt.Cluster.cluster_status/0` module API (enabled/self/nodes/joined/
  dns_name/port/exhausted/last_error) for the adaptive-probe lane; endpoint
  wiring is another lane's surface (module API only per dispatch).
- Poller is NOT added to the supervision tree by this lane — wiring into
  `Smalt.Application` children is the coordinator's call, gated on
  `enabled: true` config, keeping the default boot byte-identical.

## Verification (real output)

```
$ MIX_BUILD_ROOT=_build-lane-clu mix test test/internal/ test/cluster/
...
Finished in 2.2 seconds (0.1s async, 2.1s sync)
24 tests, 0 failures
```

### 2-node witness transcript (real)

```
$ MIX_BUILD_ROOT=_build-lane-clu mix run --no-start /tmp/cluster_witness.exs
EXIT=0
[WITNESS] main node = smalt_clu_main@127.0.0.1 cookie=:LVHPIHQZTIUUZWHIYLNO
[WITNESS] peer started: :"smalt_wit@127.0.0.1" (pid #PID<0.283.0>)
[WITNESS] Smalt.Cluster started (enabled, dns_name=localhost, poll_ms=200)
[STATUS] joined=1 nodes=[:"smalt_wit@127.0.0.1"] last_error=nil
[WITNESS] JOINED: [:"smalt_wit@127.0.0.1"]
[WITNESS] peer lists back: [:"smalt_clu_main@127.0.0.1"]
[WITNESS] budget burned: exhausted=[{127, 0, 0, 1}] last_error={:connect_failed, :"smalt_nobody@127.0.0.1"}
```

(Transcript embedded verbatim from the run above; test transcript excerpt —
4/4 cluster tests passed in the 24-test run including the real-`:peer`
two-node join and budget-burn assertions.)

## Deviations (disclosed)

1. **Seam move**: the dispatch named `test/internal/` as the regression gate,
   but `_LANES.md` assigns `test/internal/**` exclusively to WO-10 whose
   population fence pins "exactly the six owned files". Adding a 7th file
   there would fail WO-10's census and collide with the health lane's file.
   Test relocated to `test/cluster/cluster_test.exs` (new dir, rest of
   `test/` = WO-11 seam — disclosed for RESOLUTIONS.md entry).
2. **Minimal unblock fixes to shared files**: none. Two transient
   compile-freezes from other lanes' in-flight edits (`policy.ex`,
   `arm_gateway/router.ex`) were waited out (compile-freeze SLA), not
   touched.
3. Witness script lives at `/tmp/cluster_witness.exs` (scratch); a durable
   home under `scripts/` can be assigned by the coordinator.
4. test helper: `Code.require_file("poll_helper.exs", Path.join(__DIR__,
   "../internal"))` — consumes WO-10's audited poll helper read-only.

## Coordinator diff lines for `config/runtime.exs`

Append after the planes `case` block (tail of file). Do not hand-apply
elsewhere; runtime.exs is not lane-clu-owned.

```elixir
# Cluster interconnect (Smalt.Cluster) — default OFF, byte-identical solo
# boot. Flip via env in container/k8s profiles only.
cluster_enabled = System.get_env("SMALT_CLUSTER_ENABLED") in ["1", "true"]
cluster_dns = System.get_env("SMALT_CLUSTER_DNS_NAME")

config :smalt, :cluster,
  enabled: cluster_enabled and is_binary(cluster_dns) and cluster_dns != "",
  dns_name: cluster_dns,
  port: String.to_integer(System.get_env("SMALT_CLUSTER_PORT") || "0"),
  poll_ms: String.to_integer(System.get_env("SMALT_CLUSTER_POLL_MS") || "5000"),
  node_prefix: System.get_env("SMALT_CLUSTER_NODE_PREFIX") || "smalt",
  max_retries: String.to_integer(System.get_env("SMALT_CLUSTER_MAX_RETRIES") || "3")
```

## Not done / handoff

- `Smalt.Cluster` is not in the supervision tree; when the coordinator wires
  it into `Smalt.Application` children under `enabled: true` gating, reuse
  the runtime.exs diff above. `cluster_status/0` is ready for the
  adaptive-probe lane (module API).
- No KD rows minted (not a divergence — native capability), no GAP tokens
  touched.
