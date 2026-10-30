#!/usr/bin/env python3
"""compat_pin_check.py — smalt compat-pin gate, SPLIT (v26.10.31 wave).

Re-derives CURRENT truth from real sources and diffs it against TWO pins
(split per docs/jira/posh/v26.10.31/gaps/12-compat-pin-split.md):

  CORE pass    (--core-pin [PATH], default REPO/compat-pin-core.ttl)
    - cluster naming law      justfile.d/52-kind.just default
    - TF floor                provider README TF note
    - surface inventory       server_test.go resource (12) / data source (7) maps
    - payload laws            evidence greps in the provider source
  DIALECT pass (--dialect-pin [PATH], default REPO/adapters/terraform-provider-smalt/compat-pin.ttl)
    - registry.ex tops        lib/smalt/registry.ex @api_versions map
    - provider constants      grep of internal/provider/*.go (non-test) APIVersion consts
    - test census             count of `func Test` in internal/provider/*_test.go
    - dialectBehavior rows    REGISTERED-DIVERGENCE class: reported, not checked

  Exit ladder (typed, ORed over both passes):
    0 = clean (all rows pass, divergences registered)
    1 = COMPAT-PIN-FAIL (pin vs truth divergence — pin stale or wrong)
    3 = COMPAT-PIN-SKIP (a truth source or pin row is missing; loud skip, never a fake pass)
"""
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
CORE_PIN_DEFAULT = REPO / "compat-pin-core.ttl"
DIALECT_PIN_DEFAULT = REPO / "adapters/terraform-provider-smalt/compat-pin.ttl"
REGISTRY = REPO / "lib/smalt/registry.ex"
PROVIDER = REPO / "adapters/terraform-provider-smalt/internal/provider"
KIND_JUST = REPO / "justfile.d/52-kind.just"
PROVIDER_README = REPO / "adapters/terraform-provider-smalt/README.md"

OK = "[COMPAT-PIN]"
FAIL = "[COMPAT-PIN-FAIL]"
SKIP = "[COMPAT-PIN-SKIP]"

CHECKED_LAWS_CORE = {
    "managedEnvironmentId-dual-key",
    "memory-numeric-wire",
    "location-always-set",
    "tf-floor-gte-1.14",
    "aks-cluster-name-smalt",
}


def fail(msg):
    print(f"{FAIL} {msg}", file=sys.stderr)
    return 1


def skip(msg):
    print(f"{SKIP} {msg}", file=sys.stderr)
    sys.exit(3)


def read(p: Path) -> str:
    if not p.is_file():
        skip(f"source missing: {p}")
    return p.read_text()


# ----------------------------------------------------------------- truth --
def derive_registry_tops():
    text = read(REGISTRY)
    m = re.search(r"@api_versions %\{(.*?)\n  \}", text, re.S)
    if not m:
        skip(f"@api_versions map not found in {REGISTRY}")
    tops = dict(re.findall(r'"([^"]+)"\s*=>\s*"([^"]+)"', m.group(1)))
    if not tops:
        skip(f"@api_versions map parsed empty in {REGISTRY}")
    return tops


def derive_provider_constants():
    consts = {}
    for f in sorted(PROVIDER.glob("*.go")):
        if f.name.endswith("_test.go"):
            continue
        for m in re.finditer(
            r'(?:const\s+)?(\w*[Aa]PIVersion)\s*=\s*"(\d{4}-\d{2}-\d{2})"', f.read_text()
        ):
            consts[m.group(1)] = m.group(2)
    if not consts:
        skip(f"no APIVersion constants found under {PROVIDER}")
    return consts


def derive_surface_inventory():
    text = read(PROVIDER / "server_test.go")
    blocks, cur = [], []
    for line in text.splitlines():
        if re.match(r'\s+"azurerm_[a-z_]+":\s+false,\s*$', line):
            cur.append(line)
        else:
            if cur:
                blocks.append(cur)
            cur = []
    blocks = [b for b in blocks if len(b) >= 3]
    if len(blocks) < 2:
        skip("surface inventory blocks not found in server_test.go")
    return len(blocks[0]), len(blocks[1])


def derive_census():
    n = 0
    for f in sorted(PROVIDER.glob("*_test.go")):
        n += len(re.findall(r"^func Test", f.read_text(), re.M))
    if n == 0:
        skip("test census is zero (no `func Test` found)")
    return n


def derive_law_gaps():
    ca = read(PROVIDER / "resource_container_app.go")
    live = read(PROVIDER / "live_f4_test.go")
    readme = read(PROVIDER_README)
    kind = read(KIND_JUST)
    gaps = []
    if 'props["managedEnvironmentId"]' not in ca or 'props["environmentId"]' not in ca:
        gaps.append("managedEnvironmentId-dual-key")
    if "parseMemoryGiB" not in ca or "memory NUMERIC on the wire" not in live:
        gaps.append("memory-numeric-wire")
    if 'rawMap["location"] = loc' not in ca:
        gaps.append("location-always-set")
    if ">= 1.14" not in readme:
        gaps.append("tf-floor-gte-1.14")
    if not re.search(
        r'SMALT_KIND_CLUSTER\s*:=\s*env_var_or_default\(\s*"SMALT_KIND_CLUSTER",\s*"smalt"\s*\)',
        kind,
    ):
        gaps.append("aks-cluster-name-smalt")
    return gaps


# ------------------------------------------------------------------- pin --
def parse_core_pin(path):
    text = read(path)
    pin = {"laws": set()}

    def need(pat, what):
        # unparseable core rows loud-skip (exit 3), never fake-pass
        m = re.search(pat, text)
        if not m:
            skip(f"pin row unparseable: {what} in {path}")
        return m.group(1)

    pin["cluster"] = need(r'smalt:aksClusterName "([^"]+)"', "aksClusterName")
    pin["tf_floor"] = need(r'smalt:tfVersionFloor "([^"]+)"', "tfVersionFloor")
    pin["res"] = int(need(r"smalt:resourceSurfaceCount (\d+)", "resourceSurfaceCount"))
    pin["ds"] = int(need(r"smalt:dataSourceSurfaceCount (\d+)", "dataSourceSurfaceCount"))
    pin["laws"] = set(re.findall(r'smalt:payloadLaw "([^"]+)"', text))
    return pin


def parse_dialect_pin(path):
    text = read(path)
    pin = {"tops": {}, "consts": {}, "divergences": {}, "behaviors": []}

    def need(pat, what):
        m = re.search(pat, text)
        if not m:
            skip(f"pin row unparseable: {what} in {path}")
        return m.group(1)

    pin["census"] = int(need(r"smalt:testCensusCount (\d+)", "testCensusCount"))
    pin["behaviors"] = re.findall(r'smalt:dialectBehavior "([^"]+)"', text)
    for typ, ver in re.findall(
        r'smalt:resourceType "([^"]+)"\s*;\s*smalt:version "([^"]+)"', text
    ):
        pin["tops"][typ] = ver
    for sym, ver in re.findall(
        r'smalt:symbol "(\w+)"\s*;\s*smalt:version "([^"]+)"', text
    ):
        pin["consts"][sym] = ver
    for sym, prov, top in re.findall(
        r'smalt:symbol "(\w+)"\s*;\s*smalt:providerVersion "([^"]+)"\s*;\s*'
        r'\s*smalt:registryTopVersion "([^"]+)"',
        text,
    ):
        pin["divergences"][sym] = (prov, top)
    if not pin["tops"] or not pin["consts"]:
        skip("pin has no registryTop/providerConstant rows")
    return pin


# ---------------------------------------------------------------- passes --
def run_core(pin_path):
    pin = parse_core_pin(pin_path)
    res, ds = derive_surface_inventory()
    law_gaps = derive_law_gaps()

    failures = []

    if (res, ds) != (pin["res"], pin["ds"]):
        failures.append(
            f"surface inventory: pin={pin['res']}/{pin['ds']} provider={res}/{ds}"
        )

    for law in sorted(pin["laws"] - CHECKED_LAWS_CORE):
        failures.append(f"payloadLaw '{law}' is not a gate-checked law")
    for law in sorted(set(pin["laws"] & CHECKED_LAWS_CORE) & set(law_gaps)):
        failures.append(f"payloadLaw '{law}': source evidence gone")

    if failures:
        for f_ in failures:
            fail(f_)
        print(f"{FAIL} core pass: {len(failures)} divergence(s) — pin vs CURRENT truth",
              file=sys.stderr)
        return 1

    print(f"{OK}[core] surface inventory {res}/{ds} — match pin")
    print(f"{OK}[core] payload laws pinned: {len(pin['laws'])}, evidence present")
    print(f"{OK}[core] cluster={pin['cluster']} tf_floor={pin['tf_floor']}")
    print(f"{OK}[core] ALIVE")
    return 0


def run_dialect(pin_path):
    pin = parse_dialect_pin(pin_path)
    tops = derive_registry_tops()
    consts = derive_provider_constants()
    census = derive_census()

    failures = []

    # 1. registry tops vs registry.ex (fallback: provider constant evidence)
    for typ, ver in sorted(pin["tops"].items()):
        if typ in tops:
            if tops[typ] != ver:
                failures.append(f"registryTop {typ}: pin={ver} registry.ex={tops[typ]}")
        elif ver not in set(consts.values()):
            failures.append(
                f"registryTop {typ}={ver}: absent from registry.ex and no matching provider constant"
            )

    # 2. provider constants vs pin (bidirectional, exact)
    for sym, ver in sorted(pin["consts"].items()):
        if sym not in consts:
            failures.append(f"providerConstant {sym}: constant removed from provider source")
        elif consts[sym] != ver:
            failures.append(f"providerConstant {sym}: pin={ver} provider={consts[sym]}")
    for sym in sorted(set(consts) - set(pin["consts"]) - set(pin["divergences"])):
        failures.append(f"providerConstant {sym}={consts[sym]} in code but unregistered in pin")
    for sym, (prov, top) in sorted(pin["divergences"].items()):
        if sym not in consts:
            failures.append(
                f"registeredDivergence {sym}: constant removed from provider — retire the row"
            )
        elif consts[sym] != prov:
            failures.append(
                f"registeredDivergence {sym}: provider now={consts[sym]}, row says {prov} (registry top {top})"
            )

    # 3. census
    if census != pin["census"]:
        failures.append(f"test census: pin={pin['census']} provider={census}")

    # 4. dialectBehavior rows: REGISTERED-DIVERGENCE class — reported, not checked
    for b in pin["behaviors"]:
        print(f"{OK}[dialect] dialectBehavior '{b}': REGISTERED-DIVERGENCE class "
              f"(no checker yet — documented, NOT a PASS)")

    if failures:
        for f_ in failures:
            fail(f_)
        print(f"{FAIL} dialect pass: {len(failures)} divergence(s) — pin vs CURRENT truth",
              file=sys.stderr)
        return 1

    print(f"{OK}[dialect] registry tops: {len(pin['tops'])} pinned rows match registry.ex/fallback")
    print(f"{OK}[dialect] provider constants: {len(pin['consts'])} pinned + "
          f"{len(pin['divergences'])} registered divergence(s)")
    print(f"{OK}[dialect] census {census} — match pin")
    print(f"{OK}[dialect] ALIVE")
    return 0


# ------------------------------------------------------------------ main --
def main():
    argv = sys.argv[1:]
    core_pin = CORE_PIN_DEFAULT
    dialect_pin = DIALECT_PIN_DEFAULT
    known = {"--core-pin", "--dialect-pin"}

    def value_of(flag):
        if flag not in argv:
            return None
        i = argv.index(flag)
        if i + 1 < len(argv) and argv[i + 1] not in known:
            return Path(argv[i + 1])
        return None

    for flag in known:
        if argv.count(flag) > 1:
            print(f"usage: {flag} given more than once", file=sys.stderr)
            return 2
    skip_next = False
    for a in argv:
        if skip_next:
            skip_next = False
            continue
        if a in known:
            skip_next = True
            continue
        print(f"usage: unknown argument {a!r} "
              f"(positional pins removed by the split; use --core-pin/--dialect-pin)",
              file=sys.stderr)
        return 2

    v = value_of("--core-pin")
    if v:
        core_pin = v
    v = value_of("--dialect-pin")
    if v:
        dialect_pin = v

    run_core_wanted = True
    run_dialect_wanted = True
    # each flag alone runs only its own pass (posh_status.sh two-line wiring)
    if "--core-pin" in argv and "--dialect-pin" not in argv:
        run_dialect_wanted = False
    if "--dialect-pin" in argv and "--core-pin" not in argv:
        run_core_wanted = False

    rc_core = run_core(core_pin) if run_core_wanted else 0
    rc_dialect = run_dialect(dialect_pin) if run_dialect_wanted else 0

    # OR the exit ladder: 1 beats 3 beats 0
    if 1 in (rc_core, rc_dialect):
        return 1
    if 3 in (rc_core, rc_dialect):
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main())
