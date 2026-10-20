# kd107-blob-snapshots-tbd.md — evidence receipt (kd-lane, 2026-10-19)

- **KD row**: KD-107 (blob snapshots partial) — row prose says "snapshot create works
  but snapshot listing/lease-on-snapshot semantics diverge"; source survey below shows
  MORE is wired than the row prose claims (correction + narrowing for the registrar)
- **Standing**: OPEN — no snapshot-lifecycle witness receipt exists in this window; divergence surface NARROWED vs the row prose
- **Context**: solo

## Real command output (this session, tree at 81a7a29)

### 1. wf2 external suite never exercised snapshots (profile names the surface, no cell ran)

```
$ grep -c snapshot docs/jira/v26.10.19/sdk-results/wf2-ts-multistore-concurrency.md docs/jira/v26.10.19/sdk-results/wf2-py-multistore-concurrency.md
docs/jira/v26.10.19/sdk-results/wf2-ts-multistore-concurrency.md:1
docs/jira/v26.10.19/sdk-results/wf2-py-multistore-concurrency.md:1
```

Exactly one match per file — the `cap:blob-snapshot-metadata` profile line itself; no
snapshot cell verdict exists in either wf2 receipt. Both greps ran this session against
the working tree and exit 0.

### 2. Wire arms: create + read-at-snapshot are WIRED and KD-COVERS-pinned

```
$ grep -n 'snapshot' lib/smalt/egress_router.ex ; echo "exit=$?"
40:  # KD-COVERS: KD-60 — comp=snapshot is registered (wire arm below); the rest
42:  @blob_put_comps ~w(block blocklist metadata snapshot)
2127:      # blob PUT arm. Any comp value with no implemented handler here (snapshot,
2173:            # snapshot_blob/5 was previously engine-only; an unregistered comp hit
2174:            # the typed 400). Azure answers 201 with the x-ms-snapshot timestamp
2176:            # snapshot create arm with 409 ContainerLocked).
2177:            if conn.query_params["comp"] == "snapshot" do
2181:                case BlobStorage.snapshot_blob(account, container, blob_name, header_map(conn)) do
2328:            # KD-COVERS: KD-60 — snapshot read-back (`GET ?sharesnapshot=<ts>`):
2329:            # serves the frozen point-in-time record from :smalt_blob_snapshots
2330:            # byte-exact; base-blob mutations after the snapshot stay invisible
2331:            # through the snapshot. Without the param the normal GET path runs.
2332:            if conn.query_params["sharesnapshot"] in [nil, ""] do
2410:              # Snapshot read arm (sharesnapshot present).
2414:                case BlobStorage.get_blob_snapshot(
2418:                       conn.query_params["sharesnapshot"]
2424:                    |> put_resp_header("x-ms-snapshot", conn.query_params["sharesnapshot"])
2586:      # snapshot, ...) previously fell through and deleted the blob anyway.
3925:  # value they did not name (appendblock, snapshot, page, pagelist, tags,
3960:  # arm, whose unhandled comps (appendblock, snapshot, page, ...) span more
exit=0
```

Snapshot CREATE (`PUT ?comp=snapshot` → `BlobStorage.snapshot_blob/2`, frozen record +
`x-ms-snapshot` header) and READ-AT-SNAPSHOT (`GET ?sharesnapshot=<ts>` →
`BlobStorage.get_blob_snapshot/4`, frozen point-in-time record, byte-exact, base
mutations invisible through it) are both wired and pinned `# KD-COVERS: KD-60`
(KD-60 shows CLOSED-SIMULATED in the kd_flip covers-map). A delete-precedence arm at
`:2586` covers WORM interplay.

### 3. Remaining divergence: snapshot LISTING + lease-on-snapshot

`docs/WIRE_PARITY.md` blob row: listing `include` tokens `snapshots/versions/tags` are
a registered typed refusal and never emit decoration — snapshot LISTING is not served,
and no lease-on-snapshot semantics exist. That residual is what remains of KD-107.

## Standing rationale

Create and read-at-snapshot are wired (KD-60 CLOSED-SIMULATED); listing and
lease-on-snapshot remain divergent; the skeleton falsifier ("SDK snapshot probe list +
read-back passes") NOT achieved. **KD-107 stays OPEN**, narrowed to listing +
lease-on-snapshot. Registrar may tighten the row prose to match.

## Cross-links

- `docs/WIRE_PARITY.md` blob row (typed refusal on `include=snapshots`);
  KD-60 (comp=snapshot covers-map, CLOSED-SIMULATED); KD-108 (lease family).
- kd105/kd109/kd110/kd111/kd112 evidence receipts in this directory.
