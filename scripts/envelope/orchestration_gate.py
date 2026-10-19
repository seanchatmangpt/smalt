#!/usr/bin/env python3
"""orchestration_gate.py — Orchestration Density Gate (fail-closed, stdlib+PyYAML).

Phase 4 gate 4 (v26.10.19 envelope lane). Scans the orchestration surface:

  k8s/**/*.yaml|yml        (Deployment/StatefulSet/Job/Pod/Service specs)
  docker/compose*.yml|yaml (compose services)

for five violation classes:

  1. SIDECAR-IMAGE — a container/service image matching the banned
     sidecar-infrastructure set (redis, rabbitmq, envoy, nginx, mosquitto,
     memcached, confluent). The density premise is "the runtime is
     self-sufficient on the BEAM"; a sidecar image in any orchestration
     manifest is a premise violation.
  2. EXTERNAL-MANAGED-SERVICE — an image or env/host reference to a managed
     cloud service surface (amazonaws.com, azure *.windows.net databases /
     servicebus / redis, redislabs, mongodb.net, confluent.cloud, mlab, etc.)
     on an executable (non-comment) line. Comment mentions that document the
     gate itself are skipped.
  3. MULTI-REPLICA-NO-DISCOVERY — replicas > 1 (k8s) or > 1 sibling service
     on a shared network (compose) without headless-service or DNS-discovery
     config (clusterIP: None, headless:, RELEASE_DISTRIBUTION=name,
     RELEASE_NODE, DNS/discovery env).
  4. K8S-SECURITY-BASELINE — every k8s container spec must set
     runAsNonRoot: true and readOnlyRootFilesystem: true (in its
     securityContext; pod-level counts for runAsNonRoot).
  5. PROBES-REQUIRED — every k8s long-running (Deployment/StatefulSet)
     container needs a readinessProbe or livenessProbe; every compose
     service needs a healthcheck. Jobs are exempt (batch, exits).

Usage:
  python3 scripts/envelope/orchestration_gate.py            # real scan
  python3 scripts/envelope/orchestration_gate.py --self-test

Exit 0 = pass, 1 = violations or self-test failure (fail-closed).
"""

import os
import re
import sys
import tempfile

import yaml

REPO = os.environ.get("SMALT_ROOT", os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))

BANNED_SIDECARS = ("redis", "rabbitmq", "envoy", "nginx", "mosquitto", "memcached", "confluent")

MANAGED_SERVICE_HOSTS = [
    "amazonaws.com",
    "servicebus.windows.net",
    "redis.cache.windows.net",
    "documents.azure.com",
    "blob.core.windows.net",
    "vault.azure.net",
    "redislabs.com",
    "mongodb.net",
    "confluent.cloud",
    "mlab.com",
]

MANAGED_SERVICE_RE = re.compile(
    "|".join(re.escape(h) for h in MANAGED_SERVICE_HOSTS),
    re.IGNORECASE,
)

DNS_DISCOVERY_RE = re.compile(
    r"(RELEASE_DISTRIBUTION|RELEASE_NODE|DNS_DISCOVERY|HEADLESS|_DISCOVERY)", re.IGNORECASE
)

LONG_RUNNING_KINDS = ("Deployment", "StatefulSet", "ReplicaSet")


def add(out, klass, path, where, detail):
    out.append(f"{klass} {path}:{where} — {detail}")


def is_comment_line(line):
    s = line.strip()
    return s.startswith("#")


def scan_image(out, path, where, image):
    img = (image or "").lower()
    for banned in BANNED_SIDECARS:
        # registry path component or repo name match: redis, redis:7,
        # bitnami/redis, confluentinc/cp-kafka ...
        if re.search(r"(^|[/:_-])" + banned + r"([/:_-]|$)", img) or img.startswith(banned):
            add(out, "SIDECAR-IMAGE", path, where, f"banned sidecar image '{image}' (matches '{banned}')")
    if MANAGED_SERVICE_RE.search(img):
        add(out, "EXTERNAL-MANAGED-SERVICE", path, where, f"managed-service image/host in image ref '{image}'")


def scan_env_and_hosts(out, path, where, env_list, extra_text=""):
    for entry in env_list or []:
        text = str(entry)
        if MANAGED_SERVICE_RE.search(text):
            add(out, "EXTERNAL-MANAGED-SERVICE", path, where, f"managed-service reference in env '{text}'")
    if extra_text and MANAGED_SERVICE_RE.search(extra_text):
        add(out, "EXTERNAL-MANAGED-SERVICE", path, where, f"managed-service reference in config: {extra_text.strip()[:80]}")


def k8s_security_and_probes(out, path, doc):
    kind = doc.get("kind")
    spec = (doc.get("spec") or {}).get("template", {}).get("spec") or {}
    pod_sec = spec.get("securityContext") or {}
    containers = spec.get("containers") or []
    for c in containers:
        name = c.get("name", "?")
        csec = c.get("securityContext") or {}
        rn_root = csec.get("runAsNonRoot", pod_sec.get("runAsNonRoot"))
        if rn_root is not True:
            add(out, "K8S-SECURITY-BASELINE", path, f"{kind}/{doc.get('metadata', {}).get('name')}/{name}",
                "runAsNonRoot: true not set (container or pod securityContext)")
        if csec.get("readOnlyRootFilesystem") is not True:
            add(out, "K8S-SECURITY-BASELINE", path, f"{kind}/{doc.get('metadata', {}).get('name')}/{name}",
                "readOnlyRootFilesystem: true not set")
        if kind in LONG_RUNNING_KINDS:
            has_probe = bool(c.get("readinessProbe") or c.get("livenessProbe"))
            if not has_probe:
                add(out, "PROBES-REQUIRED", path, f"{kind}/{doc.get('metadata', {}).get('name')}/{name}",
                    "no readinessProbe/livenessProbe on a long-running container")


def scan_k8s(out, path, text):
    try:
        docs = [d for d in yaml.safe_load_all(text) if isinstance(d, dict)]
    except yaml.YAMLError as e:
        add(out, "K8S-PARSE", path, "-", f"unparseable YAML: {e}")
        return
    # headless-service registry per app selector
    headless_apps = set()
    services = [d for d in docs if d.get("kind") == "Service"]
    for svc in services:
        if (svc.get("spec") or {}).get("clusterIP") == "None":
            sel = (svc.get("spec") or {}).get("selector") or {}
            for v in sel.values():
                headless_apps.add(v)
    for doc in docs:
        kind = doc.get("kind")
        name = doc.get("metadata", {}).get("name", "?")
        spec = doc.get("spec") or {}
        tmpl_spec = (spec.get("template") or {}).get("spec") or {}
        for c in tmpl_spec.get("containers") or []:
            scan_image(out, path, f"{kind}/{name}/{c.get('name', '?')}", c.get("image"))
            scan_env_and_hosts(out, path, f"{kind}/{name}", c.get("env"))
        # initContainers count as sidecar surface too
        for c in tmpl_spec.get("initContainers") or []:
            scan_image(out, path, f"{kind}/{name}/init:{c.get('name', '?')}", c.get("image"))
        k8s_security_and_probes(out, path, doc)
        if kind in LONG_RUNNING_KINDS and (spec.get("replicas") or 1) > 1:
            app = ((spec.get("template") or {}).get("metadata") or {}).get("labels", {}).get("app", "")
            dns_blob = yaml.safe_dump(doc)
            has_dns = bool(DNS_DISCOVERY_RE.search(dns_blob))
            if app not in headless_apps and not has_dns:
                add(out, "MULTI-REPLICA-NO-DISCOVERY", path, f"{kind}/{name}",
                    f"replicas={spec.get('replicas')} but no headless Service (clusterIP: None) "
                    f"and no DNS-discovery config (RELEASE_DISTRIBUTION/RELEASE_NODE)")


def scan_compose(out, path, text):
    lines = text.splitlines()
    # strip comment lines for the managed-service text scan
    exec_text = "\n".join(l for l in lines if not is_comment_line(l))
    try:
        doc = yaml.safe_load(exec_text)
    except yaml.YAMLError as e:
        add(out, "COMPOSE-PARSE", path, "-", f"unparseable YAML: {e}")
        return
    if not isinstance(doc, dict) or "services" not in doc:
        return
    services = doc["services"] or {}
    service_names = list(services.keys())
    for svc_name, svc in services.items():
        svc = svc or {}
        scan_image(out, path, f"service:{svc_name}", svc.get("image"))
        env = svc.get("environment")
        if isinstance(env, dict):
            env = [f"{k}={v}" for k, v in env.items()]
        scan_env_and_hosts(out, path, f"service:{svc_name}", env)
    # PROBES-REQUIRED: compose services need a healthcheck (build or image runtimes)
    for svc_name, svc in services.items():
        svc = svc or {}
        if svc.get("healthcheck") is None:
            add(out, "PROBES-REQUIRED", path, f"service:{svc_name}",
                "no healthcheck defined for compose service")
    # MULTI-REPLICA-NO-DISCOVERY: >1 service on a shared network, or scale,
    # needs DNS-discovery config. Compose service DNS is the discovery fabric,
    # but the runtime must be configured to use it (RELEASE_DISTRIBUTION etc).
    nets = {}
    for svc_name, svc in services.items():
        svc = svc or {}
        for n in (svc.get("networks") or {"default"}):
            if isinstance(n, dict):
                n = list(n.keys())[0]
            nets.setdefault(n, []).append(svc_name)
    for net, members in nets.items():
        if len(members) < 2:
            continue
        blob = "\n".join(l for l in lines if not is_comment_line(l))
        if not DNS_DISCOVERY_RE.search(blob):
            add(out, "MULTI-REPLICA-NO-DISCOVERY", path, f"network:{net}",
                f"{len(members)} services share network '{net}' ({', '.join(members)}) "
                f"with no DNS-discovery config (RELEASE_DISTRIBUTION/RELEASE_NODE)")


def iter_manifests():
    for root, dirs, files in os.walk(os.path.join(REPO, "k8s")):
        for f in sorted(files):
            if f.endswith((".yaml", ".yml")):
                yield os.path.join(root, f)
    ddir = os.path.join(REPO, "docker")
    if os.path.isdir(ddir):
        for f in sorted(os.listdir(ddir)):
            if f.startswith("compose") and f.endswith((".yml", ".yaml")):
                yield os.path.join(ddir, f)


def scan_real(out):
    count = 0
    for path in iter_manifests():
        with open(path) as fh:
            text = fh.read()
        rel = os.path.relpath(path, REPO)
        if rel.startswith("k8s/"):
            scan_k8s(out, rel, text)
        else:
            scan_compose(out, rel, text)
        count += 1
    return count


# --- self-test: negative fixtures --------------------------------------------

FIXTURES = {
    "sidecar": """
services:
  app:
    image: smalt:local
    healthcheck: {test: ["CMD", "true"]}
  cache:
    image: redis:7
""",
    "managed": """
services:
  app:
    image: smalt:local
    environment:
      - REDIS_URL=redis://smalt.redis.cache.windows.net:6380
    healthcheck: {test: ["CMD", "true"]}
""",
    "no-probe": """
services:
  app:
    image: smalt:local
""",
    "multi-no-discovery": """
services:
  a:
    image: smalt:local
    healthcheck: {test: ["CMD", "true"]}
    networks: [dense]
  b:
    image: smalt:local
    healthcheck: {test: ["CMD", "true"]}
    networks: [dense]
networks:
  dense: {}
""",
    "k8s-insecure-no-probe": """
apiVersion: apps/v1
kind: Deployment
metadata: {name: bad}
spec:
  replicas: 1
  template:
    spec:
      containers:
      - name: app
        image: smalt:local
""",
    "k8s-multi-no-headless": """
apiVersion: apps/v1
kind: Deployment
metadata: {name: scaled}
spec:
  replicas: 3
  template:
    metadata: {labels: {app: scaled}}
    spec:
      securityContext: {runAsNonRoot: true}
      containers:
      - name: app
        image: smalt:local
        securityContext: {readOnlyRootFilesystem: true}
        readinessProbe: {tcpSocket: {port: 9443}}
""",
}

GOOD_FIXTURES = {
    "compose-good": """
services:
  a:
    image: smalt:local
    environment: ["RELEASE_DISTRIBUTION=name", "RELEASE_NODE=a@dense"]
    healthcheck: {test: ["CMD", "true"]}
    networks: [dense]
  b:
    image: smalt:local
    environment: ["RELEASE_DISTRIBUTION=name", "RELEASE_NODE=b@dense"]
    healthcheck: {test: ["CMD", "true"]}
    networks: [dense]
networks:
  dense: {}
""",
    "k8s-good": """
apiVersion: apps/v1
kind: Deployment
metadata: {name: ok}
spec:
  replicas: 2
  template:
    metadata: {labels: {app: ok}}
    spec:
      securityContext: {runAsNonRoot: true}
      containers:
      - name: app
        image: smalt:local
        securityContext: {readOnlyRootFilesystem: true}
        readinessProbe: {tcpSocket: {port: 9443}}
        env: [{name: RELEASE_NODE, value: ok@headless}]
---
apiVersion: v1
kind: Service
metadata: {name: ok-svc}
spec:
  clusterIP: None
  selector: {app: ok}
""",
}

EXPECTED_CLASSES = {
    "sidecar": "SIDECAR-IMAGE",
    "managed": "EXTERNAL-MANAGED-SERVICE",
    "no-probe": "PROBES-REQUIRED",
    "multi-no-discovery": "MULTI-REPLICA-NO-DISCOVERY",
    "k8s-insecure-no-probe": "K8S-SECURITY-BASELINE",
    "k8s-multi-no-headless": "MULTI-REPLICA-NO-DISCOVERY",
}


def self_test():
    fails = []
    global REPO
    saved = REPO
    for name, expected in list(EXPECTED_CLASSES.items()) + [
        (n, None) for n in GOOD_FIXTURES
    ]:
        with tempfile.TemporaryDirectory() as td:
            fake_repo = os.path.join(td, "repo")
            os.makedirs(os.path.join(fake_repo, "k8s"))
            os.makedirs(os.path.join(fake_repo, "docker"))
            body = FIXTURES.get(name) or GOOD_FIXTURES[name]
            if name.startswith("k8s"):
                p = os.path.join(fake_repo, "k8s", name + ".yaml")
            else:
                p = os.path.join(fake_repo, "docker", "compose-" + name + ".yml")
            with open(p, "w") as fh:
                fh.write(body)
            REPO = fake_repo
            try:
                out = []
                scan_real(out)
                if expected is None:
                    if out:
                        fails.append(name)
                        print(f"[self-test] FAIL {name}: good fixture flagged: {out}")
                    else:
                        print(f"[self-test] PASS {name}: good fixture clean (0 violations)")
                else:
                    if any(o.startswith(expected) for o in out):
                        print(f"[self-test] PASS {name}: {expected} fired")
                    else:
                        fails.append(name)
                        print(f"[self-test] FAIL {name}: expected {expected}, got: {out}")
            finally:
                REPO = saved
    return fails


def main():
    if "--self-test" in sys.argv:
        fails = self_test()
        if fails:
            print(f"SELF-TEST FAIL: {fails}")
            return 1
        print("SELF-TEST PASS: 6 negative fixtures + 2 negative controls")
        return 0

    out = []
    n = scan_real(out)
    print(f"orchestration_gate: scanned {n} manifest file(s) under k8s/ + docker/compose*")
    if out:
        for o in sorted(set(out)):
            print(f"  VIOLATION {o}")
        print(f"FAIL: {len(set(out))} violation(s)")
        return 1
    print("PASS: 0 violations")
    return 0


if __name__ == "__main__":
    sys.exit(main())
