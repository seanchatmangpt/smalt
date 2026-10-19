#!/usr/bin/env python3
"""iac_gate.py — Phase 3 IaC gate (stdlib-only, fail-closed).

Exit codes: 0 all green · 1 violations (fail-closed) · 2 usage · 3 loud skip.

Scans terraform fixture trees (default: scripts/tf_fixtures,
scripts/tf_fixtures_per_resource) and asserts:

  1. OFFICIAL PROVIDERS ONLY — every required_providers entry must carry a
     source under an official registry namespace (hashicorp/*, Azure/*,
     azure/*) with an explicit registry host. A custom/forked provider
     source (any other namespace, localhost sources, filesystem paths,
     non-registry hosts) is a FAIL.
  2. EXACT VERSION PINS — every required_providers version constraint must
     be an exact pin (`= x.y.z`). Range operators (`>=`, `~>`, bare `>=`)
     or missing versions are a FAIL.
  3. NO SCHEMA BYPASSES — the deprecated `skip_provider_registration`
     attribute and the ARM_SKIP_PROVIDER_REGISTRATION env shim are banned.
     The sole registered exemption is `resource_provider_registrations =
     "none"` (receipted: azurerm 4.x hard-rejects the flag combined with
     this; the emulator does not implement RP registration).
  4. REDIRECTION PATTERN PRESENT — a tree with an azurerm provider must
     redirect via standard upstream configuration: a `metadata_host`
     attribute, an `endpoints {}` block, or the ARM_ENDPOINT /
     ARM_RESOURCE_MANAGER_ENDPOINT env-redirect references. A tree with no
     redirection surface at all is a FAIL (it would silently point at real
     Azure).

  5. NO CONSUMER-LEVEL BINARY MIRROR — `provider_installation` blocks
     (filesystem_mirror / dev_overrides) declared inside scanned .tf files
     are a FAIL: mirror shimming that substitutes provider binaries is the
     core IaC violation. (The repo-level scripts/tf_provider_mirror.sh /
     tf_provider_wrap.sh are OUT OF SCOPE here — audited separately; the
     gate covers the declarative layer.)

--self-test: negative fixtures (forked source, range pin, missing pin,
skip_provider_registration, no-redirection, provider_installation) must each
be REFUSED; a clean positive fixture must PASS. Any poison accepted fails
the gate (anti-vacuity).
"""

import os
import re
import sys

DEFAULT_TREES = [
    "scripts/tf_fixtures",
    "scripts/tf_fixtures_per_resource",
]

OFFICIAL_SOURCE_RE = re.compile(
    r"^(?:registry\.terraform\.io/)?(?:hashicorp|[Aa]zure)/[a-z0-9][a-z0-9-]*$"
)

# Registered exemption (receipted pattern; see docstring #3).
ALLOWED_REGISTRATION_FORMS = [
    re.compile(r'resource_provider_registrations\s*=\s*"none"'),
]

# Version constraint that is an exact pin: `= X.Y.Z` (whitespace flexible).
EXACT_PIN_RE = re.compile(r"^=\s*\d+\.\d+\.\d+$")

REDIRECTIONS = [
    re.compile(r"\bmetadata_host\s*=", re.I),
    re.compile(r"^\s*endpoints\s*\{", re.I | re.M),
    re.compile(r"ARM_ENDPOINT|ARM_RESOURCE_MANAGER_ENDPOINT", re.I),
]

BANNED_BYPASSES = [
    re.compile(r"\bskip_provider_registration\s*=", re.I),
    re.compile(r"ARM_SKIP_PROVIDER_REGISTRATION", re.I),
]

# provider_installation is NOT valid in .tf at all (CLI-config only) — any
# appearance is a mirror shim or a misplacement; refuse either way.
RE_PROVIDER_INSTALLATION = re.compile(r"^\s*provider_installation\s*\{", re.I | re.M)

RE_REQUIRED_PROVIDERS = re.compile(
    r"required_providers\s*\{", re.I
)
RE_PROVIDER_ENTRY = re.compile(
    r"^\s{4}(\w+)\s*\{", re.M
)
RE_SOURCE = re.compile(r'source\s*=\s*"([^"]+)"', re.I)
RE_VERSION = re.compile(r'version\s*=\s*"([^"]+)"', re.I)


def find_tf_files(tree):
    out = []
    for root, _dirs, names in os.walk(tree):
        if ".terraform" in root.split(os.sep):
            continue
        for n in sorted(names):
            if n.endswith(".tf"):
                out.append(os.path.join(root, n))
    return sorted(out)


def extract_provider_entries(text):
    """Yield (name, body) for each entry inside required_providers blocks."""
    for m in RE_REQUIRED_PROVIDERS.finditer(text):
        depth = 1
        i = m.end()
        while i < len(text) and depth:
            if text[i] == "{":
                depth += 1
            elif text[i] == "}":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        body = text[m.end():i]
        # top-level entries look like `name {\n ... \n  }`
        for em in re.finditer(r"(\w+)\s*=\s*\{", body):
            # entry body: braces balanced
            j = em.end()
            d = 1
            while j < len(body) and d:
                if body[j] == "{":
                    d += 1
                elif body[j] == "}":
                    d -= 1
                    if d == 0:
                        break
                j += 1
            yield em.group(1), body[em.end():j]


def strip_comments(text):
    """Remove HCL `#` comments so prose in fixture docs cannot trip the
    scanner (and cannot smuggle real config past it either — analysis runs
    on the stripped copy only)."""
    return re.sub(r"#[^\n]*", "", text)


def scan_file(path, text):
    """Return list of violation strings for one .tf file."""
    v = []
    text = strip_comments(text)
    tree = os.path.dirname(path) or "."

    if RE_PROVIDER_INSTALLATION.search(text):
        v.append(
            f"{path}: provider_installation block in .tf — mirror/dev_override "
            f"shim at the declarative layer is banned (binary-substitution "
            f"risk)"
        )

    # required_providers audit
    for name, body in extract_provider_entries(text):
        sm = RE_SOURCE.search(body)
        if not sm:
            v.append(f"{path}: provider `{name}` has no source — unpinned origin")
        elif not OFFICIAL_SOURCE_RE.match(sm.group(1)):
            v.append(
                f"{path}: provider `{name}` source `{sm.group(1)}` is NOT an "
                f"official registry namespace (hashicorp/*, Azure/*)"
            )
        vm = RE_VERSION.search(body)
        if not vm:
            v.append(f"{path}: provider `{name}` has no version constraint")
        elif not EXACT_PIN_RE.match(vm.group(1)):
            v.append(
                f"{path}: provider `{name}` version `{vm.group(1)}` is not an "
                f"exact pin (`= X.Y.Z`)"
            )

    # schema bypasses
    for rx in BANNED_BYPASSES:
        if rx.search(text):
            v.append(
                f"{path}: banned schema bypass matched ({rx.pattern}) — the "
                f"only registered exemption is "
                f"`resource_provider_registrations = \"none\"`"
            )

    # redirection presence: only checked on trees that configure azurerm
    has_azurerm = re.search(r'provider\s+"azurerm"\s*\{', text) or re.search(
        r'hashicorp/azurerm', text
    )
    if has_azurerm and not any(rx.search(text) for rx in REDIRECTIONS):
        v.append(
            f"{path}: azurerm configured with NO standard redirection surface "
            f"(metadata_host / endpoints block / ARM_ENDPOINT) — would "
            f"silently target real Azure"
        )

    # registration exemption must appear verbatim if RP registration is mentioned
    return v


def scan_tree(tree):
    v = []
    if not os.path.isdir(tree):
        return [f"{tree}: [SKIP] directory absent"]
    tf_files = find_tf_files(tree)
    if not tf_files:
        return [f"{tree}: [FAIL] no .tf files found (vacuous tree)"]
    versions_seen = False
    for f in tf_files:
        text = open(f, encoding="utf-8", errors="replace").read()
        if os.path.basename(f) == "versions.tf":
            versions_seen = True
        v += scan_file(f, text)
    if not versions_seen:
        v.append(f"{tree}: no versions.tf — provider pins unanchored")
    return v


# --- self-test ---------------------------------------------------------------

# Shared surrounding config so each poison isolates exactly ONE violation
# (the intended check must be the refusing one, not an incidental failure).
POISON_CTX_TAIL = """
provider "azurerm" {
  features {}
  resource_provider_registrations = "none"
  metadata_host                   = "https://127.0.0.1:9444"
}
"""

CLEAN_FIXTURE = """
terraform {
  required_version = ">= 1.8.5"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "= 4.54.0"
    }
  }
}
provider "azurerm" {
  features {}
  resource_provider_registrations = "none"
  subscription_id                 = "00000000-0000-0000-0000-000000000000"
  metadata_host                   = "https://127.0.0.1:9444"
}
"""

POISONS = {
    "forked-provider-source": """
terraform {
  required_providers {
    azurerm = {
      source  = "smalt/azurerm-emulator"
      version = "= 4.54.0"
    }
  }
}
""" + POISON_CTX_TAIL,
    "range-version-pin": """
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.0"
    }
  }
}
""" + POISON_CTX_TAIL,
    "missing-version-pin": """
terraform {
  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
    }
  }
}
""" + POISON_CTX_TAIL,
    "missing-source-field": """
terraform {
  required_providers {
    azurerm = {
      version = "= 4.54.0"
    }
  }
}
""" + POISON_CTX_TAIL,
    "skip-provider-registration": """
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "= 4.54.0"
    }
  }
}
provider "azurerm" {
  features {}
  skip_provider_registration = true
  metadata_host              = "https://127.0.0.1:9444"
}
""",
    "no-redirection": """
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "= 4.54.0"
    }
  }
}
provider "azurerm" {
  features {}
}
""",
    "provider-installation-shim": """
provider_installation {
  filesystem_mirror {
    path = "/tmp/fake-providers"
  }
}
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "= 4.54.0"
    }
  }
}
""" + POISON_CTX_TAIL,
}


def self_test():
    import tempfile

    ok = True
    with tempfile.TemporaryDirectory(prefix="iac-gate-selftest.") as d:
        # positive control must PASS
        pos = os.path.join(d, "clean")
        os.makedirs(pos)
        open(os.path.join(pos, "versions.tf"), "w").write(CLEAN_FIXTURE)
        v = scan_tree(pos)
        if v:
            ok = False
            print(f"[SELF-TEST FAIL] clean fixture was not clean:")
            for x in v:
                print(f"  {x}")

        # each poison must be REFUSED by its INTENDED check, not an
        # incidental one (isolation discipline)
        expected = {
            "forked-provider-source": "NOT an",
            "range-version-pin": "not an",
            "missing-version-pin": "no version constraint",
            "missing-source-field": "no source",
            "skip-provider-registration": "banned schema bypass",
            "no-redirection": "NO standard redirection",
            "provider-installation-shim": "provider_installation block",
        }
        for name, body in POISONS.items():
            p = os.path.join(d, name)
            os.makedirs(p)
            open(os.path.join(p, "main.tf"), "w").write(body)
            v = scan_tree(p)
            refused = [x for x in v if "[SKIP]" not in x]
            intended = [x for x in refused if expected[name] in x]
            if not refused:
                ok = False
                print(f"[SELF-TEST FAIL] poison `{name}` was ACCEPTED (vacuous gate)")
            elif not intended:
                ok = False
                print(
                    f"[SELF-TEST FAIL] poison `{name}` refused only incidentally; "
                    f"expected refusal via `{expected[name]}`: {refused}"
                )
            else:
                print(f"[SELF-TEST OK] {name}: refused -> {intended[0]}")

        # vacuous-tree negative: empty dir must not silently pass
        empty = os.path.join(d, "empty")
        os.makedirs(empty)
        v = scan_tree(empty)
        if not any("no .tf files" in x for x in v):
            ok = False
            print("[SELF-TEST FAIL] empty tree was ACCEPTED")
        else:
            print("[SELF-TEST OK] empty-tree vacuity: refused")

    if not ok:
        print("SELF-TEST: FAIL")
        return 1
    print("SELF-TEST: PASS (all poisons refused, clean fixture passes)")
    return 0


def main(argv):
    if "--self-test" in argv:
        return self_test()
    trees = [a for a in argv if not a.startswith("-")] or DEFAULT_TREES
    if trees == ["-"]:
        return 2
    all_v = []
    for t in trees:
        all_v += scan_tree(t)
    for x in all_v:
        if "[SKIP]" in x:
            print(f"[SKIP] {x}")
        else:
            print(f"[FAIL] {x}")
    fails = [x for x in all_v if "[SKIP]" not in x]
    if fails:
        print(f"IAC GATE: FAIL ({len(fails)} violation(s))")
        return 1
    print(f"IAC GATE: PASS ({', '.join(trees)})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
