#!/usr/bin/env python3
# S8 Cosmos optimistic-concurrency e2e chain — real loopback wire against the
# smalt substrate data plane (8443).
#
# Transport: the azure-cosmos SDK is attempted first (construction + the full
# chain when available). The substrate currently has no GET/POST /dbs surface,
# so the SDK cannot construct; the chain then runs the SAME steps over raw
# HTTP (threaded), which is the wire the CAS property lives on. Every step
# records PASS / FAIL / BLOCKED with wire evidence — fail-closed: exit 0 only
# when every step is PASS.
#
# Usage: ./race.py <base-url>
# Emits one STEP-RECEIPT line per step and a final: RECEIPT:<json>

import concurrent.futures
import json
import sys
import threading
import time
import urllib.request
import urllib.error

BASE = (sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8443").rstrip("/")

STEPS = []
TLS_LOCK = threading.Lock()  # serializes last_response_headers capture


def record(step, verdict, **evidence):
    entry = {"step": step, "verdict": verdict}
    entry.update(evidence)
    STEPS.append(entry)
    print("STEP-RECEIPT:" + json.dumps(entry), flush=True)
    return entry


def http(method, path, body=None, headers=None):
    """Raw loopback HTTP. Returns (status, headers, text). No stubs."""
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        BASE + path, method=method, data=data,
        headers={"content-type": "application/json", **(headers or {})})
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            return resp.status, dict(resp.headers), resp.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read().decode()


def jbody(text):
    try:
        return json.loads(text)
    except Exception:
        return None


# ---------------------------------------------------------------------------
# Step 0 — create-surface readiness. The real azure-cosmos SDK is attempted
# first (construction + probe round-trip when available); when the SDK is not
# installed (or cannot complete a round-trip) the SAME probe runs over raw
# loopback HTTP. Either transport proving POST /dbs, POST /dbs/:db/colls and
# POST .../docs work is a PASS.
# ---------------------------------------------------------------------------
DB, COLL = "s8db", "s8coll"
DOCS = f"/dbs/{DB}/colls/{COLL}/docs"
TENANT = "acme"
PK = "x-ms-documentdb-partitionkey"

sdk_evidence = {}
try:
    from azure.cosmos import CosmosClient
    sdk_client = CosmosClient(BASE, "s" * 64, consistency_level="Session")
    # If construction succeeded, prove it with a real round-trip.
    dbp = sdk_client.get_database_client(DB)
    cp = dbp.get_container_client(COLL)
    cp.create_item({"id": "s8-sdk-probe", "tenantId": TENANT})
    sdk_evidence = {"transport": "azure-cosmos real SDK",
                    "note": "SDK constructed and created probe doc"}
    s0_verdict = "PASS"
except Exception as e:  # noqa: BLE001 — the evidence IS the failure record
    sdk_evidence = {
        "sdk_error": f"{type(e).__name__}: {e}".splitlines()[0][:220],
    }
    # Same probe over the raw wire: create db, coll, doc, read it back.
    s_db, _, _ = http("POST", "/dbs", {"id": DB})
    s_cl, _, _ = http(
        "POST", f"/dbs/{DB}/colls",
        {"id": COLL, "partitionKey": {"paths": ["/tenantId"]}})
    s_d, _, b_d = http("POST", DOCS, {"id": "s8-probe", "tenantId": TENANT},
                       {PK: f'["{TENANT}"]'})
    s_g, _, b_g = (http("GET", f"{DOCS}/s8-probe") if s_d == 201 else (0, {}, ""))
    probe_ok = s_d == 201 and s_g == 200 and "s8-probe" in b_g
    sdk_evidence.update(post_dbs=s_db, post_colls=s_cl,
                        create_status=s_d, readback_status=s_g)
    s0_verdict = "PASS" if probe_ok else "FAIL"
record("s0_create_surface_probe", s0_verdict,
       transport=sdk_evidence.pop("transport", "raw loopback HTTP"),
       **sdk_evidence)
# The chain below always runs over the raw wire (the CAS property lives there);
# the SDK attempt is evidence only.
SDK = False

# ---------------------------------------------------------------------------
# Raw-HTTP chain (the substrate wire). The SDK attempt in s0 is evidence only;
# every step below runs over raw loopback HTTP.
# ---------------------------------------------------------------------------
SESSION_TOKENS = []  # (op, token) captured under TLS_LOCK


def note_session(op, headers):
    tok = headers.get("x-ms-session-token")
    with TLS_LOCK:
        SESSION_TOKENS.append((op, tok))


# Step 1 — create db/coll with partition key /tenantId — create surfaces work.
t0 = time.time()
s_post_db, h_post_db, b_post_db = http("POST", "/dbs", {"id": DB})
s_coll, h_coll, b_coll = http(
    "POST", f"/dbs/{DB}/colls", {"id": COLL, "partitionKey": {"paths": ["/tenantId"]}})
record("s1_create_db_coll",
       "PASS" if s_post_db < 300 and s_coll < 300 else "FAIL",
       post_dbs=s_post_db, post_colls=s_coll,
       bodies={"dbs": b_post_db[:160], "colls": b_coll[:160]},
       us=int((time.time() - t0) * 1e6))

# Step 2 — 16 threads x 10 docs, unique ids, partition "acme", all 201
TENANT = "acme"
t0 = time.time()


def create_batch(worker):
    out = []
    for i in range(10):
        doc_id = f"s8-w{worker}-{i}"
        s, h, b = http("POST", DOCS,
                       {"id": doc_id, "tenantId": TENANT, "v": i},
                       {PK: f'["{TENANT}"]'})
        out.append((doc_id, s, b[:120] if s != 201 else None))
    return out


with concurrent.futures.ThreadPoolExecutor(max_workers=16) as pool:
    flat = [x for batch in pool.map(create_batch, range(16)) for x in batch]

codes2 = [s for _, s, _ in flat]
record("s2_bulk_create_16x10", "PASS" if codes2.count(201) == 160 else "FAIL",
       total=len(flat), created_201=codes2.count(201),
       statuses={str(s): codes2.count(s) for s in set(codes2)},
       non_201_bodies=[{"id": d, "status": s, "body": b}
                       for d, s, b in flat if s != 201],
       us=int((time.time() - t0) * 1e6))

# Step 3 — same-doc race: 8 threads each read own etag, replace with If-Match
RACE_ID = "s8-race-doc"
http("POST", DOCS, {"id": RACE_ID, "tenantId": TENANT, "v": 0}, {PK: f'["{TENANT}"]'})
t0 = time.time()


BAR = threading.Barrier(8)


def read_then_replace(worker):
    s_r, h_r, b_r = http("GET", f"{DOCS}/{RACE_ID}")
    if s_r != 200:
        BAR.abort()
        return ("read", s_r, None, worker, None)
    etag = jbody(b_r)["_etag"]
    # Barrier: every worker reads BEFORE any replace runs, so all 8 race on the
    # SAME etag and the server-side CAS property (1x200 / 7x412) is measured
    # against a single generation — a late GET that reads a fresh etag would
    # otherwise be a legitimate second winner, not a lost update.
    BAR.wait()
    s, h, b = http("PUT", f"{DOCS}/{RACE_ID}",
                   {"id": RACE_ID, "tenantId": TENANT, "v": worker},
                   {"if-match": etag, PK: '["acme"]'})
    return ("replace", s, etag, worker, h.get("x-ms-session-token"))


with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
    results3 = list(pool.map(read_then_replace, range(8)))

rep = [r for r in results3 if r[0] == "replace"]
rep_codes = [s for _, s, _, _, _ in rep]
cas_ok = rep_codes.count(200) == 1 and rep_codes.count(412) == 7
_, _, b_final = http("GET", f"{DOCS}/{RACE_ID}")
final_doc = jbody(b_final) if isinstance(b_final, str) else None
record("s3_same_doc_cas_race", "PASS" if cas_ok else "FAIL",
       statuses={str(c): rep_codes.count(c) for c in set(rep_codes)},
       winners=[{"worker": w, "v": w} for _, s, _, w, _ in rep if s == 200],
       final_doc_v=(final_doc or {}).get("v"),
       lost_update_detected=rep_codes.count(200) > 1,
       read_failures=[(r[0], r[1]) for r in results3 if r[0] == "read"],
       cas_property="exactly-one-200-and-seven-412",
       us=int((time.time() - t0) * 1e6))

# Step 4 — query POST (application/query+json): cross-partition scan and
# single-partition (pk-header) filter. A query POST must NEVER create a doc.
t0 = time.time()
PARTITIONS = ["acme", "globex", "initech"]
expected = []
for part in PARTITIONS:
    for i in range(3):
        doc_id = f"s8-q-{part}-{i}"
        expected.append(doc_id)
        http("POST", DOCS, {"id": doc_id, "tenantId": part, "i": i},
             {PK: f'["{part}"]'})

s_q, h_q, b_q = http("POST", DOCS, {"query": "SELECT * FROM c"},
                     {"x-ms-documentdb-is-query": "true",
                      "content-type": "application/query+json"})
cross = jbody(b_q) or {}
cross_ids = {d.get("id") for d in cross.get("Documents", []) if isinstance(d, dict)}

s_sp, h_sp, b_sp = http("POST", DOCS, {"query": "SELECT * FROM c WHERE c.tenantId = 'acme'"},
                        {"x-ms-documentdb-is-query": "true",
                         "content-type": "application/query+json",
                         PK: '["acme"]'})
single = jbody(b_sp) or {}
single_ids = {d.get("id") for d in single.get("Documents", []) if isinstance(d, dict)}

# A query POST must never create a document.
created_by_query = s_q == 201 or s_sp == 201

foreign_ids = {f"s8-q-globex-{i}" for i in range(3)} | {f"s8-q-initech-{i}" for i in range(3)}

query_ok = (
    s_q == 200 and set(expected) <= cross_ids
    and s_sp == 200 and set(expected[:3]) <= single_ids
    and not (single_ids & foreign_ids)
)
record("s4_cross_partition_query", "PASS" if query_ok else "FAIL",
       query_post_status=s_q, cross_count=cross.get("_count"),
       cross_ids=sorted(cross_ids)[:12],
       single_pk_query_status=s_sp, single_count=single.get("_count"),
       single_ids=sorted(single_ids)[:12],
       no_create_on_query=not created_by_query,
       us=int((time.time() - t0) * 1e6))

# Step 5 — delete with current etag -> 204; re-delete -> 404
t0 = time.time()
del_id = "s8-del-doc"
http("POST", DOCS, {"id": del_id, "tenantId": TENANT, "v": 1}, {PK: f'["{TENANT}"]'})
_, _, b_del = http("GET", f"{DOCS}/{del_id}")
etag = jbody(b_del)["_etag"]
s_d1, h_d1, _ = http("DELETE", f"{DOCS}/{del_id}", headers={"if-match": etag})
note_session("delete1", h_d1)
s_d2, h_d2, _ = http("DELETE", f"{DOCS}/{del_id}", headers={"if-match": etag})
note_session("delete2", h_d2)
record("s5_delete_etag_semantics",
       "PASS" if (s_d1, s_d2) == (204, 404) else "FAIL",
       first_delete=s_d1, re_delete=s_d2,
       us=int((time.time() - t0) * 1e6))

# Step 6 — session token monotonic across replaces (x-ms-session-token)
t0 = time.time()
sess_id = "s8-sess-doc"
http("POST", DOCS, {"id": sess_id, "tenantId": TENANT, "v": 0}, {PK: f'["{TENANT}"]'})
s_r0, h_r0, b_r0 = http("GET", f"{DOCS}/{sess_id}")
note_session("read0", h_r0)
tokens = [h_r0.get("x-ms-session-token")]
put_statuses = []
cur_etag = jbody(b_r0)["_etag"]
for gen in range(1, 6):
    s_u, h_u, _ = http("PUT", f"{DOCS}/{sess_id}",
                       {"id": sess_id, "tenantId": TENANT, "v": gen},
                       {"if-match": cur_etag, PK: '["acme"]'})
    put_statuses.append(s_u)
    note_session(f"replace{gen}", h_u)
    tokens.append(h_u.get("x-ms-session-token"))
    _, _, b_next = http("GET", f"{DOCS}/{sess_id}")
    cur_etag = jbody(b_next)["_etag"]

lsns = [int(t.split("#")[1]) for t in tokens if t]
mono = lsns == sorted(set(lsns)) and len(lsns) == 6
record("s6_session_token_monotonic", "PASS" if mono else "FAIL",
       tokens=tokens, monotonic=mono, put_statuses=put_statuses,
       us=int((time.time() - t0) * 1e6))

# Step 7 — negative: partition-key header mismatch -> 400
t0 = time.time()
s_n, h_n, b_n = http("POST", DOCS,
                     {"id": "s8-neg-1", "tenantId": TENANT},
                     {PK: '["other"]'})
record("s7_pk_mismatch_400", "PASS" if s_n == 400 else "FAIL",
       expected_status=400, observed_status=s_n,
       body=b_n[:200],
       reason=None if s_n == 400 else
       "substrate has no HTTP surface to define the container partition key "
       "(define_container/3 is not wired to any route), so pk header "
       "enforcement is inert; header mismatch is accepted with 201",
       us=int((time.time() - t0) * 1e6))

# ---------------------------------------------------------------------------
verdict = "PASS" if all(s["verdict"] == "PASS" for s in STEPS) else "FAIL"
receipt = {
    "scenario": "s8_cosmos_race",
    "endpoint": BASE,
    "transport": "azure-cosmos SDK attempted; raw loopback HTTP executed"
                 if not SDK else "azure-cosmos real SDK",
    "steps": STEPS,
    "verdict": verdict,
    "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
}
print("RECEIPT:" + json.dumps(receipt))
sys.exit(0 if verdict == "PASS" else 1)
