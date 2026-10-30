# 25 — posh-court green runbook (GAP09 R1: never witnessed exit 0)

## Live-witnessed state (2026-10-30, this lane)

- **Plane state = SPLIT** (`scripts/court_plane_discriminator.sh` exit 2, ALIVE run):
  host `127.0.0.1:9443` is owned by **beam.smp pid 90813**, cwd `/Users/sac/smalt`,
  ppid=1 (launchd), started 12:42:58, `mix run --no-halt` — the G17 native beam,
  lane-orphaned per same-checkout-fanout law 4 (socket + no owning lane). A
  second listener, colima's ssh mux pid 1010 on `*:9443`, is the KIND path
  (docker context = colima: host → ssh mux → colima VM → docker-proxy → kind node).
  The court's host probe (`SMALT_POSH_META=http://127.0.0.1:9443/...`) hits the
  **specific bind (beam) over the wildcard (ssh)** — so a green court today would
  be answering on the NATIVE plane: vacuous green. Both planes answer 200 on
  `/metadata/endpoints`.
- **F14 sidecar: NOT fixed.** `kubectl exec ... -c posh-membrane -- sh` →
  `exec: "sh": executable file not found in $PATH`; `/app/entrypoint` →
  `stat: no such file`. Image `posh:sidecar` is distroless-ish with no shell and
  no entrypoint at the assumed path. `posh-sidecar-witness` pod 0/2 Completed.
  All court stages are host-side (go/terraform/curl), so this does not gate the
  ladder, but any sidecar exec assertion would fail — keep as watch item.
- **Kind node disk: FAILING preflight.** `smalt-control-plane:/var/lib/containerd`
  avail **15864MB < 20000MB** threshold (`justfile.d/52-kind.just:138`).
  Witnessed failure path in the green receipt: kind-down/up recreate did NOT fix
  (14756MB after recreate) — the 60GB volume is thin; crictl prune only freed
  ~46MB. Real reclaim: `docker system df` shows **8.089GB build cache, 100%
  reclaimable**; images 9.3GB reclaimable.
- Receipt `docs/jira/posh/v26.10.30/receipts/posh-court/posh-court-green.json`:
  standing FAIL, exit 1, `0/8 PASS`, `per_stage: []` — died in `[POSH-COURT-PRE]`
  at `[KIND-IMAGES-FAIL]` before stage 1. No stage has ever been witnessed.

## Ordered runbook to `just posh-court` exit 0

1. **Discriminate the plane** (repeat at any point to re-witness):
   `scripts/court_plane_discriminator.sh` → expect `PLANE=SPLIT` (exit 2) today.
   Kind-only end state: `PLANE=KIND` (exit 2, beam line absent).
2. **Verify the native beam is orphaned, then stop it** (order matters):
   - Ownership: `ps -o pid,ppid,lstart,command -p <pid>` → ppid must be 1
     (launchd), command contains `mix run --no-halt`, cwd `/Users/sac/smalt`
     (`lsof -a -p <pid> -d cwd -Fn`). If ppid != 1 or cwd is another repo, it is
     another lane's live process — DO NOT kill, re-triage.
   - Stop: `kill 90813` (SIGTERM; escalate `kill -9` after 10s only if still up).
   - Expected: `scripts/court_plane_discriminator.sh` → `PLANE=KIND` and host
     `curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:9443/metadata/endpoints`
     now returns **200 via the wildcard ssh/kind path** (colima forwards into the
     kind cluster), or 000 if no host→node mapping exists — if 000, point the
     court anchor in-cluster instead of killing anything further:
     `SMALT_POSH_META=http://<pod-ip>:9443/...` via a `kubectl port-forward`.
3. **Free docker disk so the node preflight can pass**:
   - `docker builder prune -f` → expect ~8GB freed (build cache 100% reclaimable).
   - Optional: `docker image prune -f` (untagged) — avoid pruning images tagged
     `smalt:local` / `kindest/node` (court needs both).
   - Verify: `docker exec smalt-control-plane sh -c 'df -m /var/lib/containerd | tail -1'`
     → avail must be **>= 20000MB**. If still short after prune, `just kind-down`
     then let the court's `kind-up` recreate (witnessed: recreate alone without
     host-side prune does NOT clear the threshold — prune first).
4. **Court run**:
   `just posh-court > tmp/posh/posh-court-$(date +%Y%m%d-%H%M).log 2>&1; echo exit=$?`
   - Expected stage lines: `[POSH-COURT-PRE] PASS kind ladder`, `PASS metadata
     anchor 200 after N poll(s)`, `PASS posh-build`, `PASS posh-install`, then
     `[POSH-COURT-n] PASS ...` for stages 1–7 (stage 1 may print SKIP if
     golangci-lint is not on PATH — typed, lawful), final
     `[POSH-COURT] result: 7/8 PASS (or 8/8), N SKIP, 0 FAIL` and `exit=0`.
   - If `[KIND-IMAGES-FAIL]` recurs: return to step 3, verify the df number on
     disk, do not retry blind (no-sleep/no-blind-retry law).
   - If the metadata anchor never reaches 200: re-run the discriminator — a new
     native beam or a dead kind path is the first suspect.
5. **Post-court witness**: re-run `scripts/court_plane_discriminator.sh` and
   record `PLANE=KIND` in the green receipt so the next GAP09 replay knows which
   plane the receipt certifies.

## Falsifier

`scripts/court_plane_discriminator.sh` — prints `PLANE=native|kind|split|none`
from (a) HTTP probe of host loopback and in-cluster pod IP, (b) socket ownership
of the probe port (beam.smp vs tunnel), (c) cwd of the owning beam. Exit 0
NATIVE, 2 KIND/SPLIT, 3 NONE/UNKNOWN (fail-closed). Non-vacuity: witnessed live
flipping — with beam 90813 up it prints `SPLIT` (exit 2); after step 2 it must
flip to `KIND`. A discriminator that prints the same plane before and after the
beam stop is VACUOUS.

## See Also

`docs/jira/posh/v26.10.30/receipts/posh-court/posh-court-green.json` ·
`justfile.d/58-posh.just` (posh-court) · `justfile.d/52-kind.just:121-147`
(disk preflight) · G17 · F14 · GAP09 R1
