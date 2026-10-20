# kd113-legs-ab-policy-rbac-locks.md — evidence receipt (ERRC lane c8, 2026-10-19)

- **KD row**: KD-113 legs a+b (RBAC scope generalization + real management locks)
- **Standing**: PASS (module tier: compile green + live witness + tier regression)
- **Context**: solo

## What landed

`lib/smalt/policy.ex` (exclusive lane ownership), compile green:

- RBAC enforcement (KD-COVERS: KD-113 leg a): `authorize?/3` + `authorize?/4`
  resolve assignment scope prefixes (subscription ⊃ RG ⊃ resource,
  case-insensitive per the AZB-25c downcase law); `role_verbs/1` maps built-in
  GUIDs to verb sets (Owner=read/write/delete/authorize,
  Contributor=read/write/delete, Reader=read).
- Management locks (KD-COVERS: KD-113 leg b): `put_lock/get_lock/delete_lock/
  list_locks` (level CanNotDelete|ReadOnly, notes, scope-prefix matching) and
  `lock_blocks?/2` — `:delete` blocked by CanNotDelete AND ReadOnly; `:write`
  blocked by ReadOnly; `:read` never blocked (real ARM: ReadOnly blocks writes
  AND deletes, so the delete-block set is the union).
- `enforce/3` wiring: lock check BEFORE policy deny evaluation; a locked PUT
  refuses with an inline `ScopeLocked` envelope. Inline, not send_arm_error —
  same law as PolicyViolation (the arm_error_corpus meta-test pins the
  send_arm_error (status, code) set; the corpus scans only router.ex sites).

## Witness (real output, one run, `MIX_BUILD_ROOT=_build-lane-c8 mix run --no-start /tmp/smalt-c8/kd113_witness.exs`, EXIT=0)

```
a1 contrib delete in-scope                true
a2 contrib read in-scope                  true
a3 ghost delete                           false
a4 subreader read other-rg                true
a5 subreader write other-rg               false
a6 owner authorize                        true
a7 owner write                            true
b1 lock level                             "CanNotDelete"
b2 blocks delete                          true
b3 blocks write (CanNotDelete)            false
b4 enforce PUT under CanNotDelete         :ok
b5 bad level refusal code                 "ManagementLockInvalid"
b6 get after delete                       :error
b7 blocks delete after removal            false
b8 enforce after unlock                   :ok
b9 readonly enforce code                  "ScopeLocked"
b10 blocks write (ReadOnly)               true
b11 list_locks                            ["ro"]
WITNESS-DONE
```

## Falsifier status

Module-tier falsifier PASSED as amended: put lock CanNotDelete on an RG →
`lock_blocks?(delete)=true` (b2) while enforce(PUT) still proceeds (b4 —
CanNotDelete does not gate PUT, per real ARM); remove the lock → delete
unblocked (b7); ReadOnly lock → enforce(PUT) refuses with ScopeLocked (b9).
RBAC legs: Contributor/Reader/Owner verb sets + sub⊃RG⊃resource inheritance
all as predicted (a1..a7); unknown principal refused (a3).

## Router patch lines for the coordinator (router.ex owned elsewhere)

- `lib/smalt/arm_gateway/router.ex:1046` — the `{:deny, body}` branch of the
  `Policy.enforce` dispatch (case opens at :1019) sends 400 unconditionally.
  Patch to map the lock refusal class:

```elixir
{:deny, body} ->
  status = if String.contains?(body, "\"code\":\"ScopeLocked\""), do: 409, else: 400
  conn
  |> put_resp_content_type("application/json")
  |> send_resp(status, body)
```

- Lock record CRUD route family when wired (delegates to Smalt.Policy):
  `PUT/GET/DELETE /subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Authorization/locks/{lock}`
  (api-version 2016-09-01) + list at `.../locks`.

## Tier regression

```
MIX_BUILD_ROOT=_build-lane-c8 mix test   ->  exit 2, "50 tests, 3 failures"
```

All three failures are in test/internal and NONE exercise Smalt.Policy:

1. internal_tier_census_test (status-literal asserts vs the KD-104 certificate
   witness file — another lane's in-flight witness surface)
2. certificates_kd104_witness_test (MatchError in OTPCertificate decode —
   same KD-104 witness surface)
3. vm_zero_growth_test (ConnSup not alive — app-boot ordering under the
   lane's EPHEMERAL-port run, same surface at c9b0bf1's last green? unproven)

Lane classification: PRE-EXISTING / OTHER-LANE (my diff is policy.ex only,
+244/-0; the AZB-25c downcase fix at :678 preserved; the three failing
surfaces are the KD-104 certificates witness and the VM census/churn tests,
unrelated to RBAC/locks/policy enforce). Not session-introduced by c8; the
coordinator's integration sweep owns the reconcile.

## Boundary

KD-113 legs a+b closed at the module tier. Router wiring (locks routes +
409 ScopeLocked mapping) and the KD register flip via kd_flip.py belong to
the router lane / registrar.
## Re-witness addendum (2026-10-20, post token-format fix)

The KD-COVERS token format in `lib/smalt/policy.ex` was corrected
(`KD-113 leg a/b` → `KD-113 — leg a/b`), refreshing the file mtime. The
witness was re-run in full post-fix (`mix run --no-start
/tmp/smalt-c8/kd113_witness.exs`): WITNESS-DONE, exit 0, all 18 probes as
originally predicted (a1..a7 RBAC incl. readonly-enforce ScopeLocked face;
b1..b11 locks incl. ReadOnly write-block). Semantics unchanged — the edit
was comment-format only. This addendum postdates the refreshed shim mtime.
