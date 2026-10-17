#!/usr/bin/env python3
"""Smalt doctor v2 — fail-closed diagnostic court with agent-facing remediation.

Exit codes: 0 all checks pass (or only INFO advisories); 1 any check FAILed
(machine remediation block emitted).
"""
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

SCHEMA_V1 = "smalt-doctor/v1"
SCHEMA_V2 = "smalt-doctor/v2"

REPO_ROOT = Path(os.environ.get("SMALT_ROOT", Path(__file__).resolve().parent.parent))

REQUIRED_BINARIES = [
    ("elixir", "Elixir Runtime"),
    ("mix", "Mix Build Tool"),
    ("terraform", "Terraform CLI"),
]

# Port set mirrors scripts/bench.py: fixed defaults are the `just bench`
# front door; SMALT_BENCH_* overrides let a private-port bench run put the
# doctor's port-in-use court on the same private ports it will bind.
_BENCH_ARM = int(os.environ.get("SMALT_BENCH_ARM_PORT", "9443"))
_BENCH_DATA = int(os.environ.get("SMALT_BENCH_DATA_PORT", "8443"))
_BENCH_AMQP = int(os.environ.get("SMALT_BENCH_AMQP_PORT", "5672"))

REQUIRED_PORTS = [
    (_BENCH_ARM, "Control Plane REST (ARM)"),
    (_BENCH_DATA, "Data Plane REST (Egress)"),
    (_BENCH_AMQP, "AMQP 1.0 Broker"),
]

SUBSTRATE_URL = f"http://127.0.0.1:{_BENCH_ARM}/?api-version=2021-01-01"

# Same state the flock manager (scripts/substrate.sh) owns: a live PID here is
# the legitimate holder of the substrate ports — doctor must not fail on it.
SUBSTRATE_PID_FILE = Path("/tmp/smalt-substrate-state/substrate.pid")
SUBSTRATE_PORTS = (9443, 9444, 5672, 5673)  # mirrors substrate.sh PORTS


def substrate_pid():
    """Live substrate PID from the same state file substrate.sh owns, else None."""
    try:
        pid = int(SUBSTRATE_PID_FILE.read_text().strip())
    except (OSError, ValueError):
        return None
    try:
        os.kill(pid, 0)
    except OSError:
        return None
    return pid

AMQP_PORT = _BENCH_AMQP
AMQP_HEADER = b"AMQP\x00\x01\x00\x00"
AMQP_HANDSHAKE_TIMEOUT = 2.0

TMP_DIR = REPO_ROOT / "tmp"
REQUIRED_TMP_DIRS = [TMP_DIR, REPO_ROOT / "tmp" / "stability"]

# .gitignore entries every smalt checkout must carry (id -> exact line appended).
REQUIRED_GITIGNORE = {
    "gitignore-build": "/_build/",
    "gitignore-deps": "/deps/",
    "gitignore-tmp": "/tmp/",
    "gitignore-erl-crash": "erl_crash.dump",
    "gitignore-sdk-node-modules": "test/sdk-full/node_modules/",
    "gitignore-sdk-smoke-deps": "test/sdk-smoke/.deps/",
    "gitignore-tf-fixture": "test/terraform_fixture/.terraform*/",
}

DEV_KEY_GLOBS = [
    TMP_DIR / "dev-key.pem",
    REPO_ROOT / ".smalt" / "tls" / "dev-key.pem",
    REPO_ROOT / ".smalt" / "tls" / "ca-key.pem",
]

CERT_SCRIPT = Path(__file__).resolve().parent / "gen_dev_cert.sh"

RECEIPT_STALE_SECONDS = 24 * 3600
MIX_DEPS_TIMEOUT = 90


class DiagnosticFailure(Exception):
    def __init__(self, check_id, message, remediation_cmd, fix=None, advisory=False):
        super().__init__(message)
        self.check_id = check_id
        self.message = message
        self.remediation_cmd = remediation_cmd
        self.fix = fix  # callable -> action string, or None
        # advisory=True: printed as [ADVISORY] with remediation but does NOT flip
        # ok/exit (e.g. keychain trust: repo flow trusts via SSL_CERT_FILE instead).
        self.advisory = advisory
        # Typed diagnostic exit contract (v26.10.16 lane 430): closed severity
        # vocabulary shared with Smalt.Enclave.Remediations.
        self.severity = "ADVISORY" if advisory else "BLOCKING_GATE"


# ---------------------------------------------------------------- helpers

def port_holder_pids(port):
    try:
        out = subprocess.run(
            ["lsof", "-nP", f"-iTCP:{port}", "-sTCP:LISTEN"],
            capture_output=True, text=True, timeout=10,
        ).stdout
    except Exception:
        return []
    pids = set()
    for line in out.splitlines()[1:]:
        parts = line.split()
        if parts:
            pids.add(parts[1])
    return sorted(pids)


def fix_kill_port_holders(port):
    pids = port_holder_pids(port)
    if not pids:
        return f"no listener on {port} remained (nothing killed)"
    subprocess.run(["kill", *pids], timeout=10, check=False)
    time.sleep(0.3)
    remaining = port_holder_pids(port)
    if remaining:
        raise DiagnosticFailure(
            "port-in-use",
            f"Port {port}: kill sent to {','.join(pids)} but still held by {','.join(remaining)}",
            f"kill -9 {','.join(remaining)}",
            fix=None,
        )
    return f"killed PID(s) {','.join(pids)} on port {port}"


def fix_append_gitignore(root=REPO_ROOT):
    gi = Path(root) / ".gitignore"
    existing = gi.read_text().splitlines() if gi.exists() else []
    have = {ln.strip() for ln in existing}
    appended = []
    for cid, line in REQUIRED_GITIGNORE.items():
        if line not in have:
            with gi.open("a") as f:
                if existing and existing[-1].strip() and not existing[-1].endswith("\n"):
                    f.write("\n")
                f.write(line + "\n")
            appended.append(line)
            existing.append(line)
    if not appended:
        return None  # nothing needed — caller should not journal
    return f"appended {len(appended)} missing entr{'y' if len(appended) == 1 else 'ies'} to .gitignore: {', '.join(appended)}"


def fix_chmod_dev_keys(paths=None):
    changed = []
    for p in (paths if paths is not None else DEV_KEY_GLOBS):
        if not p.exists():
            continue
        mode = p.stat().st_mode & 0o777
        if mode & 0o077:
            os.chmod(p, 0o600)
            changed.append(f"{p} ({oct(mode)}->0o600)")
    if not changed:
        return None
    return "chmod 600 " + "; ".join(changed)


def fix_mint_certs():
    if not CERT_SCRIPT.exists():
        raise DiagnosticFailure("dev-certs-missing", f"cert minter not found at {CERT_SCRIPT}",
                                f"# inspect {CERT_SCRIPT}", fix=None)
    out = subprocess.run(["bash", str(CERT_SCRIPT)], capture_output=True, text=True, timeout=60,
                         env=dict(os.environ, SMALT_ROOT=str(REPO_ROOT)))
    if out.returncode != 0:
        raise DiagnosticFailure(
            "dev-certs-missing",
            f"gen_dev_cert.sh failed (exit {out.returncode}): {out.stderr.strip()[:200]}",
            f"bash {CERT_SCRIPT}", fix=None)
    return out.stdout.strip().splitlines()[-1] if out.stdout.strip() else "minted dev certs"


def fix_create_tmp_dirs(dirs=None):
    created = []
    for d in (dirs if dirs is not None else REQUIRED_TMP_DIRS):
        if not d.exists():
            d.mkdir(parents=True, exist_ok=True)
            try:
                created.append(str(d.relative_to(REPO_ROOT)))
            except ValueError:
                created.append(str(d))
    if not created:
        return None
    return "created " + ", ".join(created)


# ---------------------------------------------------------------- checks

def check_binaries():
    for cmd, name in REQUIRED_BINARIES:
        path = shutil.which(cmd)
        if not path:
            raise DiagnosticFailure(
                "missing-binary",
                f"Missing dependency: {name} ('{cmd}' not found in PATH)",
                f"# install {cmd} (e.g. brew install {cmd})",
            )


def check_port(port, name):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    # SO_REUSEADDR: client TIME_WAIT sockets must not read as "port held" —
    # the doctor only cares about live LISTENers.
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.bind(("127.0.0.1", port))
    except OSError as e:
        pids = port_holder_pids(port)
        # A healthy substrate legitimately holds its own ports (same detection
        # substrate.sh uses: live PID in /tmp/smalt-substrate-state/). Only the
        # substrate PID itself counts — a foreign or co-held port still fails.
        sub_pid = substrate_pid()
        if sub_pid is not None and pids and set(pids) == {str(sub_pid)}:
            return f"ok (held by healthy substrate pid {sub_pid})"
        holder = f" held by PID(s) {', '.join(pids)}" if pids else ""
        raise DiagnosticFailure(
            "port-in-use",
            f"Port {port} ({name}) is not free{holder}: {e}",
            f"wait for the holder to exit, or use a private port from the "
            f"documented range 39000-39999 (docs/how-to/dev-loop.md); never kill an "
            f"unknown holder",
            # UNSAFE: killing an unknown process is never a --fix default;
            # applied only via --fix-unsafe --yes through CHECK_REGISTRY.
            fix=None,
        )
    finally:
        s.close()


def probe_amqp_handshake(host="127.0.0.1", port=None, timeout=None):
    # port/timeout resolved at CALL time from module constants: a default like
    # `port=AMQP_PORT` binds at import time — the same trap class as bench.py's
    # witnessed mint_token defect (lens-2 cycle 4: deterministic 401 on the
    # whole auto-scope path). doctor.py never re-picks AMQP_PORT today, so this
    # was latent not live; the class is closed repo-wide regardless.
    """Informational only: the doctor runs pre-boot, so an absent broker is not a fault.

    When the port is LISTENING: send the AMQP protocol header, await any valid
    8-byte-header frame within `timeout`. Returns HANDSHAKE_OK, HANDSHAKE_DEGRADED
    (listening but never/short reply), or PASS-FREE (port not listening).
    """
    if port is None:
        port = AMQP_PORT
    if timeout is None:
        timeout = AMQP_HANDSHAKE_TIMEOUT
    try:
        with socket.create_connection((host, port), timeout=timeout) as s:
            s.settimeout(timeout)
            s.sendall(AMQP_HEADER)
            hdr = b""
            while len(hdr) < 8:
                chunk = s.recv(8 - len(hdr))
                if not chunk:
                    break
                hdr += chunk
            if len(hdr) < 8:
                return "HANDSHAKE_DEGRADED (accepted header but no/short frame reply)"
            frame_size = int.from_bytes(hdr[:4], "big")
            frame_type = hdr[4]
            if frame_size < 8 or frame_type not in (0, 1, 2):
                return f"HANDSHAKE_DEGRADED (invalid frame header: {hdr.hex()})"
            return f"HANDSHAKE_OK (server frame {hdr.hex()})"
    except ConnectionRefusedError:
        return "PASS-FREE (broker not listening — pre-boot)"
    except (socket.timeout, TimeoutError):
        return "HANDSHAKE_DEGRADED (no frame within 2s)"
    except OSError as e:
        return f"HANDSHAKE_DEGRADED ({type(e).__name__}: {e})"


def probe_substrate():
    """Informational only: the gate runs doctor before substrate boot.

    Any HTTP response — including 401/403 under :enforce auth — proves the ARM
    control plane is LISTENING; only transport failure means NOT-RUNNING.
    """
    try:
        with urllib.request.urlopen(SUBSTRATE_URL, timeout=3) as resp:
            return f"LISTENING (HTTP {resp.status})"
    except urllib.error.HTTPError as e:
        return f"LISTENING (HTTP {e.code})"
    except Exception as e:
        return f"NOT-RUNNING ({type(e).__name__})"


def check_gitignore():
    gi = REPO_ROOT / ".gitignore"
    if not gi.exists():
        raise DiagnosticFailure(
            "gitignore-missing", f"{gi} does not exist",
            f"printf '%s\\n' {REPO_ROOT}/.gitignore entries",
            fix=fix_append_gitignore,
        )
    have = {ln.strip() for ln in gi.read_text().splitlines()}
    missing = [f"'{ln}'" for ln in REQUIRED_GITIGNORE.values() if ln not in have]
    if missing:
        raise DiagnosticFailure(
            "gitignore-coverage",
            f".gitignore missing {len(missing)} required entr"
            f"{'y' if len(missing) == 1 else 'ies'}: {', '.join(missing)}",
            "# append missing ignore patterns (or rerun with --fix)",
            fix=fix_append_gitignore,
        )


def check_dev_key_perms():
    bad = []
    for p in DEV_KEY_GLOBS:
        if not p.exists():
            continue
        mode = p.stat().st_mode & 0o777
        if mode & 0o077:
            bad.append(f"{p.relative_to(REPO_ROOT)} is {oct(mode)} (group/world readable)")
    if bad:
        raise DiagnosticFailure(
            "dev-key-perms",
            "dev key material too open: " + "; ".join(bad),
            "chmod 600 tmp/dev-key.pem .smalt/tls/*-key.pem",
            fix=fix_chmod_dev_keys,
        )


def check_dev_certs():
    cert = REPO_ROOT / ".smalt" / "tls" / "dev-cert.pem"
    key = REPO_ROOT / ".smalt" / "tls" / "dev-key.pem"
    if cert.exists() and key.exists():
        return f"present ({cert.relative_to(REPO_ROOT)})"
    raise DiagnosticFailure(
        "dev-certs-missing",
        f"dev TLS material missing (expected {cert} + {key}); "
        "macOS Go builds need the CA chain (receipt 2026-10-14)",
        f"bash {CERT_SCRIPT}",
        fix=fix_mint_certs,
    )


def check_keychain_trust():
    """Advisory: dev leaf must verify through the macOS trust evaluator."""
    cert = REPO_ROOT / ".smalt" / "tls" / "dev-cert.pem"
    ca = REPO_ROOT / ".smalt" / "tls" / "ca-cert.pem"
    if not (cert.exists() and ca.exists()):
        return "skipped (dev certs not minted)"
    try:
        out = subprocess.run(
            ["security", "verify-cert", "-R", str(cert), "-p", "ssl",
             "-c", str(ca), "-k", "/Library/Keychains/System.keychain"],
            capture_output=True, text=True, timeout=15)
    except FileNotFoundError:
        return "skipped (security(1) unavailable)"
    except Exception as e:
        return f"skipped ({type(e).__name__})"
    if out.returncode == 0:
        return "trusted (verify-cert exit 0)"
    raise DiagnosticFailure(
        "keychain-untrusted",
        "dev CA not trusted by macOS System keychain (Go TLS via Apple Security.framework "
        "will reject the leaf): " + (out.stderr.strip() or out.stdout.strip())[:160],
        f"sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain {ca}",
        # UNSAFE: mutates system trust store; print-only unless --fix-unsafe --yes
        fix=None,  # attached as unsafe remediation below
        advisory=True,  # repo flow trusts via SSL_CERT_FILE; advisory unless opted in
    )


def fix_keychain_trust():
    ca = REPO_ROOT / ".smalt" / "tls" / "ca-cert.pem"
    out = subprocess.run(
        ["sudo", "-n", "security", "add-trusted-cert", "-d", "-r", "trustRoot",
         "-k", "/Library/Keychains/System.keychain", str(ca)],
        capture_output=True, text=True, timeout=30)
    if out.returncode != 0:
        raise DiagnosticFailure(
            "keychain-untrusted",
            "add-trusted-cert failed (needs interactive sudo / user approval): "
            + (out.stderr.strip() or out.stdout.strip())[:160],
            f"sudo security add-trusted-cert -d -r trustRoot -k "
            f"/Library/Keychains/System.keychain {ca}",
            fix=None)
    return "installed trust setting for dev CA in System keychain"


def check_tmp_dirs():
    missing = [d for d in REQUIRED_TMP_DIRS if not d.exists()]
    if missing:
        raise DiagnosticFailure(
            "tmp-dirs-missing",
            "missing runtime dirs: " + ", ".join(str(d.relative_to(REPO_ROOT)) for d in missing),
            "mkdir -p tmp/stability",
            fix=fix_create_tmp_dirs,
        )


def check_mix_deps_freshness():
    """Informational: capture `mix deps` output, surface advisory count."""
    try:
        out = subprocess.run(
            ["mix", "deps"], cwd=str(REPO_ROOT),
            capture_output=True, text=True, timeout=MIX_DEPS_TIMEOUT)
    except FileNotFoundError:
        return "INFO skipped (mix not on PATH)"
    except subprocess.TimeoutExpired:
        return f"INFO skipped (mix deps exceeded {MIX_DEPS_TIMEOUT}s)"
    if out.returncode != 0:
        return f"INFO skipped (mix deps exit {out.returncode})"
    lines = [ln for ln in out.stdout.splitlines() if ln.strip()]
    deps = [ln for ln in lines if re.match(r"^\*", ln)]
    outdated = [ln for ln in lines if "outdated" in ln.lower()]
    advisories = [ln for ln in lines if "vulnerab" in ln.lower() or "advisory" in ln.lower()]
    n = len(deps) if deps else len(lines)
    detail = f"{n} locked deps"
    if outdated:
        detail += f"; {len(outdated)} outdated flag(s)"
    if advisories:
        detail += f"; {len(advisories)} advisory line(s) — run `mix hex.audit`"
    return f"INFO {detail}"


def receipt_ages():
    """[(path, age_seconds)] for tmp/*receipt*.json, newest last."""
    ages = []
    if TMP_DIR.exists():
        now = time.time()
        for p in TMP_DIR.glob("*receipt*.json"):
            try:
                ages.append((p, now - p.stat().st_mtime))
            except OSError:
                continue
    return ages


def check_recent_receipts():
    ages = receipt_ages()
    if not ages:
        return "INFO no tmp/*receipt*.json found (no receipts minted yet)"
    stale = [f"{p.name} ({age / 3600:.1f}h old)" for p, age in ages if age > RECEIPT_STALE_SECONDS]
    if stale:
        return (f"INFO {len(stale)}/{len(ages)} receipt(s) stale >24h: "
                + ", ".join(sorted(stale)[:5]) + ("..." if len(stale) > 5 else ""))
    return f"INFO all {len(ages)} receipt(s) fresh (<24h)"


def check_spc_bands():
    """Check 5: SPC rolling control bands (config/bands.yaml).

    WARN (advisory) at 1-2 sigma drift, FAIL at 3 sigma / NFR-4 residue.
    Delegates to scripts/spc_gate.py (same bands file, same receipt).
    """
    spc = REPO_ROOT / "scripts" / "spc_gate.py"
    if not spc.exists():
        raise DiagnosticFailure("spc-bands", f"spc_gate.py missing: {spc}",
                                "# restore scripts/spc_gate.py")
    out = subprocess.run([sys.executable, str(spc)], capture_output=True,
                         text=True, timeout=60, cwd=REPO_ROOT)
    if out.returncode == 1:
        raise DiagnosticFailure(
            "spc-bands",
            "SPC 3-sigma fail-closed: " + out.stdout.strip().splitlines()[-1][:300],
            "python3 scripts/spc_gate.py  # see "
            "docs/jira/v26.10.16/sdk-results/spc-bands.md")
    # exit 0: parse verdict from the receipt for the PASS/WARN detail
    receipt = REPO_ROOT / "docs" / "jira" / "v26.10.16" / "sdk-results" / "spc-bands.md"
    detail = "ok"
    try:
        import re
        m = re.search(r"```json\s*(\{.*?\})\s*```", receipt.read_text(), re.S)
        if not m:
            raise ValueError(f"no json block in {receipt}")
        d = json.loads(m.group(1))
        detail = f"verdict={d['verdict']} tier={d['tier']} seeded={d['seeded']}"
        if d["tier"] >= 1:
            # 1-2 sigma: advisory WARN, not a failure
            raise DiagnosticFailure(
                "spc-bands",
                f"WARN SPC drift {detail}: "
                + "; ".join(f"{e['spc_drift'][0]} z~{e['spc_drift'][1]}sigma"
                            for e in d["events"]),
                "python3 scripts/spc_gate.py  # see spc-bands.md",
                advisory=True)
    except DiagnosticFailure:
        raise
    except Exception:
        pass
    return f"PASS {detail}"


CHECK_REGISTRY = [
    # (name, fn, unsafe_fix or None) — unsafe_fix applied only with --fix-unsafe --yes
    ("binaries", check_binaries, None),
    ("port-arm", lambda: check_port(_BENCH_ARM, REQUIRED_PORTS[0][1]), lambda: fix_kill_port_holders(_BENCH_ARM)),
    ("port-data", lambda: check_port(_BENCH_DATA, REQUIRED_PORTS[1][1]), lambda: fix_kill_port_holders(_BENCH_DATA)),
    ("port-amqp", lambda: check_port(_BENCH_AMQP, REQUIRED_PORTS[2][1]), lambda: fix_kill_port_holders(_BENCH_AMQP)),
    ("gitignore-coverage", check_gitignore, None),
    ("dev-key-perms", check_dev_key_perms, None),
    ("dev-certs", check_dev_certs, None),
    ("keychain-trust", check_keychain_trust, fix_keychain_trust),
    ("tmp-dirs", check_tmp_dirs, None),
    ("mix-deps-freshness", check_mix_deps_freshness, None),
    ("recent-receipts", check_recent_receipts, None),
    ("spc-bands", check_spc_bands, None),
]


# ---------------------------------------------------------------- driver

def substrate_summary():
    sub = probe_substrate()
    booted = sub.startswith("LISTENING")
    ports = {}
    # Aligned with the substrate's own port set (substrate.sh PORTS =
    # 9443 9444 5672 5673) plus the bench-front-door ports; one port set,
    # no doctor-vs-substrate-status mismatch.
    for port in sorted(set(SUBSTRATE_PORTS) | {p for p, _ in REQUIRED_PORTS}):
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        # No SO_REUSEADDR here (unlike check_port): on BSD/macOS reuseaddr lets
        # bind succeed while a live LISTENer holds the port, misreading held
        # ports as "free". TIME_WAIT is fine to treat as held for this
        # informational dict; only a live-listener verdict must be exact.
        try:
            s.bind(("127.0.0.1", port))
            listening = False
        except OSError:
            listening = True
        finally:
            s.close()
        ports[str(port)] = "listening" if listening else "free"
    ages = receipt_ages()
    freshness = None
    if ages:
        newest = min(age for _, age in ages)
        freshness = {
            "newest_receipt_age_hours": round(newest / 3600, 2),
            "stale": newest > RECEIPT_STALE_SECONDS,
            "count": len(ages),
        }
    return {"booted": booted, "substrate": sub, "ports": ports, "receipts": freshness}


def run_checks(fix=False, fix_unsafe=False, assume_yes=False):
    checks = []
    failures = []
    advisories = []
    fixes_applied = []

    def journal(check_id, action):
        fixes_applied.append({"check_id": check_id, "action": action})

    def run(name, fn, unsafe_fix):
        t0 = time.perf_counter()
        try:
            detail = fn()
            checks.append({"name": name, "status": "PASS", "detail": detail or "ok"})
        except DiagnosticFailure as f:
            # try remediation
            if fix and f.fix is not None:
                try:
                    action = f.fix()
                except DiagnosticFailure as fe:
                    action = None
                    f = fe
                if action is not None:
                    journal(f.check_id, action)
                    t1 = time.perf_counter()
                    try:
                        detail2 = fn()
                        checks.append({"name": name, "status": "PASS",
                                       "detail": (detail2 or "ok") + " [FIXED]",
                                       "duration_ms": round((time.perf_counter() - t1) * 1000, 1)})
                        return
                    except DiagnosticFailure as f2:
                        f = f2
            elif fix_unsafe and unsafe_fix is not None:
                if not assume_yes:
                    f = DiagnosticFailure(f.check_id,
                                          f.message + " (unsafe fix requires --yes)",
                                          f.remediation_cmd, fix=None)
                else:
                    try:
                        action = unsafe_fix()
                        journal(f.check_id, action)
                        t1 = time.perf_counter()
                        detail2 = fn()
                        checks.append({"name": name, "status": "PASS",
                                       "detail": (detail2 or "ok") + " [FIXED-UNSAFE]",
                                       "duration_ms": round((time.perf_counter() - t1) * 1000, 1)})
                        return
                    except DiagnosticFailure as fe:
                        f = fe
            if f.advisory:
                checks.append({"name": name, "status": "ADVISORY", "detail": f.message,
                               "code": f.check_id, "severity": f.severity})
                advisories.append(f)
            else:
                checks.append({"name": name, "status": "FAIL", "detail": f.message,
                               "code": f.check_id, "severity": f.severity})
                failures.append(f)
        finally:
            if checks and checks[-1].get("duration_ms") is None:
                checks[-1]["duration_ms"] = round((time.perf_counter() - t0) * 1000, 1)

    for name, fn, unsafe_fix in CHECK_REGISTRY:
        run(name, fn, unsafe_fix)

    return checks, failures, advisories, fixes_applied


def v1_projection(checks, ok):
    return {"schema": SCHEMA_V1, "ok": ok, "checks": checks}


def main():
    argv = sys.argv[1:]
    fix = "--fix" in argv
    fix_unsafe = "--fix-unsafe" in argv
    assume_yes = "--yes" in argv
    out_v2 = "--json" in argv
    out_v1 = "--json-v1" in argv

    checks, failures, advisories, fixes_applied = run_checks(
        fix=fix, fix_unsafe=fix_unsafe, assume_yes=assume_yes)
    ok = not failures
    summary = substrate_summary()

    v2 = {
        "schema": SCHEMA_V2,
        "ok": ok,
        "checks": checks,
        "fixes_applied": fixes_applied,
        "advisories": [{"check_id": f.check_id, "message": f.message,
                        "remediation": f.remediation_cmd} for f in advisories],
        # Typed diagnostic exit contract: code -> remediation command, one
        # mapping shared with the Elixir remediation table (single source).
        "remediation_map": {f.check_id: f.remediation_cmd
                            for f in failures + advisories},
        "substrate": summary,
    }

    if out_v1:
        # v1 consumers: same three keys; ADVISORY checks read as FAIL and ok is
        # conservative (advisories count) so v1 semantics stay self-consistent.
        v1_checks = [dict(c, status="FAIL" if c["status"] == "ADVISORY" else c["status"])
                     for c in checks]
        v1_ok = ok and not advisories
        print(json.dumps(v1_projection(v1_checks, v1_ok), indent=2))
    elif out_v2:
        print(json.dumps(v2, indent=2))
    else:
        print("=== SMALT DOCTOR DIAGNOSTIC COURT (v2) ===")
        for fx in fixes_applied:
            print(f"FIXED: {fx['check_id']} -> {fx['action']}")
        for c in checks:
            print(f"[{c['status']}] {c['name']} ({c['duration_ms']}ms): {c['detail']}")
        print(f"[SUBSTRATE] booted={summary['booted']} ports={summary['ports']} "
              f"receipts={summary['receipts']}")
        if advisories:
            print("\n--- ADVISORIES (unsafe remediation: --fix-unsafe --yes) ---")
            for f in advisories:
                print(f"[ADVISORY] {f.check_id}")
                print(f"Reason: {f.message}")
                print(f"Remediation: {f.remediation_cmd}")
            print("--- END ADVISORIES ---")
        if ok:
            print("[PASS] Smalt doctor diagnostic court passed.")
        else:
            print("\n--- MACHINE REMEDIATION BLOCK ---")
            for f in failures:
                print(f"[FAULT] {f.check_id}")
                print(f"Reason: {f.message}")
                print(f"Remediation: {f.remediation_cmd}")
            print("--- END MACHINE REMEDIATION BLOCK ---")

    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
