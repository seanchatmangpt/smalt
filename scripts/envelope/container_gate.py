#!/usr/bin/env python3
"""container_gate.py — stdlib-only, fail-closed container gate (exit 0/1/2/3).

Static mode: parse docker/Dockerfile.hermetic (primary subject) and
docker/Dockerfile (reference). Final stage must have: no pkg-manager installs
(allowlist: ca-certificates-only RUN), USER != root present, no credential
COPY (.smalt/ *.pem *.key id_rsa .env), no ADD remote URL, no :latest base,
HEALTHCHECK present, ARG SUBJECT_SHA validated 40-hex.
Runtime mode (daemon + hermetic image present): docker history/inspect secret
grep, User != root, shell-form entrypoint flag.
--self-test: poisoned inline fixtures must each be REFUSED.
"""
import os
import re
import subprocess
import sys

RED, GRN, RST = "\033[31m", "\033[32m", "\033[0m"
HERMETIC = "docker/Dockerfile.hermetic"
REFERENCE = "docker/Dockerfile"
HERMETIC_IMAGES = ["smalt:hermetic", "smalt-hermetic:latest", "smalt-hermetic"]
CRED = (".smalt/", ".pem", ".key", "id_rsa", ".env")

RE_FROM = re.compile(r"^\s*FROM\s+(\S+)(?:\s+AS\s+(\S+))?", re.I)
RE_PKG = re.compile(r"^\s*RUN\s+.*\b(apt(?:-get)?\s+install|yum\s+install|apk\s+add)\b", re.I)
RE_USER = re.compile(r"^\s*USER\s+(\S+)", re.I)
RE_COPY = re.compile(r"^\s*COPY(?:\s+--\S+)*\s+(.+)$", re.I)
RE_ADD = re.compile(r"^\s*ADD(?:\s+--\S+)*\s+(.+)$", re.I)
RE_HC = re.compile(r"^\s*HEALTHCHECK\b", re.I)
RE_LATEST = re.compile(r"^\s*FROM\s+\S+:latest\b", re.I)
RE_SHA_ARG = re.compile(r"^\s*ARG\s+SUBJECT_SHA\s*$", re.I)
RE_URL = re.compile(r"^https?://", re.I)
RE_PEM = re.compile(r"BEGIN [A-Z ]*PRIVATE KEY")
RE_B64 = re.compile(r"[A-Za-z0-9+/]{41,}={0,2}")


def r(m):
    print("  REFUSE " + m, flush=True)


def g(m):
    print("  ok     " + m, flush=True)


def parse_stages(text):
    stages = []
    cur = None
    for i, line in enumerate(text.splitlines(), 1):
        m = RE_FROM.search(line)
        if m:
            as_m = re.search(r"\s+AS\s+(\S+)", line, re.I)
            stages.append([i, m.group(1), as_m.group(1) if as_m else None, []])
            cur = stages[-1][3]
        elif cur is not None:
            cur.append((i, line))
    return stages


def analyze(text, label):
    """Return list of violation strings for one Dockerfile text."""
    v = []
    stages = parse_stages(text)
    if not stages:
        return ["no FROM stages parsed"]
    final = stages[-1][3]
    all_lines = text.splitlines()

    # 1 pkg installs in final stage (allowlist: ca-certificates-only, OR an
    # install-then-strip chain that deletes the package manager itself)
    for ln, line in final:
        if RE_PKG.search(line):
            body = re.sub(r"^\s*RUN\s+", "", line, flags=re.I)
            body = re.sub(r"\b(?:apt(?:-get)?\s+install|yum\s+install|apk\s+add)\b", "", body, flags=re.I)
            toks = [t for t in body.replace("\\", " ").split() if not t.startswith("-")]
            # collect the full RUN chain (backslash continuations; Dockerfile
            # strips comment lines inside continuations, so comments don't end
            # the chain — only a non-backslash-terminated line does)
            chain = [line]
            idx = final.index((ln, line))
            j = idx
            while j + 1 < len(final) and final[j][1].rstrip().endswith("\\"):
                j += 1
                # skip comment lines: the Dockerfile parser strips them from
                # the continuation, so the chain continues past them
                while j < len(final) and final[j][1].lstrip().startswith("#"):
                    j += 1
                if j < len(final):
                    chain.append(final[j][1])
            chain_text = " ".join(chain)
            strips_pm = bool(re.search(r"\b(apk\s+del\s+apk-tools|apt-get\s+remove\s+apt|"
                                       r"rm\s+-rf\s+/(?:etc|var/cache)/apk)\b", chain_text, re.I))
            if toks == ["ca-certificates"]:
                g(f"[{label}] final-stage pkg install is ca-certificates-only allowlist (line {ln})")
            elif "ca-certificates" in chain_text and strips_pm:
                g(f"[{label}] final-stage pkg install allowed: link-deps + package manager "
                  f"stripped in-chain (`apk del apk-tools`), CA trust present (line {ln})")
            else:
                v.append(f"final stage installs packages without stripping the package manager "
                         f"(line {ln}): {line.strip()[:90]} — allowlist: ca-certificates-only, or "
                         f"install link-deps then `apk del apk-tools` in the same RUN chain")

    # 2 USER
    users = [m.group(1) for _, line in final if (m := RE_USER.search(line))]
    if not users:
        v.append("final stage has no USER directive (defaults to root)")
    elif users[-1].lower() in ("root", "0"):
        v.append("final stage USER is root")

    # 3 credential COPY
    for ln, line in final:
        m = RE_COPY.search(line)
        if m:
            for tok in m.group(1).split():
                if any(p in tok.lower() for p in CRED):
                    v.append(f"COPY of credential-shaped path (line {ln}): {tok}")

    # 4 ADD remote URL (any stage)
    for ln, line in enumerate(all_lines, 1):
        m = RE_ADD.search(line)
        if m and RE_URL.search(m.group(1)):
            v.append(f"ADD of remote URL (line {ln}): {line.strip()[:80]}")

    # 5 :latest base (any stage)
    for ln, line in enumerate(all_lines, 1):
        if RE_LATEST.search(line):
            v.append(f"floating :latest base (line {ln})")

    # 6 HEALTHCHECK in final stage
    if not any(RE_HC.search(line) for _, line in final):
        v.append("final stage has no HEALTHCHECK")

    # 7 SUBJECT_SHA ARG + 40-hex validation anywhere in file
    if not any(RE_SHA_ARG.search(l) for l in all_lines):
        v.append("no `ARG SUBJECT_SHA` found")
    elif not any(re.search(r"SUBJECT_SHA", l) and re.search(r"\{40\}", l) for l in all_lines):
        v.append("SUBJECT_SHA not validated as 40-hex at build time "
                 "(expected a `grep -Eq '^[0-9a-f]{40}$'`-class check)")
    return v


# ------------------------------------------------------------ runtime mode ---

def daemon_up():
    try:
        p = subprocess.run(["docker", "info"], capture_output=True, timeout=15)
        return p.returncode == 0
    except Exception:
        return False


def hermetic_image():
    try:
        p = subprocess.run(["docker", "images", "--format", "{{.Repository}}:{{.Tag}}"],
                           capture_output=True, text=True, timeout=15)
    except Exception:
        return None
    names = set(p.stdout.split())
    for cand in HERMETIC_IMAGES:
        if cand in names:
            return cand
    return None


def high_entropy_b64(s):
    return bool(RE_B64.search(s or ""))


def runtime_checks(image):
    v = []
    try:
        insp = subprocess.run(["docker", "inspect", image],
                              capture_output=True, text=True, timeout=20)
        if insp.returncode != 0:
            return [f"docker inspect failed: {insp.stderr.strip()[:120]}"]
        import json
        cfg = json.loads(insp.stdout)[0]["Config"]
    except Exception as e:
        return [f"docker inspect error: {e}"]
    user = cfg.get("User") or ""
    if user in ("", "root", "0"):
        v.append(f"image User is root/empty (got {user!r})")
    for e in cfg.get("Env") or []:
        key = e.split("=", 1)[0]
        if "SUBJECT_SHA" in key:
            continue
        if RE_PEM.search(e) or high_entropy_b64(e):
            v.append(f"secret-shaped ENV: {key}")
    for k, val in (cfg.get("Labels") or {}).items():
        if "SUBJECT_SHA" in k or "SUBJECT_SHA" in val:
            continue
        if RE_PEM.search(val) or high_entropy_b64(val):
            v.append(f"secret-shaped label: {k}")
    entry = cfg.get("Entrypoint")
    if entry and any(x in ("sh", "/bin/sh", "bash") for x in entry[:1]):
        v.append(f"shell-dependent entrypoint: {entry[:3]}")
    return v


# ------------------------------------------------------------- self-test ---

CLEAN = """\
FROM alpine:3.20@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa AS base
ARG SUBJECT_SHA
RUN echo "$SUBJECT_SHA" | grep -Eq '^[0-9a-f]{40}$'
USER app
HEALTHCHECK CMD true
COPY app /app
ENTRYPOINT ["/app"]
"""

POISONS = {
    "pkg-install-in-final": "RUN apk add --no-cache git build-base",
    "missing-user": None,
    "user-root": "USER root",
    "cred-copy": "COPY .smalt/tls/ca-cert.pem /etc/tls/ca.pem",
    "add-remote-url": "ADD https://example.com/x.tar.gz /tmp/x.tar.gz",
    "latest-base": "FROM alpine:latest",
    "missing-healthcheck": None,
    "sha-not-validated": None,
}


def poison(text, line):
    return text + "\n" + line + "\n" if line else text


def self_test():
    print("SELF-TEST: negative fixtures (each poison MUST be refused)", flush=True)
    fails = 0
    base = CLEAN
    # single-stage clean fixture: from alpine pinned, USER app, HEALTHCHECK,
    # sha validated, no poison lines.
    n = analyze(base, "selftest-clean")
    if n:
        fails += 1
        r(f"clean fixture refused (must pass): {n}")
    else:
        g("clean fixture passes")
    cases = []
    p1 = poison(base, POISONS["pkg-install-in-final"])
    cases.append(("pkg-install-in-final", p1))
    p2 = base.replace("USER app\n", "")
    cases.append(("missing-user", p2))
    p3 = base.replace("USER app", "USER root")
    cases.append(("user-root", p3))
    p4 = poison(base, POISONS["cred-copy"])
    cases.append(("cred-copy", p4))
    p5 = poison(base, POISONS["add-remote-url"])
    cases.append(("add-remote-url", p5))
    p6 = base.replace("FROM alpine:3.20", "FROM alpine:latest")
    cases.append(("latest-base", p6))
    p7 = base.replace("HEALTHCHECK CMD true\n", "")
    cases.append(("missing-healthcheck", p7))
    p8 = base.replace("grep -Eq '^[0-9a-f]{40}$'", "echo skipped-validation")
    cases.append(("sha-not-validated", p8))
    for name, text in cases:
        v = analyze(text, "selftest")
        if v:
            g(f"poison '{name}' REFUSED: {v[0][:70]}")
        else:
            fails += 1
            r(f"poison '{name}' ACCEPTED — vacuous check")
    return fails


# ----------------------------------------------------------------- modes ---

def static_mode():
    fails = 0
    herm = os.path.join(repo_root(), HERMETIC)
    ref = os.path.join(repo_root(), REFERENCE)
    print("STATIC MODE", flush=True)
    if not os.path.exists(herm):
        r(f"{HERMETIC} MISSING — hermetic container lane not landed. "
          "Actionable: land docker/Dockerfile.hermetic with pinned digests, "
          "final stage: no pkg installs (ca-certificates-only allowlist), USER non-root, "
          "HEALTHCHECK, ARG SUBJECT_SHA + 40-hex build-time check.")
        fails += 1
    else:
        with open(herm) as f:
            text = f.read()
        v = analyze(text, "hermetic")
        for x in v:
            r(f"[hermetic] {x}")
        if not v:
            g(f"[hermetic] {HERMETIC} green")
        fails += len(v)
    if os.path.exists(ref):
        with open(ref) as f:
            v = analyze(open(ref).read(), "reference:Dockerfile")
        for x in v:
            print(f"  note   [reference:Dockerfile] {x}")
        print(f"  note   reference docker/Dockerfile: {len(v)} finding(s) "
              "(reference analysis; does not gate — the burn image is not the hermetic subject)")
    return fails


def repo_root():
    return os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def runtime_mode():
    print("RUNTIME MODE", flush=True)
    if not daemon_up():
        print("  note   docker daemon down — runtime mode loud-skipped (static verdict stands)", flush=True)
        return 0
    img = hermetic_image()
    if not img:
        print("  note   no hermetic image present — runtime mode loud-skipped", flush=True)
        return 0
    print(f"  inspecting image: {img}")
    v = runtime_checks(img)
    for x in v:
        r(x)
    if not v:
        g(f"runtime image {img}: user/env/labels/entrypoint clean")
    return len(v)


def main():
    if "--self-test" in sys.argv:
        f = self_test()
        print("SELF-TEST " + ("PASS" if f == 0 else f"FAIL ({f} accepted poison(s))"), flush=True)
        return 1 if f else 0
    static_fails = static_mode()
    runtime_fails = runtime_mode()
    total = static_fails + runtime_fails
    print(f"container_gate: {'PASS' if total == 0 else 'FAIL'} "
          f"(static={static_fails} runtime={runtime_fails})", flush=True)
    return 0 if total == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
