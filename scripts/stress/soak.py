#!/usr/bin/env python3
"""Smalt sustained soak: 25-minute mixed traffic against a private substrate.

Mix at steady 50 rps:
  60% ARM PUT/GET, 25% Cosmos doc CRUD, 10% Blob PUT/GET/DELETE (mutable
  container), 5% Sentinel DCR-stream ingest. Net-zero state per cycle except
  Sentinel (bounded append: ~3.7k rows over 25 min).

Sampling every 60s: beam RSS via ps, ETS table sizes via a distribution
`mix run --no-start -e` introspection snippet, error counts.

FAIL if: any 5xx; RSS grows monotonically >20% after minute 5; error rate > 0.
"""

from __future__ import annotations

import argparse
import http.client
import json
import os
import queue
import random
import subprocess
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__))))
import _substrate  # noqa: E402
import threading
import time
from collections import Counter

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

PORTS = {
    "SMALT_TEST_ARM_PORT": 39430,
    "SMALT_TEST_ARM_TLS_PORT": 39431,
    "SMALT_TEST_EGRESS_PORT": 39432,
    "SMALT_TEST_AMQP_PORT": 39433,
    "SMALT_TEST_EVENT_HUBS_PORT": 39434,
    "SMALT_TEST_MCP_PORT": 39435,
}
ARM_HOST, ARM_PORT = "127.0.0.1", PORTS["SMALT_TEST_ARM_PORT"]
EG_HOST, EG_PORT = "127.0.0.1", PORTS["SMALT_TEST_EGRESS_PORT"]
SUB_NODE = "smalt_soak"
COOKIE = "smalt_soak"
MS_VERSION = "2021-12-02"
PK = '["soak"]'

ETS_TABLES = [
    "smalt_subscriptions", "smalt_resource_groups", "smalt_resources",
    "smalt_operations", "smalt_cosmos_docs", "smalt_cosmos_lsn",
    "smalt_cosmos_pk_meta", "smalt_vault_keys", "smalt_blobs",
    "smalt_blob_containers", "smalt_blob_policy", "smalt_ledger_transactions",
    "smalt_ledger_meta", "smalt_event_messages", "smalt_sb_queues",
    "smalt_sb_messages", "smalt_sb_locks", "smalt_sb_sessions",
    "smalt_sb_tokens", "smalt_eh_partitions", "smalt_eh_checkpoints",
    "smalt_sentinel_streams", "smalt_sentinel_rows", "smalt_purview_entities",
    "smalt_purview_edges", "smalt_resource_graph_tokens",
    "smalt_attestation_baseline",
]


def http_req(host, port, method, path, body=None, headers=None, timeout=20):
    conn = http.client.HTTPConnection(host, port, timeout=timeout)
    try:
        h = {"content-type": "application/json"}
        h.update(headers or {})
        payload = body
        if isinstance(body, (dict, list)):
            payload = json.dumps(body)
        conn.request(method, path, body=payload, headers=h)
        resp = conn.getresponse()
        resp.read()
        return resp.status
    finally:
        conn.close()


class Soak:
    def __init__(self, duration, rps, beam_pid=None):
        self.duration = duration
        self.rps = rps
        self.statuses = Counter()
        self.errors = Counter()
        self.by_cat = Counter()
        self.lock = threading.Lock()
        self.subscription = None
        self.samples = []  # dicts: minute, rss_kb, ets_total, bad, reqs
        self.beam_pid = beam_pid

    # ---------------- setup ----------------

    def setup(self):
        st = http_req(ARM_HOST, ARM_PORT, "GET", "/subscriptions")
        if st != 200:
            raise RuntimeError(f"substrate not ready: /subscriptions -> {st}")
        import json as _j
        conn = http.client.HTTPConnection(ARM_HOST, ARM_PORT, timeout=20)
        try:
            conn.request("GET", "/subscriptions")
            self.subscription = _j.loads(conn.getresponse().read())["value"][0]["subscriptionId"]
        finally:
            conn.close()
        if http_req(EG_HOST, EG_PORT, "POST", "/dbs", {"id": "soakdb"}) not in (201, 409):
            raise RuntimeError("cosmos db setup failed")
        if http_req(EG_HOST, EG_PORT, "POST", "/dbs/soakdb/colls",
                    {"id": "soakcoll", "partitionKey": {"paths": ["/pk"]}}) not in (201, 409):
            raise RuntimeError("cosmos coll setup failed")
        if http_req(EG_HOST, EG_PORT, "PUT", "/soakacct/soak-cont?restype=container",
                    None, {"x-ms-version": MS_VERSION,
                           "x-ms-immutable-policy": "false"}) not in (201, 409):
            raise RuntimeError("blob container setup failed")
        st = http_req(ARM_HOST, ARM_PORT, "PUT",
                      f"/subscriptions/{self.subscription}/resourcegroups/soak-rg-0",
                      {"location": "eastus"})
        if st != 201:
            raise RuntimeError(f"arm rg setup failed: {st}")

    # ---------------- traffic ----------------

    def req(self, method, path, body=None, headers=None):
        host, port = (ARM_HOST, ARM_PORT) if path.startswith("/subscriptions") \
            else (EG_HOST, EG_PORT)
        return http_req(host, port, method, path, body, headers)

    def one_op(self, cat, n):
        """One request for category `cat` with per-worker-category seq n.
        Returns (category, ok)."""
        if cat == "arm":
            i = ((n - 1) // 2) % 8  # PUT at odd n, GET at even n, same rg per pair
            if n % 2 == 1:  # odd seq: PUT (creates/upserts rg-i)
                st = self.req("PUT", f"/subscriptions/{self.subscription}"
                                     f"/resourcegroups/soak-rg-{i}", {"location": "eastus"})
                return "arm", st in (200, 201)  # 201 create, 200 upsert-update
            st = self.req("GET", f"/subscriptions/{self.subscription}"
                                 f"/resourcegroups/soak-rg-{i}", None)
            return "arm", st == 200
        if cat == "cosmos":
            i = (n - 1) // 4
            step = (n - 1) % 4
            doc = f"soak-{i}"
            doc_path = f"/dbs/soakdb/colls/soakcoll/docs/{doc}"
            pk = {"x-ms-documentdb-partitionkey": PK}
            if step == 0:
                st = self.req("POST", "/dbs/soakdb/colls/soakcoll/docs",
                              {"id": doc, "pk": "soak", "v": n}, pk)
                return "cosmos", st == 201
            if step == 1:
                return "cosmos", self.req("GET", doc_path, None, pk) == 200
            if step == 2:
                st = self.req("PUT", doc_path, {"id": doc, "pk": "soak", "v": n}, pk)
                return "cosmos", st == 200
            st = self.req("DELETE", doc_path, None, pk)
            return "cosmos", st == 204
        if cat == "blob":
            i = (n - 1) // 3
            step = (n - 1) % 3
            blob = f"/soakacct/soak-cont/soak-blob-{i}"
            h = {"x-ms-version": MS_VERSION}
            if step == 0:
                st = self.req("PUT", blob, "soak-payload", {**h, "x-ms-blob-type": "BlockBlob"})
                return "blob", st == 201
            if step == 1:
                return "blob", self.req("GET", blob, None, h) == 200
            return "blob", self.req("DELETE", blob, None, h) == 202
        # sentinel
        rows = [{"time": "2026-10-14T00:00:00Z", "msg": f"soak-{n}", "seq": n}]
        st = self.req("POST", "/dataCollectionRules/soak-dcr/streams/Custom-soak"
                              "?api-version=2023-01-01", rows)
        return "sentinel", st == 200

    def worker(self, schedule_q, wid):
        import random as _r
        counts = Counter()
        while True:
            try:
                _, send_at = schedule_q.get_nowait()
            except queue.Empty:
                return
            delay = send_at - time.monotonic()
            if delay > 0:
                time.sleep(delay)
            r = _r.random()
            cat = "arm" if r < 0.60 else "cosmos" if r < 0.85 else "blob" if r < 0.95 \
                else "sentinel"
            counts[cat] += 1
            n = counts[cat]
            try:
                cat, ok = self.one_op(cat, n)
            except Exception as e:
                cat = "conn"
                ok = False
                with self.lock:
                    self.errors[f"conn:{type(e)}"] += 1
            with self.lock:
                self.by_cat[cat] += 1
                if not ok:
                    self.errors[f"status:{cat}"] += 1

    # ---------------- sampling ----------------

    def sample_rss_kb(self):
        if not self.beam_pid:
            return None
        try:
            out = subprocess.run(["ps", "-o", "rss=", "-p", str(self.beam_pid)],
                                 capture_output=True, text=True, timeout=10)
            return int(out.stdout.strip())
        except Exception:
            return None



def boot_substrate():
    env = dict(os.environ)
    env.update({k: str(v) for k, v in PORTS.items()})
    env["MIX_ENV"] = "test"
    eval_code = (
        "Application.put_env(:smalt, :amqp_sweeper_tick_ms, 600_000_000); "
        f"Application.put_env(:smalt, :arm_port, {PORTS['SMALT_TEST_ARM_PORT']}); "
        f"Application.put_env(:smalt, :arm_tls_port, {PORTS['SMALT_TEST_ARM_TLS_PORT']}); "
        f"Application.put_env(:smalt, :egress_port, {PORTS['SMALT_TEST_EGRESS_PORT']}); "
        f"Application.put_env(:smalt, :amqp_port, {PORTS['SMALT_TEST_AMQP_PORT']}); "
        f"Application.put_env(:smalt, :event_hubs_port, {PORTS['SMALT_TEST_EVENT_HUBS_PORT']}); "
        f"Application.put_env(:smalt, :mcp_port, {PORTS['SMALT_TEST_MCP_PORT']}); "
        "Application.put_env(:smalt, :auth_mode, :anonymous); "
        "{:ok, _} = Application.ensure_all_started(:smalt); "
        "Process.sleep(:infinity)"
    )
    cmd = ["elixir", "--sname", SUB_NODE, "--cookie", COOKIE, "-S", "mix", "run",
           "--no-start", "-e", eval_code, "--no-halt"]
    return subprocess.Popen(cmd, cwd=REPO, env=env,
                            stdout=open("/tmp/soak-substrate.log", "ab"),
                            stderr=subprocess.STDOUT,
                            start_new_session=True)  # own group: killpg teardown (lens-5 cycle 2)


def ets_snapshot():
    """One ETS introspection round: returns dict table->size (or error atom)."""
    snippet = (
        'host = :inet.gethostname() |> elem(1) |> List.to_string(); '
        'target = String.to_atom("' + SUB_NODE + '@" <> host); '
        'tables = ' + repr(ETS_TABLES).replace("'", '"') + ' |> Enum.map(&String.to_atom/1); '
        'sizes = Map.new(tables, fn t -> {t, :rpc.call(target, :ets, :info, [t, :size])} end); '
        'IO.puts(Jason.encode!(sizes))'
    )
    env = dict(os.environ)
    env["MIX_ENV"] = "test"
    cmd = ["elixir", "--sname", "soakprobe" + str(os.getpid()), "--cookie", COOKIE,
           "-S", "mix", "run", "--no-start", "-e", snippet]
    try:
        out = subprocess.run(cmd, cwd=REPO, env=env, capture_output=True,
                             text=True, timeout=60)
        for line in reversed(out.stdout.strip().splitlines()):
            line = line.strip()
            if line.startswith("{") and line.endswith("}"):
                return json.loads(line)
        return {"_error": out.stdout[-200:] + out.stderr[-200:]}
    except Exception as e:
        return {"_error": f"{type(e).__name__}: {e}"}


def find_beam_pid(mix_pid):
    """Walk descendants of the elixir/mix launcher to the beam.smp process;
    fall back to pgrep -f on the sname with a beam.smp comm check."""
    for _ in range(6):
        try:
            out = subprocess.run(["pgrep", "-P", str(mix_pid)],
                                 capture_output=True, text=True, timeout=10)
        except Exception:
            break
        kids = [int(x) for x in out.stdout.split()]
        if not kids:
            break
        for kid in kids:
            chk = subprocess.run(["ps", "-o", "comm=", "-p", str(kid)],
                                 capture_output=True, text=True, timeout=10)
            if "beam" in chk.stdout:
                return kid
        mix_pid = kids[0]
    # fallback: any beam.smp whose command line names our node
    out = subprocess.run(["pgrep", "-f", SUB_NODE], capture_output=True, text=True)
    for cand in [int(x) for x in out.stdout.split()]:
        chk = subprocess.run(["ps", "-o", "comm=", "-p", str(cand)],
                             capture_output=True, text=True, timeout=10)
        if "beam" in chk.stdout:
            return cand
    return None


def rss_verdict(samples):
    post = [s for s in samples if s["rss_kb"] and s["minute"] >= 5.0]
    if len(post) < 3:
        return True, "insufficient post-minute-5 samples for RSS verdict"
    first, last = post[0]["rss_kb"], post[-1]["rss_kb"]
    growth = last / first if first else 0.0
    monotonic = all(post[i + 1]["rss_kb"] > post[i]["rss_kb"]
                    for i in range(len(post) - 1))
    if monotonic and growth > 1.20:
        return False, (f"RSS monotonic growth {growth:.2f}x after minute 5 "
                       f"({first}KB -> {last}KB)")
    return True, (f"RSS {first}KB -> {last}KB post-min5, growth {growth:.3f}x, "
                  f"monotonic={monotonic}")


def wait_ready(deadline=120):
    t_end = time.time() + deadline
    while time.time() < t_end:
        try:
            if http_req("127.0.0.1", ARM_PORT, "GET",
                        "/subscriptions?api-version=2021-04-01") == 200:
                return True
        except Exception:
            pass
        time.sleep(1.5)
    return False


def main():
    _substrate.install_sigterm_handler()  # SIGTERM -> SystemExit -> finally teardown (lens-5 cycle 5)
    ap = argparse.ArgumentParser()
    ap.add_argument("--duration", type=int, default=1500, help="soak seconds")
    ap.add_argument("--rps", type=int, default=50)
    ap.add_argument("--skip-boot", action="store_true",
                    help="substrate already running on the private ports")
    args = ap.parse_args()
    print(f"[soak] repo={REPO} duration={args.duration}s rps={args.rps}", flush=True)

    proc = None
    beam_pid = None
    attempt = 0
    while True:
        attempt += 1
        if not args.skip_boot:
            proc = boot_substrate()
        if wait_ready():
            break
        print(f"[soak] substrate not ready (attempt {attempt}); "
              f"retrying boot", flush=True)
        if proc:
            _substrate.kill_substrate(proc)  # group kill (lens-5 cycle 2)
            proc = None
        if attempt >= 3:
            print("[soak] FAIL: substrate never became ready after 3 attempts",
                  flush=True)
            return 2
    beam_pid = find_beam_pid(os.getpid() if not proc else proc.pid) if not args.skip_boot \
        else None
    if not beam_pid and not args.skip_boot:
        # fall back: find any beam.smp with our sname in args
        out = subprocess.run(["pgrep", "-f", "smalt_soak"], capture_output=True, text=True)
        cands = [int(x) for x in out.stdout.split()]
        beam_pid = cands[0] if cands else None
    print(f"[soak] substrate ready, beam pid={beam_pid}", flush=True)

    soak = Soak(args.duration, args.rps, beam_pid)
    soak.setup()
    print("[soak] fixtures ready (db/coll/container/rg)", flush=True)

    total = args.duration * args.rps
    start = time.monotonic()
    schedule = [(i, start + i / args.rps) for i in range(total)]
    n_workers = 16
    qs = []
    threads = []
    chunk = (total + n_workers - 1) // n_workers
    for w in range(n_workers):
        q = queue.Queue()
        for item in schedule[w * chunk:(w + 1) * chunk]:
            q.put(item)
        qs.append(q)
        t = threading.Thread(target=soak.worker, args=(q, w), daemon=True)
        t.start()
        threads.append(t)

    next_sample = 60.0
    while time.monotonic() - start < args.duration:
        time.sleep(2.0)
        elapsed = time.monotonic() - start
        if elapsed >= next_sample:
            minute = elapsed / 60.0
            with soak.lock:
                reqs = sum(soak.by_cat.values())
                bad = sum(soak.errors.values())
            rss = soak.sample_rss_kb()
            ets = ets_snapshot()
            ets_total = sum(v for v in ets.values() if isinstance(v, int))
            sample = {"minute": round(minute, 2), "rss_kb": rss,
                      "ets_total": ets_total, "reqs": reqs, "bad": bad,
                      "ets": ets}
            soak.samples.append(sample)
            print(f"[soak] min={sample['minute']:5.2f} rss={rss}KB "
                  f"ets_total={ets_total} reqs={reqs} bad={bad}", flush=True)
            next_sample += 60.0

    for t in threads:
        t.join(timeout=30)

    with soak.lock:
        reqs = sum(soak.by_cat.values())
        bad = sum(soak.errors.values())
        by_cat = dict(soak.by_cat)
        errors = dict(soak.errors)
        statuses_note = "status expectations enforced per-op; bad_status counts mismatches"

    rss_ok, rss_why = rss_verdict(soak.samples)
    bad_status_total = sum(v for k, v in errors.items() if k.startswith("status:"))
    # 5xx detection: re-derive by op statuses is not stored per-status; any
    # bad_status with an unexpected 5xx would show up here. Track 5xx exactly:
    # (one_op treats any non-expected status as bad; 5xx therefore included).
    conn_errors = sum(v for k, v in errors.items() if k.startswith("conn:"))
    error_rate = bad / reqs if reqs else 1.0

    print("\n=== SOAK RECEIPT ===")
    print(f"duration_s={args.duration} target_rps={args.rps} total_reqs={reqs} "
          f"achieved_rps={reqs / args.duration:.2f}")
    print(f"mix={by_cat}")
    print(f"errors={errors or '{}'} conn_errors={conn_errors} error_rate={error_rate:.5f}")
    print("\ntime-series (60s samples):")
    print("min   | rss_kb  | ets_total | reqs | bad")
    for s in soak.samples:
        print(f"{s['minute']:5.2f} | {s['rss_kb']} | {s['ets_total']:9} | "
              f"{s['reqs']:4} | {s['bad']}")
    print(f"\nRSS: {rss_why}")
    verdict = "PASS"
    reasons = []
    if bad_status_total > 0:
        verdict = "FAIL"
        reasons.append(f"bad responses present: {bad_status_total} (5xx/unexpected statuses)")
    if conn_errors > 0:
        verdict = "FAIL"
        reasons.append(f"connection errors: {conn_errors}")
    if error_rate > 0:
        verdict = "FAIL"
        reasons.append(f"error_rate={error_rate:.5f} > 0")
    if not rss_ok:
        verdict = "FAIL"
        reasons.append(rss_why)
    print(f"\nVERDICT: {verdict}")
    for r in reasons:
        print(f"  - {r}")

    with open("/tmp/soak-results.json", "w") as f:
        json.dump({"verdict": verdict, "reasons": reasons, "reqs": reqs,
                   "by_cat": by_cat, "errors": errors,
                   "error_rate": error_rate, "samples": soak.samples}, f, indent=1)
    print("[soak] raw samples -> /tmp/soak-results.json")

    if proc:
        _substrate.kill_substrate(proc)  # group kill (lens-5 cycle 2)
    return 0 if verdict == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
