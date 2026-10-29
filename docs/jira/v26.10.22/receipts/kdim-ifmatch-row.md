# KD-IM — IF-MATCH-IGNORED witness verification (PB-1 SDK leg)

**Standing:** ALIVE (witnessed refutation) — the PB-1 `IF-MATCH-IGNORED` divergence claim is
REFUTED; the emulator honors If-Match → 412 on every face probed. No KD row
minted (register row only for real emulator divergences; dispatch step 3).
Context: solo

Evidence: docs/jira/v26.10.22/receipts/bk5-powlbench.md (PB-1,
`injection_failures=170` at every contention point ≥10%,
`IF-MATCH-IGNORED surface divergence (KD/GAP pending)`), and
tmp/bench/pb1-fond-sweep.jsonl.

## Root cause (probe mis-shape, not emulator divergence)

The PB-1 SDK leg (`scripts/bench/pb1_cosmos_sdk.mjs`) issued conditional
replaces with `{ ifMatchEtag: "…" }`. `ifMatchEtag` is **not an option** in
@azure/cosmos 4.10.1 (the version under verification/ts): zero occurrences in
the installed dist or typings. The option is silently ignored, the If-Match
header never left the client, and the emulator correctly answered 200 — the
bench counted each 200 as an "injection failure" (stale etag accepted).
The documented conditional-write shape is:

```js
await item.replace(body, { accessCondition: { type: "IfMatch", condition: etag } });
```

## Probe receipts (all fresh, lane-b1 private substrate, 2026-10-22)

Substrate: `bench_boot b1` (ports 39010..39015, MIX_ENV=test anonymous),
torn down after the probe (b1 block verified free).

### Wire face 1 — plain HTTP egress 39011 (curl)

```text
create doc (POST /dbs/kdprobe/colls/c1/docs)      201
PUT with STALE  If-Match: stale-etag-seed          412 PreconditionFailed
PUT with CORRECT If-Match: <current etag>          200
20 sequential stale If-Match PUTs                  accepted(non-412)=0  rejected(412)=20
```

### Wire face 2 — TLS twin 39014 (curl, dev-cert-39014 pin)

```text
create doc (with x-ms-documentdb-partitionkey)    201
PUT with STALE  If-Match: stale-seed               412 PreconditionFailed
PUT with CORRECT If-Match: <current etag>          200
10 sequential stale If-Match PUTs                  accepted(non-412)=0  rejected(412)=10
```

### SDK face — @azure/cosmos 4.10.1 over TLS twin 39014

```text
# leg shape as PB-1 ran it (ifMatchEtag):
read ok, etag: "67bafce3-..."
SDK-STALE: ACCEPTED status=200 (divergence — no 412)   <- header never sent

# corrected shape (accessCondition):
read ok, etag: "ea9db1b3-..."
SDK-STALE: refused code= 412 The condition specified using HTTP conditional header(s) is not met.
SDK contention: stale accepted=0 rejected412=20
SDK-GOOD: status 200 etag "6599b42c-..."
```

## Disposition

- Emulator If-Match/CAS: CORRECT on both wire faces and via the SDK when the
  header is actually sent. No emulator divergence → no KD row.
- Probe defect: `scripts/bench/pb1_cosmos_sdk.mjs` `settle/1` uses
  `ifMatchEtag` — dead option, injections never on the wire. The bench's
  170/point `injection_failures` measure the probe's own dropped header, not
  surface behavior. The PB-1 falsifier line in bk5-powlbench.md ("a rerun
  whose SDK leg shows injection_failures=0 refutes the divergence") is
  satisfied in advance: the corrected-shape probe shows injection_failures=0
  with real 412s on the wire.
- Owner of the repair: BK-5 lane (scripts/bench/pb1_cosmos_sdk.mjs) — swap
  `ifMatchEtag` → `accessCondition` and rerun the SDK leg; expect
  injection_failures=0 and nonzero conflicts (412s) at contention ≥10%.
  This lane did not touch the bench script (registrar-lane boundary).

## Replay

```bash
export PATH="$HOME/.asdf/shims:$PATH"; cd /Users/sac/smalt
bash -c 'source scripts/bench/lib.sh; bench_boot b1; sleep 100000' &   # lane-b1 substrate
NODE_EXTRA_CA_CERTS=$PWD/tmp/dev-certs/dev-cert-39014.pem PB1_ATLS=39014 \
  node <probe script>   # item.replace(body, { accessCondition: { type: "IfMatch", condition: etag } })
```

Probe scripts were session-scratch under /tmp (kdim_probe.sh, kdim_sdk_probe.mjs);
the wire probes are inline curl and fully specified above.

## RE-WITNESS addendum (BK-REWIT2 lane, 2026-10-22)

Exit-capture addendum on the KD-IM lane's evidence (kept intact). On-disk
verification of the corrected-probe premise, this session:

```
$ grep '"version"' verification/ts/node_modules/@azure/cosmos/package.json
  "version": "4.10.1",
$ grep -rl 'ifMatchEtag' verification/ts/node_modules/@azure/cosmos/ | head -3
(no output — zero occurrences in the entire installed package)
exit=1
$ grep -n -E 'ifMatchEtag|accessCondition' scripts/bench/pb1_cosmos_sdk.mjs
59:// one settlement: R stale-etag attempts (412) then CAS match (200)
60:async function settle(item, doc, r) {
67:      await item.replace({ ...doc, v: 1 }, { accessCondition: { type: "IfMatch", condition: "pb1-stale-seed" } });
80:        await item.replace({ ...doc, v: 1 }, { accessCondition: { type: "IfMatch", condition: `pb1-stale-${i}` } });
90:  await item.replace({ ...doc, v: 2 }, { accessCondition: { type: "IfMatch", condition: etag } });
exit=0
```

The BK-5 owner repair has LANDED: `scripts/bench/pb1_cosmos_sdk.mjs` now uses
the documented `accessCondition` shape on all three replace sites; zero
`ifMatchEtag` occurrences anywhere in @azure/cosmos 4.10.1 or the bench
script. The PB-1 falsifier line in bk5-powlbench.md (injection_failures=0 on a
rerun) remains the KD-IM lane's own replay; standing unchanged:
REFUTED-WITNESS. exit=0
