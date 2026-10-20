# Insurance Policy Governance — smalt example

A Fortune-500 insurer's platform team governs its policy-administration
subscription. One harness, four chapters of the governance story:

1. **Azure Policy** — a deny-by-location definition ("no workloads in
   `westus2`") is authored at subscription scope, assigned at the RG scope,
   and enforced over the wire: a violating vnet create answers the same typed
   `400 PolicyViolation` a real Azure arm-client would render. The team then
   groups the definition into an **initiative** (`policySetDefinitions`,
   "claims-platform guardrails") and runs the full **exemption lifecycle**:
   grant a `Waiver` exemption with a far-future `expiresOn`, watch the same
   create succeed under the exemption, delete the exemption, and watch the
   typed violation return. Real audit story: exception granted, excepted
   create succeeds, exception expired, enforcement restored.
   Note (KD-class divergence, witnessed 2026-10-19): policy statements on
   this substrate do not survive a substrate restart — enforcement is
   in-memory per boot (consistent with the wf1 pre-suite witness).
2. **RBAC** — built-in role definitions are served deterministically
   (`GET roleDefinitions/contributor` -> `Contributor`,
   b24988ac-6180-42a0-ab88-20f7382dd24c); custom role-definition PUT is not
   an exposed surface (GET-only built-ins). A role assignment rides the
   RG-scope route and reads back with the principal + the resolved built-in
   role-definition id. Wire law (witnessed): the assignment body must carry
   exactly one top-level `location` — a no-location body is refused
   `400 InvalidResourceShape` ("A resource payload may carry at most one
   location"); the admitted shape carries `location: "global"`.
3. **Management locks** — probed against the real wire; the substrate
   answers a **typed 501 `LockSurfaceNotImplemented`** stub at RG scope
   (the `Smalt.Policy.lock_blocks?/2` wiring is a pending policy lane). The
   chapter is a loud `SKIP#SURFACE-ABSENT`, never a fake pass; the harness
   exits 3 per the exit-code contract.
4. **Tags at scope** — two PATCH merges accumulate `env` + `costCenter`,
   then a PUT with an empty tags map proves the empty->null law
   (full-replace removes stored tags; GET renders `"tags": null`).

## Run

```bash
bash examples/insurance-governance/run.sh
# exit 0 pass / 1 fail / 2 substrate down / 3 loud skip (surface absent)
```

Requires the substrate up (`just substrate-up`) and the dev TLS CA at
`.smalt/tls/ca-cert.pem`. SDKs resolve from `verification/ts/node_modules`;
the only smalt imports are the shared verification harness (`enum`,
`assert`, `credential`), which contains no `lib/` imports. Zero mocks —
every check rides the real TLS wire against the ARM twin on :9444.
