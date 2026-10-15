#!/usr/bin/env python3
"""vs_azurite.py — honest smalt-vs-Azurite blob-plane benchmark.

Identical client code (vendored @azure/storage-blob via SMALT_SDK_ROOT) runs
against:
  (a) smalt  egress blob plane, http://127.0.0.1:8443/{account}
  (b) Azurite blob endpoint,    http://127.0.0.1:10000/devstoreaccount1

Workloads (sequential, per-op latency recorded, p50/p95 reported):
  - container create  x50
  - 1KB blob PUT      x500
  - blob GET          x500
  - container list    x50

Boot-to-ready is also measured for each substrate:
  - Azurite: `docker run -d` -> first successful List Containers (HTTP 200)
  - smalt:   `mix run --no-halt` spawn -> first successful List Containers

Fail-closed: if Azurite (docker) is unreachable, the report prints a
DOCUMENT-UNAVAILABLE section and the receipt records azurite: unavailable.
No synthetic azurite numbers are ever produced.

Usage:
  python3 scripts/stress/vs_azurite.py [--keep-containers] [--keep-smalt]

Exit codes: 0 = both legs produced; 1 = azurite leg unavailable (smalt leg
still runs); 2 = smalt leg failed.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PID_FILE = "/tmp/smalt.pid"

SMALT_ARM_PORT = int(os.environ.get("SMALT_VSAZ_ARM_PORT", "39500"))
SMALT_TLS_PORT = int(os.environ.get("SMALT_VSAZ_TLS_PORT", "39501"))
SMALT_URL = "http://127.0.0.1:8443"
SMALT_ACCOUNT = "smaltacct"
SMALT_KEY = "smaltacct-key"

AZ_CONTAINER = "vs-azurite-bench"
AZ_PORT = 10000
AZ_URL = f"http://127.0.0.1:{AZ_PORT}"
AZ_ACCOUNT = "devstoreaccount1"
AZ_KEY = (
    "Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/"
    "K1SZFPTOtr/KBHBeksoGMGw=="
)

DOCKER = shutil.which("docker") or "docker"
DOCKER_CONTEXT = "colima"

NODE_CLIENT_JS = r'''
"use strict";
// Generated at runtime by vs_azurite.py — identical client code for both targets.
const path = require("node:path");
const {
  BlobServiceClient, StorageSharedKeyCredential, PipelinePolicy,
} = require(path.join(process.env.SMALT_SDK_ROOT, "@azure/storage-blob"));

// Pin x-ms-version for BOTH targets: the vendored SDK sends 2026-10-06 which
// current Azurite cannot canonicalize (signature mismatch), while smalt
// accepts any version. Same policy, same client code, both targets.
const PINNED_VERSION = "2021-12-02";
const versionPin = {
  name: "versionPin",
  sendRequest(request, next) {
    request.headers.set("x-ms-version", PINNED_VERSION);
    return next(request);
  },
};

const URL = process.env.BENCH_URL;
const ACCOUNT = process.env.BENCH_ACCOUNT;
const KEY = process.env.BENCH_KEY;
const TAG = process.env.BENCH_TAG || "vsazurite";
const CREATE_N = 50, PUT_N = 500, GET_N = 500, LIST_N = 50;

function now() { return Number(process.hrtime.bigint()) / 1e6; }

(async () => {
  const service = new BlobServiceClient(
    `${URL}/${ACCOUNT}`,
    new StorageSharedKeyCredential(ACCOUNT, KEY),
    { policies: [versionPin] },
  );
  const samples = { create: [], put: [], get: [], list: [] };
  const errors = [];
  const runTag = `${TAG}-${Date.now()}`;

  async function timed(label, fn) {
    const t0 = now();
    try {
      await fn();
      samples[label].push(now() - t0);
    } catch (e) {
      errors.push(`${label}: ${(e && e.message) || String(e)}`.slice(0, 200));
    }
  }

  // container create x50
  const runContainers = [];
  for (let i = 0; i < CREATE_N; i++) {
    const c = service.getContainerClient(`${runTag}-c${i}`);
    runContainers.push(c);
    await timed("create", () => c.create({ abortSignal: AbortSignal.timeout(30_000) }));
  }

  // 1KB PUT x500 into a holder container — each PUT is a FRESH unique blob
  // (create-new, not overwrite): smalt's default container policy is
  // WORM-immutable (documented stricter-than-azurite default), so overwrites
  // would be refused there but not on azurite. Fresh-blob puts are identical
  // semantics on both targets.
  const holder = service.getContainerClient(`${runTag}-holder`);
  await holder.create({ abortSignal: AbortSignal.timeout(30_000) });
  runContainers.push(holder);
  const payload = Buffer.alloc(1024, 0x73);
  const blob0 = holder.getBlockBlobClient("bench-blob-0");
  for (let i = 0; i < PUT_N; i++) {
    const b = holder.getBlockBlobClient(`bench-blob-${i}`);
    await timed("put", () => b.upload(payload, payload.length, {
      abortSignal: AbortSignal.timeout(30_000),
    }));
  }

  // GET x500 (the first written blob; immutable containers allow reads)
  for (let i = 0; i < GET_N; i++) {
    await timed("get", () => blob0.downloadToBuffer(undefined, undefined, {
      abortSignal: AbortSignal.timeout(30_000),
    }));
  }

  // list x50 — list blobs in the holder container
  for (let i = 0; i < LIST_N; i++) {
    await timed("list", async () => {
      for await (const _ of holder.listBlobsFlat()) break;
    });
  }

  function summarize(arr) {
    const xs = arr.filter(Number.isFinite).sort((a, b) => a - b);
    const p = (q) => (xs.length ? xs[Math.min(xs.length - 1, Math.floor(q * xs.length))] : null);
    const out = {
      n_recorded: xs.length,
      n_errors: arr.length - xs.length,
      p50_ms: p(0.50),
      p95_ms: p(0.95),
    };
    if (xs.length) out.mean_ms = Math.round(xs.reduce((a, b) => a + b, 0) / xs.length * 1000) / 1000;
    return out;
  }

  const summary = {};
  for (const k of Object.keys(samples)) summary[k] = summarize(samples[k]);
  process.stdout.write(JSON.stringify({ summary, first_errors: errors.slice(0, 5) }));
})().catch((e) => { console.error("CLIENT FATAL:", e && e.message); process.exit(2); });
'''


def docker_cmd(*args: str) -> list:
    return [DOCKER, "--context", DOCKER_CONTEXT, *args]


def http_get_status(url: str, timeout: float = 2.0):
    try:
        req = urllib.request.Request(url, method="GET")
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status
    except urllib.error.HTTPError as e:  # type: ignore[attr-defined]
        return e.code
    except Exception:
        return None


# smalt ready = passed the Bearer plug (anonymous mode): 200/201/400.
# 401/403 means a FOREIGN enforce-mode substrate answered — never "ready" here.
SMALT_READY = (200, 201, 400)
AZ_READY = (200, 201, 403)  # azurite: 403 = up, auth enforced


def probe_ready(target: str, url: str | None = None) -> bool:
    if target == "smalt":
        return http_get_status(f"{url or SMALT_URL}/{SMALT_ACCOUNT}/?comp=list") in SMALT_READY
    return http_get_status(f"{AZ_URL}/devstoreaccount1?comp=list&restype=container") in AZ_READY


def wait_ready(target: str, deadline_s: float, url: str | None = None) -> float | None:
    """Poll until ready; return boot-to-ready seconds, or None on timeout."""
    t0 = time.monotonic()
    while time.monotonic() - t0 < deadline_s:
        if probe_ready(target, url):
            return time.monotonic() - t0
        time.sleep(0.1)
    return None


def azurite_up(keep: bool) -> dict:
    receipt = {"container": AZ_CONTAINER, "image": "mcr.microsoft.com/azure-storage/azurite:latest"}
    # reuse check
    state = subprocess.run(docker_cmd("inspect", "-f", "{{.State.Running}}", AZ_CONTAINER),
                           capture_output=True, text=True)
    if state.returncode == 0 and state.stdout.strip() == "true":
        receipt["mode"] = "already-running (boot time not measured this run)"
        receipt["ready"] = True
        return receipt
    if subprocess.run(docker_cmd("rm", "-f", AZ_CONTAINER), capture_output=True).returncode not in (0, 1):
        pass  # best-effort cleanup
    try:
        t0 = time.monotonic()
        subprocess.run(
            docker_cmd("run", "-d", "--rm", "--name", AZ_CONTAINER,
                       "-p", f"127.0.0.1:{AZ_PORT}:10000",
                       "mcr.microsoft.com/azure-storage/azurite:latest",
                       # vendored SDK sends api-version 2026-10-06; current
                       # azurite release tops out lower — skip, not fake.
                       # blobHost 0.0.0.0 required for the docker port forward.
                       "azurite", "--skipApiVersionCheck", "--blobHost", "0.0.0.0"),
            check=True, capture_output=True, text=True, timeout=120,
        )
    except Exception as e:
        receipt["error"] = f"docker run failed: {e}"
        receipt["ready"] = False
        return receipt
    boot = wait_ready("azurite", 90.0)
    receipt["boot_to_ready_s"] = boot
    receipt["ready"] = boot is not None
    return receipt


def azurite_down() -> None:
    subprocess.run(docker_cmd("rm", "-f", AZ_CONTAINER), capture_output=True)


def smalt_up(keep: bool) -> dict:
    receipt = {"url": SMALT_URL, "account": SMALT_ACCOUNT}
    if http_get_status(f"{SMALT_URL}/{SMALT_ACCOUNT}/?comp=list") is not None:
        # Port 8443 held by a foreign substrate (another lane's `just up` or
        # test tier, possibly enforce-mode). Never disturb it: boot a private
        # instance on the fallback port and bench against that.
        receipt["mode"] = ("port 8443 held by another process; booted private "
                           "instance on fallback port 39502 for boot+bench")
        return _smalt_boot(39502, receipt)
    if not os.path.isfile(os.path.join(REPO, "mix.exs")):
        receipt["error"] = "mix.exs not found"
        receipt["ready"] = False
        return receipt
    return _smalt_boot(8443, receipt)


def _smalt_boot(port: int, receipt: dict) -> dict:
    # Full six-listener scope (arm/tls/egress/amqp/event-hubs/mcp) on the
    # harness's documented private block (DEV_LOOP table). An unscoped
    # listener falls back to its default (9444/9545/5672) and the boot dies
    # eaddrinuse when a sibling holds it — witnessed class, lens-2 cycle 2/4.
    amqp = int(os.environ.get("SMALT_VSAZ_AMQP_PORT", "39503"))
    eh = amqp + 1
    mcp = int(os.environ.get("SMALT_VSAZ_MCP_PORT", "39505"))
    env = dict(os.environ)
    env.setdefault("SMALT_SB_SHARED_KEY",
                   subprocess.run(["bash", "-c",
                                   'printf \'%s\' "$(hostname)smalt-dev-sb" | openssl dgst -sha256 -binary | base64'],
                                  capture_output=True, text=True).stdout.strip())
    log_path = f"/tmp/vs_azurite_smalt_{port}.log"
    log = open(log_path, "w")
    eval_expr = (
        f'Application.put_env(:smalt, :egress_port, {port}); '
        # Documented SDK-tier auth config (config/test.exs, test/sdk-smoke):
        # enforce mode rejects SharedKey with MalformedBearerHeader and the JS
        # SDK cannot inject the smalt STS Bearer on plain HTTP, so the repo's
        # own SDK tiers run :anonymous. The bench matches that contract.
        'Application.put_env(:smalt, :auth_mode, :anonymous); '
        f'Application.put_env(:smalt, :arm_port, {SMALT_ARM_PORT}); '
        f'Application.put_env(:smalt, :arm_tls_port, {SMALT_TLS_PORT}); '
        f'Application.put_env(:smalt, :amqp_port, {amqp}); '
        f'Application.put_env(:smalt, :event_hubs_port, {eh}); '
        f'Application.put_env(:smalt, :mcp_port, {mcp}); '
        f'{{:ok, _}} = Application.ensure_all_started(:smalt); '
        f'IO.puts("smalt bench ready on {port}"); '
        'Process.sleep(:infinity)'
    )
    t0 = time.monotonic()
    proc = subprocess.Popen(["mix", "run", "--no-start", "--eval", eval_expr],
                            cwd=REPO, env=env, stdout=log, stderr=subprocess.STDOUT)
    boot = wait_ready("smalt", 120.0, url=f"http://127.0.0.1:{port}")
    elapsed = time.monotonic() - t0
    if boot is None:
        proc.terminate(); proc.wait(timeout=15)
        log.close()
        receipt["error"] = f"smalt did not become ready in {elapsed:.1f}s (log: {log_path})"
        receipt["ready"] = False
        return receipt
    receipt["url"] = f"http://127.0.0.1:{port}"
    receipt["boot_to_ready_s"] = boot
    receipt["ready"] = True
    receipt["_proc"] = proc
    receipt["_log"] = log
    return receipt


def smalt_down(receipt: dict) -> None:
    proc = receipt.get("_proc")
    if proc is None:
        return
    try:
        proc.terminate()
        proc.wait(timeout=15)
    except Exception:
        try:
            proc.kill()
        except Exception:
            pass
    receipt.get("_log") and receipt["_log"].close()


def run_bench(target: str, url: str, account: str, key: str) -> dict:
    js_path = "/tmp/vs_azurite_client.js"
    with open(js_path, "w") as f:
        f.write(NODE_CLIENT_JS)
    sdk_root = os.environ.get("SMALT_SDK_ROOT", "/Users/sac/cai/athena/playground/node_modules")
    env = dict(os.environ)
    env.update({
        "SMALT_SDK_ROOT": sdk_root,
        "BENCH_URL": url, "BENCH_ACCOUNT": account, "BENCH_KEY": key,
        "BENCH_TAG": target,
    })
    t0 = time.monotonic()
    r = subprocess.run(["node", js_path], capture_output=True, text=True, timeout=600, env=env)
    out = {
        "target": target, "url": url, "node_exit": r.returncode,
        "wall_s": round(time.monotonic() - t0, 2),
    }
    if r.returncode == 0:
        try:
            out.update(json.loads(r.stdout))
        except json.JSONDecodeError:
            out["error"] = "unparseable client output"
            out["error_text"] = r.stdout[-500:] + r.stderr[-500:]
    else:
        out["error"] = "client failed"
        out["error_text"] = (r.stderr[-800:])
    return out


def fmt_row(op: str, res: dict) -> str:
    s = res.get("summary", {}).get(op)
    if not s or s["p50_ms"] is None:
        return f"| {op} | — | — | — | ERROR |"
    return (f"| {op} | {s['n_recorded']}/{s['n_recorded'] + s['n_errors']} | "
            f"{s['p50_ms']:.1f} | {s['p95_ms']:.1f} | ok |")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--keep-azurite", action="store_true")
    ap.add_argument("--keep-smalt", action="store_true")
    args = ap.parse_args()

    sdk_root = os.environ.get("SMALT_SDK_ROOT", "/Users/sac/cai/athena/playground/node_modules")
    if not os.path.isdir(os.path.join(sdk_root, "@azure", "storage-blob")):
        print(f"[vs_azurite] ERROR: no @azure/storage-blob under {sdk_root} "
              f"(set SMALT_SDK_ROOT)", file=sys.stderr)
        return 2
    node = shutil.which("node")
    if not node:
        print("[vs_azurite] ERROR: node not on PATH", file=sys.stderr)
        return 2

    smalt_receipt = smalt_up(args.keep_smalt)
    az_receipt = None
    try:
        az_receipt = azurite_up(args.keep_azurite)
        bench_az = run_bench("azurite", AZ_URL, AZ_ACCOUNT, AZ_KEY) if az_receipt.get("ready") else None
    finally:
        pass

    bench_smalt = run_bench("smalt", smalt_receipt.get("url", SMALT_URL),
                            SMALT_ACCOUNT, SMALT_KEY) if smalt_receipt.get("ready") else None

    if not args.keep_azurite:
        azurite_down()

    receipt = {
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "host": os.uname().nodename,
        "sdk": os.path.join(sdk_root, "@azure", "storage-blob"),
        "workloads": {"container_create": 50, "put_1kb": 500, "get": 500, "list": 50},
        "boot": {"smalt": {k: v for k, v in smalt_receipt.items() if not k.startswith("_")},
                 "azurite": az_receipt},
        "results": {"smalt": bench_smalt, "azurite": bench_az},
    }
    out_path = "/tmp/vs_azurite_receipt.json"
    with open(out_path, "w") as f:
        json.dump(receipt, f, indent=2)

    # ---- report ----
    print("=" * 72)
    print("smalt vs Azurite — blob plane (identical vendored @azure/storage-blob client)")
    print("=" * 72)
    for name, r in (("smalt (8443)", smalt_receipt), ("azurite (10000)", az_receipt or {})):
        status = "READY" if r.get("ready") else "UNAVAILABLE"
        boot = r.get("boot_to_ready_s")
        boot_s = f"{boot:.2f}s" if boot is not None else "n/a"
        print(f"{name}: {status}  boot_to_ready={boot_s}  mode={r.get('mode', 'started-by-script')}")
        if r.get("error"):
            print(f"  error: {r['error']}")
    print()
    for name, res in (("smalt", bench_smalt), ("azurite", bench_az)):
        if res is None:
            print(f"--- {name}: DOCUMENT-UNAVAILABLE (no measured numbers) ---")
            continue
        print(f"--- {name} ({res.get('url')}) node_exit={res['node_exit']} wall={res['wall_s']}s ---")
        print("| op | ok/total | p50 ms | p95 ms | status |")
        print("|----|----------|--------|--------|--------|")
        for op in ("create", "put", "get", "list"):
            print(fmt_row(op, res))
        fe = res.get("first_errors") or []
        if fe:
            print("first errors:", *fe, sep="\n  ")
        print()

    if not args.keep_smalt:
        smalt_down(smalt_receipt)

    print(f"receipt: {out_path}")
    ok_smalt = bool(bench_smalt and bench_smalt.get("node_exit") == 0)
    if not smalt_receipt.get("ready"):
        return 2
    if not az_receipt or not az_receipt.get("ready"):
        return 1
    return 0 if ok_smalt else 2


if __name__ == "__main__":
    sys.exit(main())
