# Receipt — ex5-insurance-governance (lane ex5)

- Date: 2026-10-19
- Lane: ex5 (owns ONLY `/Users/sac/smalt/examples/insurance-governance/**`)
- Subject: `bash examples/insurance-governance/run.sh` against the shared
  substrate (ARM TLS twin :9444, enforce auth, smalt STS credential)
- Files: `index.ts`, `run.sh`, `README.md`, `receipt.md` (this file)
- Standing: **PASS-with-SKIP (ALIVE)** — 15/19 GREEN, 0 FAIL, 4
  SKIP#SURFACE-ABSENT (management-locks surface is a typed 501 stub),
  exit code 3 per the exit-code contract (loud skip, never a fake pass).

## What ran

Real wire, official `@azure/arm-resources` (from
`verification/ts/node_modules`), zero mocks, boundedPoll discipline (the
only waits are SDK LRO pollers; the sole `expiresOn` stamp is annotated
`// SLEEP-CLASS: TIME-ADVANCE` as a wire body, never a sleep).

Chapter results (final run, 2026-10-19 21:56 local):

```
== ex5-insurance-governance: 15/19 GREEN, 4 SURFACE-ABSENT skip, 0 FAIL ==
  [GREEN] rg-create — policy-administration RG ex5-ins-rg-1792471765340 up
  [GREEN] policy-def-create — deny-by-location definition ex5-ins-deny-westus2-1792471765788 PUT by-id resolved
  [GREEN] policy-assignment-create — assignment at RG scope (enforcementMode Default)
  [GREEN] policy-deny — westus2 create refused with typed 400 PolicyViolation
  [GREEN] initiative-create — initiative ex5-ins-initiative-1792471765800 read-back lists 1 member definition(s)
  [GREEN] exemption-create — exemption ex5-ins-exemption-1792471765801 created (Waiver, expiresOn 2026-10-20T05:49:25.801Z)
  [GREEN] exemption-applies — westus2 DR vnet created under exemption (id /subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/ex5-ins-rg-1792471765340/providers/Microsoft.Network/virtualNetworks/ex5-ins-dr-vnet-1792471765803)
  [GREEN] exemption-remove — exemption DELETE LRO terminal
  [GREEN] exemption-expired-violation-returns — after exemption removal: 400/PolicyViolation
  [GREEN] rbac-builtin-role-def — GET roleDefinitions/contributor -> roleName=Contributor
  [GREEN] rbac-unknown-role-404 — typed 404 ResourceNotFound for unknown role
  [GREEN] rbac-role-assignment — assignment read-back principal=22222222-2222-2222-2222-222222222222 role=/subscriptions/11111111-1111-1111-1111-111111111111/providers/Microsoft.Authorization/roleDefinitions/b24988ac-6180-42a0-ab88-20f7382dd24c
  [SKIP#SURFACE-ABSENT] lock-create — substrate answers typed 501 LockSurfaceNotImplemented at RG scope (policy lane pending)
  [SKIP#SURFACE-ABSENT] lock-blocks-delete — dependent on lock surface (typed 501 skip)
  [SKIP#SURFACE-ABSENT] lock-remove — dependent on lock surface (typed 501 skip)
  [SKIP#SURFACE-ABSENT] delete-after-unlock — dependent on lock surface (typed 501 skip)
  [GREEN] tags-patch-merge — tags after two PATCH merges: {"costCenter":"cc-4511","env":"claims-prod"}
  [GREEN] tags-empty-null — tags after PUT with empty tags map (empty->null law): null
  [EXIT CODE: 3 (loud skip — locks surface not exposed)]
```

## Typed findings (honest, not failures of this harness)

1. **Management locks: SURFACE-ABSENT.** The substrate exposes locks only
   as a typed 501 `LockSurfaceNotImplemented` stub at RG scope
   (`Smalt.Policy.lock_blocks?/2` wiring is declared "pending policy lane"
   in `lib/smalt/arm_gateway/router.ex:966-990`); nested-resource lock
   paths answer 404 RouteNotFound. Wired as loud SKIP, exit 3.
2. **Custom role definitions: not exposed.** `roleDefinitions` is GET-only
   (deterministic built-ins Owner/Contributor/Reader); a PUT falls to the
   generic by-id handler and is refused by the GraphLaw validator. The
   harness targets the supported surface (built-in GET + roleAssignments
   lifecycle) and notes the gap.
3. **Wire law (witnessed):** a role-assignment body without a top-level
   `location` is refused `400 InvalidResourceShape` ("A resource payload
   may carry at most one location"); `location: "global"` is admitted.
   Real-Azure role assignments carry no location — KD-class divergence
   candidate for the register, evidence = this receipt.
4. **Policy state is per-boot.** Policy definitions/assignments/exemptions
   live in substrate memory; a substrate restart clears them (consistent
   with the wf1 pre-suite witness). Enforcement semantics within a boot are
   exact: deny -> violation, exemption -> pass, removal -> violation.

## Command output (final run)

```
EXIT=3
```

## Session-introduced disclosures (compile-freeze SLA)

- **Minimal unblock fix, sibling repo** `/Users/sac/ggen_igniter/lib/ggen_igniter/semantic_jira/complete.ex`
  (another lane's in-flight edit left `max_of(opts)` inside a guard — not a
  macro, so the shared substrate boot could not compile; the substrate was
  DOWN for all lanes). Fix: hoisted `max = max_of(opts)` to the loop body
  and used it in the guard + detail string. Semantically identical.
  Disclosed here per the compile-freeze SLA (same-checkout-fanout addition 2);
  the owning lane should fold or own this diff.
- One shared-lib freeze (`lib/smalt/messaging/event_hubs.ex`, mid-edit by
  another lane) self-resolved by its owner within the SLA window; ex5
  bounded-polled for the owner edit (grep for `defp cg_record`), no fix
  applied by this lane.

## Environment

- Substrate: shared `just substrate-up` (enforce auth, pid churn from
  concurrent lanes observed mid-run; restarted via the lock manager only,
  never evicted another lane).
- Node v26.10.0, `--experimental-strip-types`, NODE_EXTRA_CA_CERTS at
  `.smalt/tls/ca-cert.pem`.

---

## Integration note (coordinator, 2026-10-19 post-landing flip attempt)

Capability commit `8ca1b82` (KV deleted-keys/secrets planes, RBAC+locks)
landed mid-wave; the harness's pre-coded flip assertions were re-run twice
on freshly compiled canonical beams. Verdict: the plane is still not served
(`/deletedkeys`/`deletedsecrets` 404; RG-scope locks 501
LockSurfaceNotImplemented at arm_gateway/router.ex:982) — XFAIL stands,
never faked. Full recover/purge/lock assertions are coded and activate on
the first serving beam. Confounder: an outside actor cycled the shared
substrate during the window (5 beam pids observed); verdicts are
as-of-beam.
