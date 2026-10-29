#!/usr/bin/env python3
"""SQLD-3 — SQLite ingestion court (real sqlite3 CLI + real duckdb CLI).

Legs:
  1. Generate a deterministic synthetic-events sqlite .db via the sqlite3 CLI.
  2. ATTACH it in duckdb via the sqlite extension (TYPE sqlite).
  3. Project to OCEL v2 CSVs (events / objects / relationships).
  4. Court:
     a. exact row counts (sqlite == duckdb-over-attach == OCEL projection);
     b. query parity: identical per-object_type aggregate from the sqlite3 CLI
        and duckdb-over-attach;
     c. SHACL-shaped structural gate on the projected AST TTL, then the
        parity queries are compiled FROM that AST.

Deterministic: fixed LCG seed, no wall-clock inputs. Chicago-style: real
subprocess CLIs, asserts on observed state, no mocks.

Exit 0 = PASS, 1 = FAIL, 3 = SKIP (sqlite extension unavailable).
"""

import hashlib
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TMP = os.path.join(ROOT, "tmp", "sqlite_court")
DB = os.path.join(TMP, "events.db")
AST = os.path.join(TMP, "projection_ast.ttl")

SQLITE3 = "/usr/bin/sqlite3"
DUCKDB = "/opt/homebrew/bin/duckdb"

N_OBJECTS = 60
N_EVENTS = 900


def sh(cmd, stdin=None):
    p = subprocess.run(cmd, input=stdin, capture_output=True, text=True)
    if p.returncode != 0:
        raise RuntimeError(f"{cmd} exited {p.returncode}: {p.stderr.strip()}")
    return p.stdout


# ---------------------------------------------------------------- corpus
class LCG:
    """Deterministic PRNG (fixed seed; identical corpus every run)."""

    def __init__(self, seed=20261021):
        self.s = seed

    def next(self):
        self.s = (self.s * 6364136223846793005 + 1442695040888963407) % (2**64)
        return self.s >> 16

    def pick(self, xs):
        return xs[self.next() % len(xs)]


def generate_db():
    os.makedirs(TMP, exist_ok=True)
    if os.path.exists(DB):
        os.remove(DB)
    rng = LCG()
    object_types = ["freezer", "conveyor", "pallet"]
    activities = ["temp_reading", "door_open", "batch_load", "defrost_cycle"]
    sites = ["S1", "S2"]
    objs, evs = [], []
    for i in range(N_OBJECTS):
        objs.append((f"obj-{i:03d}", object_types[i % 3], sites[i % 2]))
    for j in range(N_EVENTS):
        obj = objs[rng.next() % N_OBJECTS]
        oid = obj[0]
        act = rng.pick(activities)
        temp = -22 + (rng.next() % 600) / 10.0  # -22.0 .. 37.9
        dur = rng.next() % 900
        evs.append((f"ev-{j:04d}", 1700000000 + j * 7, act, oid, round(temp, 1), dur))
    stmts = ["PRAGMA journal_mode=DELETE;",
             "CREATE TABLE objects (object_id TEXT PRIMARY KEY,"
             " object_type TEXT NOT NULL, site TEXT NOT NULL);",
             "CREATE TABLE events (event_id TEXT PRIMARY KEY, ts INTEGER NOT NULL,"
             " activity TEXT NOT NULL, object_id TEXT NOT NULL REFERENCES objects,"
             " temp REAL, duration INTEGER);",
             "BEGIN;"]
    stmts += ["INSERT INTO objects VALUES ('%s','%s','%s');" % o for o in objs]
    stmts += ["INSERT INTO events VALUES ('%s',%d,'%s','%s',%.1f,%d);" % e for e in evs]
    stmts.append("COMMIT;")
    sh([SQLITE3, DB], stdin="\n".join(stmts))
    return objs, evs


# ---------------------------------------------------------------- AST + SHACL
def write_ast():
    ttl = """@prefix sql: <https://smalt.local/sql#> .
@prefix ocel: <https://smalt.local/ocel#> .

<http://example/projection> a ocel:Projection ;
    sql:sourceDb "events.db" ;
    sql:tables "events", "objects" ;
    sql:eventsTable "events" ;
    sql:objectsTable "objects" ;
    sql:joinColumn "object_id" ;
    ocel:eventKey "event_id" ;
    ocel:objectKey "object_id" ;
    ocel:activityField "activity" ;
    ocel:timestampField "ts" .
"""
    with open(AST, "w") as f:
        f.write(ttl)


IDENT = re.compile(r"^[a-zA-Z_][a-zA-Z0-9_.]*$")


def shacl_gate(objs, evs):
    """SHACL-shaped structural gate on the AST; raises on violation."""
    with open(AST) as f:
        ttl = f.read()

    def get(prop):
        m = re.search(rf"{prop}\s+\"([^\"]+)\"", ttl)
        assert m, f"SHACL: missing required property {prop}"
        return m.group(1)

    tables_blob = re.search(r'sql:tables\s+([^;]+);', ttl)
    assert tables_blob, "SHACL: sql:tables property missing"
    tables = re.findall(r'"([^"]+)"', tables_blob.group(1))
    assert len(tables) >= 2, "SHACL: sql:tables must list >= 2 tables"
    for t in tables + [get("sql:eventsTable"), get("sql:objectsTable"),
                       get("sql:joinColumn"), get("ocel:eventKey"),
                       get("ocel:objectKey"), get("ocel:activityField"),
                       get("ocel:timestampField"), get("sql:sourceDb")]:
        assert IDENT.match(t), f"SHACL: bad identifier {t!r}"
    assert ttl.count("a ocel:Projection") == 1, "SHACL: exactly one Projection node"
    assert len(objs) == N_OBJECTS and len(evs) == N_EVENTS, "SHACL: cardinality"
    return True


# ---------------------------------------------------------------- projection
def project_to_ocel():
    """duckdb-over-sqlite-attach -> OCEL v2 CSVs."""
    q = f"""
    LOAD sqlite_scanner;
    ATTACH '{DB}' AS sqlitedb (TYPE sqlite);
    COPY (
      SELECT e.event_id AS event_id, e.ts AS ts, e.activity AS activity,
             o.object_id AS object_id, o.object_type AS object_type,
             e.temp AS temp, e.duration AS duration
      FROM sqlitedb.events e JOIN sqlitedb.objects o USING (object_id)
      ORDER BY e.event_id
    ) TO '{TMP}/ocel_events.csv' (HEADER, DELIMITER ',');
    COPY (
      SELECT object_id, object_type, site FROM sqlitedb.objects ORDER BY object_id
    ) TO '{TMP}/ocel_objects.csv' (HEADER, DELIMITER ',');
    COPY (
      SELECT e.event_id, o.object_id, 'performed_on' AS qualifier
      FROM sqlitedb.events e JOIN sqlitedb.objects o USING (object_id)
      ORDER BY e.event_id
    ) TO '{TMP}/ocel_relationships.csv' (HEADER, DELIMITER ',');
    """
    sh([DUCKDB, "-noheader", "-c", q])
    return (os.path.join(TMP, "ocel_events.csv"),
            os.path.join(TMP, "ocel_objects.csv"),
            os.path.join(TMP, "ocel_relationships.csv"))


def read_csv_rows(path):
    with open(path) as f:
        lines = [l.rstrip("\n").split(",") for l in f if l.strip()]
    return [dict(zip(lines[0], row)) for row in lines[1:]]


AGG = ("SELECT o.object_type AS object_type, COUNT(*) AS n_events, "
       "SUM(e.duration) AS total_duration, MAX(e.temp) AS max_temp, "
       "ROUND(AVG(e.temp), 4) AS avg_temp "
       "FROM {evt} e JOIN {obt} o USING (object_id) "
       "GROUP BY o.object_type ORDER BY o.object_type")


def main():
    print("SQLD-3 SQLITE INGESTION COURT")
    print(f"sqlite3: {sh([SQLITE3, '--version']).strip()}")
    print(f"duckdb:  {sh([DUCKDB, '--version']).strip()}")

    # 0. extension availability (typed SKIP if absent)
    ext = sh([DUCKDB, "-noheader", "-csv", "-c",
              "SELECT extension_name, installed, loaded FROM duckdb_extensions() "
              "WHERE extension_name='sqlite_scanner'"]).strip()
    print(f"extension row: {ext}")
    if not ext:
        print("SKIP: sqlite_scanner not in duckdb_extensions(); "
              "install with: duckdb -c 'INSTALL sqlite_scanner'")
        return 3
    fields = ext.split(",")
    if fields[1] != "true":
        print(f"SKIP: sqlite_scanner present but installed={fields[1]}; "
              "install with: duckdb -c 'INSTALL sqlite_scanner'")
        return 3

    # 1. generate
    objs, evs = generate_db()
    print(f"generated {DB}: {len(objs)} objects, {len(evs)} events")

    # 2. project via duckdb sqlite extension
    ev_csv, ob_csv, rel_csv = project_to_ocel()
    ocel_ev, ocel_ob, ocel_rel = (read_csv_rows(ev_csv), read_csv_rows(ob_csv),
                                  read_csv_rows(rel_csv))

    # 3a. exact row counts, three ways
    src_counts = sh([SQLITE3, DB,
                     "SELECT (SELECT COUNT(*) FROM events),"
                     " (SELECT COUNT(*) FROM objects);"]).strip().split("|")
    duck_counts = sh([DUCKDB, "-noheader", "-csv", "-c",
                      f"LOAD sqlite_scanner; ATTACH '{DB}' AS s (TYPE sqlite); "
                      "SELECT (SELECT COUNT(*) FROM s.events), "
                      "(SELECT COUNT(*) FROM s.objects);"]).strip().split(",")
    assert int(src_counts[0]) == int(duck_counts[0]) == len(ocel_ev) == N_EVENTS, \
        f"event count mismatch: {src_counts} vs {duck_counts} vs {len(ocel_ev)}"
    assert int(src_counts[1]) == int(duck_counts[1]) == len(ocel_ob) == N_OBJECTS, \
        "object count mismatch"
    assert len(ocel_rel) == N_EVENTS, "relationship count mismatch"
    assert all(r["object_id"] and r["qualifier"] == "performed_on" for r in ocel_rel), \
        "relationship shape violation"
    print(f"row counts exact: events={N_EVENTS} objects={N_OBJECTS} "
          f"rels={len(ocel_rel)}")

    # 3b. query parity, same aggregate over both engines
    s_agg = sh([SQLITE3, "-separator", "|", DB,
                AGG.format(evt="events", obt="objects")]).strip()
    q = (f"LOAD sqlite_scanner; ATTACH '{DB}' AS s (TYPE sqlite); "
         + AGG.format(evt="s.events", obt="s.objects") + ";")
    out = sh([DUCKDB, "-noheader", "-csv", "-c", q]).strip()
    d_agg = "\n".join("|".join(l.split(",")) for l in out.splitlines())
    assert s_agg == d_agg, \
        f"parity mismatch:\nsqlite:\n{s_agg}\nduckdb:\n{d_agg}"
    print("query parity (sqlite3 CLI vs duckdb-over-attach): EXACT")
    print(s_agg)
    src_norm = s_agg

    # OCEL projection parity: same aggregate recomputed from projected CSVs
    q2 = (f"CREATE TABLE oc_ev AS SELECT * FROM read_csv_auto('{ev_csv}'); "
          f"CREATE TABLE oc_ob AS SELECT * FROM read_csv_auto('{ob_csv}'); "
          + AGG.format(evt="oc_ev", obt="oc_ob") + ";")
    out = sh([DUCKDB, "-noheader", "-csv", "-c",
              f"LOAD sqlite_scanner; ATTACH '{DB}' AS s (TYPE sqlite); {q2}"]).strip()
    ocel_rows = "\n".join("|".join(l.split(",")) for l in out.splitlines())
    assert ocel_rows == src_norm, \
        f"OCEL projection parity mismatch:\n{ocel_rows}\nvs\n{src_norm}"
    print("OCEL projection parity (aggregate from projected CSVs == source): EXACT")

    # 3c. SHACL gate on the AST, then parity query compiled FROM the AST
    write_ast()
    shacl_gate(objs, evs)
    with open(AST) as f:
        ttl = f.read()
    ev_table = re.search(r'sql:eventsTable\s+"([^"]+)"', ttl).group(1)
    ob_table = re.search(r'sql:objectsTable\s+"([^"]+)"', ttl).group(1)
    join_col = re.search(r'sql:joinColumn\s+"([^"]+)"', ttl).group(1)
    ast_query = AGG.format(evt=f"s.{ev_table}", obt=f"s.{ob_table}").replace(
        "USING (object_id)", f"USING ({join_col})")
    out = sh([DUCKDB, "-noheader", "-csv", "-c",
              f"LOAD sqlite_scanner; ATTACH '{DB}' AS s (TYPE sqlite); "
              + ast_query + ";"]).strip()
    ast_rows = "\n".join("|".join(l.split(",")) for l in out.splitlines())
    assert ast_rows == src_norm, "AST-compiled query parity mismatch"
    print("SHACL gate on projected AST: PASS; AST-compiled parity query: EXACT")

    digest = hashlib.sha256(
        (s_agg + d_agg + ast_rows + ocel_rows + open(ev_csv).read()).encode()
    ).hexdigest()
    print("COURT RESULT: PASS")
    print(f"audit_hash: {digest}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
