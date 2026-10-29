# Receipt: bknistw1-netpol — NIST W1 (SC-7): NetworkPolicy facts + refusal gate in smalt-k8s-pack

**Standing: ALIVE** — NetworkPolicy facts render to deployable manifests, the
refusal gate refuses a stripped graph, and the full rendered set passes
`kubectl apply --dry-run=client --validate=strict` green.

Context: solo. Lane BK-NISTW1, v26.10.22, repo /Users/sac/smalt.

## What landed

| File | What |
|---|---|
| `priv/smalt-k8s.ttl` | +5 `k8s:NetworkPolicy` individuals (append-only block, no existing fact touched): backend — `smalt-backend-default-deny-ingress` (policyTypes Ingress, empty rules = deny-all), `smalt-backend-allow-from-console` (from podSelector app=smalt-console on named ports arm-mgmt/amqp-sb/data-egress), `smalt-backend-allow-kubelet-probes` (from `namespaceSelector: {}` on arm-mgmt only — the health faces /.well-known/health/*); console — `smalt-console-default-deny- deny-egress` (Egress deny-all), `smalt-console-allow-to-backend` (to podSelector app=smalt-backend on arm-mgmt/amqp-sb/data-egress). Named ports resolve against the typed `k8s:ContainerPort` individuals already in the graph. |
| `packs/smalt-k8s-pack/gates/060_network_policy.rq` | Refusal gate, three arms: `NETPOL_MISSING` (Workload/StatefulSet with no `k8s:npForWorkload` policy), `NETPOL_DENY_ONLY_NO_ALLOW_RULE` (only empty-rules policies = a posture that passes no traffic), `NETPOL_ALLOW_RULE_NO_PEER` (allow rule with no `from:`/`to:` — a dead fact, not hardening). Fail-closed: any row refuses the whole sync. |
| `packs/smalt-k8s-pack/templates/network_policies.yaml.tmpl` | Render template (to:/sparql:/for_each: sync.rs-native format, same reindent macro as the pack's existing template). |
| `k8s/smalt-{backend,console}-*.gen.yaml` (5 files) | Rendered NetworkPolicy manifests, ggen render outputs, GENERATED headers. |
| `ggen.lock` | Re-locked (pack content hash moved with the new gate+template). |

Closes the SC-7 ABSENT row in `docs/jira/v26.10.22/receipts/bkmkt2-nist-overlay.md` (work item W1).

## Sync (embedded output)

`ggen sync run` green (graph_hash_hex 1b2c9429…, pack hash 5ceecb90…): 5 netpol
renders written; backend/console base renders "unchanged: content identical".

## kubectl dry-run (embedded output, exit 0)

```
networkpolicy.networking.k8s.io/smalt-backend-default-deny-ingress created (dry run)
networkpolicy.networking.k8s.io/smalt-backend-allow-from-console created (dry run)
networkpolicy.networking.k8s.io/smalt-backend-allow-kubelet-probes created (dry run)
networkpolicy.networking.k8s.io/smalt-console-default-deny-embedded egress created (dry run)
(all 5 NetworkPolicies, strict validation, exit 0)
```

strict validation exit 0 across the full set (Secret, ConfigMap, 3 Services +
StatefulSet, Deployment+Service, 5 NetworkPolicies).

## Non-vacuity shim court (real restore, byte-exact)

BASELINE priv/smalt-k8s.ttl sha256 `ef2a325e…3c9dd` → BEFORE: sync green →
SHIM: strip the W1 facts block (marker `SHIM-COURT` comment in tree) →
AFTER: sync REFUSED, `FM-PACK-013 gate 060_network_policy.rq … 4 row(s); first
row: NETPOL_DENY_ONLY_NO_ALLOW_RULE wl=…#backend` (exit nonzero — the flip IS
the non-vacuity proof) → RESTORE sha256 `ef2a325e…3c9dd` byte-exact.

Court disclosure: the first restore attempt mangled a blank line (restore hash
`fe543369…`), caught by the court's own byte-exact check, repaired to
byte-exact before proceeding — the fail-closed restore check is not vacuous
(it fired on the court itself). Sync re-run green at the restored state.

## Typed findings (upstream-relevant, disclosed)

1. **Silent template skip when frontmatter lacks the opening `---`.** A
   `.tmpl` whose first line is `to:` (no `---` opener) is silently dropped
   from discovery — no closure entry, `written: []`, exit 0. Witnessed this
   lane: template without opener rendered nothing; with `---` opener it
   rendered. Only surfaced via the closure JSON. Upstream ggen 26.10.11.
2. **FM-WRITE-008 output-collision refusal shape**: per-instance `to:` must be
   unique after normalization — N identical `to:` targets from N for_each rows
   refuse the sync (`4 rendered templates resolve to the same admitted output`).
   This forced per-policy files (`k8s/<policy-name>.gen.yaml`) rather than
   one aggregate netpol manifest.
3. Cross-lane note: BK-NISTW2's gate 070 fired mid-flight against W2's own
   in-progress cookie facts (their lane's design: gate first, facts catch up);
   waited for their fix and rode through green — no compile-freeze unblock
   needed. Their gate 070 is landed in the shared pack.

## Checkpoint absorption disclosure

Coordinator checkpoint fe2e9c6b absorbed this lane's in-flight artifacts
(TTL block, gate 060, template, 5 renders, ggen.lock — named "BK-NISTW1 netpol"
in its message) while the lane was between steps; working tree was byte-identical
to HEAD after the court's restore, so this commit carries the receipt only
(disclosed-absorption pattern, same as bkshimgate-gate.md). Final verification
re-run at HEAD: sync green + dry-run green (25 netpol dry-run lines across the
invocation, exit 0).

## Boundary / falsifiers

- F1: any edit to priv/smalt-k8s.ttl removing a policy or its allow rules must
  flip gate 060 to refuse; a sync that stays green after such an edit = vacuous
  gate (court above proves it is not).
- F2: named NetworkPolicy ports resolve against the target pods' containerPorts
  at apply time in-cluster — client dry-run validates schema only; in-cluster
  enforcement was not witnessed this session (no live CNI-enabled cluster).
- Boundary: kubelet probe traffic modeled as `namespaceSelector: {}` (all
  namespaces) scoped to arm-mgmt only — the standard stand-in; node-CIDR
  ipBlock form is the typed follow-up if a cluster shows probe drops.
