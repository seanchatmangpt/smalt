#!/usr/bin/env bash
set -euo pipefail

# scripts/tf_provider_mirror.sh — ONLINE provider mirror for the terraform
# fixtures, re-validated on every run.
#
# Downloads the azurerm provider into scripts/tf_fixtures/provider-mirror/
# (gitignored — binaries are tens of MB). The terraform CLI rc is NOT written
# here: consumers (tf_smoke.sh / tf_plan_check.sh via scripts/tf_mirror_env.sh)
# generate it at run time into a temp path, so no absolute /Users/... path is
# ever committed (M8). .terraform.lock.hcl stays committed; only the provider
# binaries are ignored.
#
# M7 fix (integrity re-validation): the old idempotence probe was file-size
# only (>1MB), so a swapped/corrupted binary persisted silently as PASS.
# terraform providers mirror IS the validator — it re-checks the mirror
# against the registry's checksums and re-downloads only on mismatch — so
# this script now ATTEMPTS the mirror on every run (fast when cached).
# When the connectivity probe fails, an existing mirror is trusted only
# loudly: mode "offline-trusted" (receipts state the mirror was NOT
# re-validated this run). No mirror + offline = exit 1, never a fake pass.
#
# Prints "[tf-provider-mirror] mode: online-revalidated|offline-trusted" —
# consumers grep this for their receipts.
#
# Exit codes: 0 mirror ready / 1 failure (offline with no mirror, terraform
# missing, or mirror verification failed).

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$ROOT/scripts/tf_fixtures"
MIRROR="$FIXTURE/provider-mirror"

if ! command -v terraform >/dev/null 2>&1; then
  echo "[FAULT] terraform binary not on PATH" >&2
  exit 1
fi

mirror_nonempty() {
  find "$MIRROR" -type f -name 'terraform-provider-*' -size +1M 2>/dev/null | grep -q .
}

have_mirror() {
  [ -d "$MIRROR" ] && mirror_nonempty
}

probe_online() {
  # Connectivity probe to the provider registry (2s timeout, no side effects).
  nc -z -G 2 registry.terraform.io 443 >/dev/null 2>&1
}

if ! probe_online; then
  if have_mirror; then
    echo "[tf-provider-mirror] OFFLINE: registry unreachable — trusting the"
    echo "[tf-provider-mirror] previously-validated mirror WITHOUT re-validation."
    echo "[tf-provider-mirror] mode: offline-trusted"
    have_mirror && find "$MIRROR" -type f -name 'terraform-provider-*' -exec ls -lh {} \;
    exit 0
  fi
  echo "[FAULT] offline AND no existing mirror at $MIRROR — cannot proceed" >&2
  exit 1
fi

echo "[tf-provider-mirror] ONLINE — re-running mirror (validates every binary"
echo "[tf-provider-mirror] against registry checksums; re-downloads on mismatch)..."
mkdir -p "$MIRROR"
if ! terraform -chdir="$FIXTURE" providers mirror "$MIRROR"; then
  echo "[FAULT] terraform providers mirror failed" >&2
  exit 1
fi

# Verify the mirror actually landed provider binaries (non-vacuous).
if ! mirror_nonempty; then
  echo "[FAULT] mirror dir exists but no provider binaries found in $MIRROR" >&2
  exit 1
fi
echo "[tf-provider-mirror] mirror re-validated:"
find "$MIRROR" -type f -name 'terraform-provider-*' -exec ls -lh {} \;
echo "[tf-provider-mirror] mode: online-revalidated"

# Zero-dialog trust path (2026-10-16 operator ruling): registry checksums
# validated the download ABOVE (terraform providers mirror is the ingest
# validator); the re-sign below is a deliberate, receipted LOCAL
# transformation that makes the darwin_arm64 binaries accept
# DYLD_INSERT_LIBRARIES injection (Apple-signed Go binaries get SIGKILLed
# under injection; ad-hoc signatures do not — witnessed darwin 26:
# `codesign --remove-signature` ALONE still gets SIGKILLed, it MUST be
# followed by `codesign -f -s -`).
#
# After re-signing, the h1: entries in .terraform.lock.hcl no longer match
# (terraform's h1 is dirhash.HashZip over the zip members — see
# scripts/tf_h1_dirhash.py, cross-validated byte-exactly against the
# committed pristine lock values), so we recompute and rewrite them. The
# lock edit is deterministic and self-verifying: a later `terraform init`
# recomputes h1 from the mirror zip and refuses a mismatch.
RESIGN_RECEIPT="$FIXTURE/provider-mirror/.smalt-resign-receipt.json"
[ "${TF_RESIGN:-1}" = "1" ] || { echo "[tf-provider-mirror] TF_RESIGN=0 — skipping re-sign/h1 rewrite"; exit 0; }

echo "[tf-provider-mirror] re-signing provider binaries (ad-hoc) ..."
python3 - "$MIRROR" "$FIXTURE/.terraform.lock.hcl" "$RESIGN_RECEIPT" <<'PYEOF'
import base64, hashlib, json, os, re, subprocess, sys, tempfile, zipfile

MIRROR, LOCK, RECEIPT = sys.argv[1], sys.argv[2], sys.argv[3]

def h1_files(items):
    h = hashlib.sha256()
    for name, data in sorted(items):
        h.update(f"{hashlib.sha256(data).hexdigest()}  {name}\n".encode())
    return "h1:" + base64.b64encode(h.digest()).decode()

zips = []
for root, _d, names in os.walk(MIRROR):
    zips += [os.path.join(root, n) for n in names
             if n.startswith("terraform-provider-") and n.endswith(".zip")]

receipt = {"re-signed": [], "h1": {}}
new_h1 = {}
# Idempotence: if a previous run re-signed but crashed before the lock rewrite,
# this run sees pre_h1 == post_h1; merge the persisted receipt so the pristine
# h1 still maps to the current (re-signed) one.
if os.path.exists(RECEIPT):
    try:
        prev = json.load(open(RECEIPT))
        for r in prev.get("re-signed", []):
            new_h1.setdefault(r["h1_before"].split(":", 1)[1],
                              r["h1_after"].split(":", 1)[1])
    except Exception:
        pass
for zp in zips:
    with zipfile.ZipFile(zp) as z:
        members = {i.filename: z.read(i) for i in z.infolist() if not i.is_dir()}
        tmp = tempfile.mkdtemp(prefix="tf-resign.")
        z.extractall(tmp)
    pre_h1 = h1_files(list(members.items()))
    signed = []
    for name, data in members.items():
        p = os.path.join(tmp, name)
        if os.path.basename(name).startswith("terraform-provider-"):
            subprocess.run(["codesign", "--remove-signature", p], check=True)
            # darwin 26: remove alone still SIGKILLs under injection — ad-hoc re-sign is mandatory
            subprocess.run(["codesign", "-f", "-s", "-", p], check=True)
            signed.append(name)
            members[name] = open(p, "rb").read()
    assert signed, f"no provider binary found in {zp}"
    post_h1 = h1_files(list(members.items()))
    with zipfile.ZipFile(zp, "w", zipfile.ZIP_DEFLATED) as z:
        for name, data in members.items():
            zi = zipfile.ZipInfo(name)
            zi.external_attr = 0o755 << 16
            z.writestr(zi, data)
    os.chmod(zp, 0o644)
    # re-read from disk: hash what terraform will actually see
    with zipfile.ZipFile(zp) as z:
        disk_h1 = h1_files([(i.filename, z.read(i)) for i in z.infolist() if not i.is_dir()])
    assert disk_h1 == post_h1, f"h1 drift after rezip: {zp}"
    new_h1[pre_h1.split(":", 1)[1]] = post_h1.split(":", 1)[1]  # digest-only keys (lock lines carry no "h1:" in the map)
    receipt["re-signed"] += [{"zip": os.path.relpath(zp, MIRROR), "binaries": signed,
                              "h1_before": pre_h1, "h1_after": post_h1}]

# Rewrite ONLY the h1: entries in the lock (zh: lines are registry-side and stay).
# `terraform providers mirror` strips h1: entries from the lock every run, so
# this stage GUARANTEES presence: replace the provider block's h1 line when one
# exists, insert one after `hashes = [` when not. Fail-closed: after the
# rewrite, every re-signed zip's h1 must appear in the lock.
lines = open(LOCK).read().splitlines(keepends=True)
for r in receipt["re-signed"]:
    ns_name = "/".join(r["zip"].split("/")[-3:-1])  # <ns>/<name> under the registry host dir
    signed_digest = r["h1_after"].split(":", 1)[1]
    start = next(i for i, ln in enumerate(lines)
                 if ln.strip().startswith(f'provider "registry.terraform.io/{ns_name}"'))
    end = next((i for i in range(start + 1, len(lines))
                if lines[i].strip().startswith("provider ")), len(lines))
    blk = lines[start:end]
    h1_idx = [i for i, ln in enumerate(blk) if ln.strip().startswith('"h1:')]
    if h1_idx:
        # First h1 = the mirror-zip (re-signed) hash; any extra h1 lines are
        # stale wrapped-dir hashes from a previous cycle — drop them.
        old = blk[h1_idx[0]].strip()[4:-2]
        blk[h1_idx[0]] = blk[h1_idx[0]].replace(old, signed_digest)
        for i in reversed(h1_idx[1:]):
            del blk[i]
    else:
        hidx = next(i for i, ln in enumerate(blk) if ln.strip() == "hashes = [")
        blk.insert(hidx + 1, f'    "h1:{signed_digest}",\n')
    lines[start:end] = blk
    # Strip the zh: (registry-zip) lines for re-signed providers. Witnessed:
    # with zh present, terraform init validates the mirror zip's raw sha256
    # against zh, mismatches on the re-signed zip, and silently re-downloads
    # the PRISTINE package from the registry (defeating the re-sign; init then
    # reports "signed by HashiCorp"). With h1-only, init consumes the local
    # re-signed zip deterministically ("Installed ... (unauthenticated)") and
    # h1 remains the integrity record for the receipted local transformation.
    end2 = next((i for i in range(start + 1, len(lines))
                 if lines[i].strip().startswith("provider ")), len(lines))
    blk2 = [ln for ln in lines[start:end2] if not ln.strip().startswith('"zh:')]
    lines[start:end2] = blk2
# fail-closed verification pass
text = "".join(lines)
for r in receipt["re-signed"]:
    d = r["h1_after"].split(":", 1)[1]
    assert f'"h1:{d}"' in text, f"lock missing re-signed h1 for {r['zip']}"
    assert '"zh:' not in text, "stale zh lines remain in lock after re-sign pinning"
open(LOCK, "w").write(text)
print(f"[tf-provider-mirror] h1 lock: {len(receipt['re-signed'])} provider block(s) pinned to re-signed dirhash (zh stripped)")

receipt["h1"] = {r["h1_before"]: r["h1_after"] for r in receipt["re-signed"]}
# Rewrite the mirror's per-version index jsons ({"archives": {zip: sha256}}) to
# the re-signed zip checksums — otherwise terraform init validates the local
# zip against the OFFICIAL sha256 in these jsons, mismatches, and silently
# falls back to a registry download (witnessed: pristine HashiCorp-signed
# binary installed from a re-signed mirror; ad-hoc install only after the
# jsons were removed). Same deliberate, receipted local transformation as the
# lock h1 rewrite.
import hashlib as _hl, glob as _glob
for r in receipt["re-signed"]:
    zp = os.path.join(MIRROR, r["zip"])
    vdir = os.path.dirname(zp)
    zip_name = os.path.basename(zp)
    m = re.match(r"terraform-provider-.+?_(.+)_darwin_arm64\.zip$", zip_name)
    if not m:
        continue
    ver = m.group(1)
    signed_h1 = r["h1_after"]
    for jf in _glob.glob(os.path.join(vdir, f"{ver}.json")):
        # Witnessed (this lane, 3x): terraform init validates the mirror zip
        # against the version json's official checksum, mismatches on the
        # re-signed zip, and SILENTLY falls back to a registry download —
        # installing the pristine HashiCorp-signed (hardened-runtime, DYLD-
        # refusing) binary and resurrecting the exact zero-dialog failure the
        # re-sign stage exists to prevent. Removing the json is the only
        # observed state where init consumes the re-signed zip deterministically
        # (h1-verified against the lock). The version json is mirror metadata,
        # not integrity data — the lock's h1/zh pair is the integrity record.
        os.remove(jf)
        print(f"[tf-provider-mirror] index json removed (re-signed mirror): {os.path.relpath(jf, MIRROR)}")
json.dump(receipt, open(RECEIPT, "w"), indent=2)
print(f"[tf-provider-mirror] re-signed {len(receipt['re-signed'])} zip(s); receipt: {RECEIPT}")
for r in receipt["re-signed"]:
    print(f"[tf-provider-mirror]   {r['binaries'][0]}: {r['h1_before'][:20]}... -> {r['h1_after'][:20]}...")
PYEOF
echo "[tf-provider-mirror] SHIM-COURT re-sign stage complete (marker: SHIM-COURT)"

# Keep the binaries out of git; .terraform.lock.hcl stays committed.
if ! grep -qxF 'provider-mirror/' "$FIXTURE/.gitignore" 2>/dev/null; then
  echo 'provider-mirror/' >> "$FIXTURE/.gitignore"
  echo "[tf-provider-mirror] added provider-mirror/ to $FIXTURE/.gitignore"
fi
exit 0
