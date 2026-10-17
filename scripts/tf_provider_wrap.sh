#!/usr/bin/env bash
# scripts/tf_provider_wrap.sh — post-init provider wrapper for the zero-dialog
# trust path.
#
# ROOT CAUSE (witnessed 2026-10-16, this lane): terraform STRIPS DYLD_* env
# vars before exec'ing provider plugins (witness receipt: an env-printer
# substituted for the provider under a hashes-stripped lock printed
# "DYLD=" (empty) from inside the plugin process). DYLD_INSERT_LIBRARIES
# exported by scripts/smalt-tf / scripts/tf_mirror_env.sh therefore NEVER
# reaches the provider through terraform, no matter how injectable the
# binary is.
#
# Fix: after `terraform init` installs the provider package, this script
# replaces each installed terraform-provider-* binary with a small bash
# wrapper that RE-ADDS DYLD_INSERT_LIBRARIES + the leaf-pin env and exec's
# the real (ad-hoc re-signed, injection-tolerant) binary. The package dir
# hash changes, so the h1: entries in .terraform.lock.hcl are recomputed —
# over the installed package DIR (dir-variant Hash1; same algorithm as
# scripts/tf_h1_dirhash.py, which is cross-validated byte-exactly against
# terraform's zip-variant) — so `terraform plan`'s cached-package checksum
# enforcement still passes.
#
# Trust contract unchanged (fingerprint-pinned leaf + loopback-only SAN gate
# inside the shim; no keychain mutation; no dialog). Idempotent: wrapping a
# wrapped binary is a no-op; env values are refreshed on every run.
#
# Exit codes: 0 wrapped/already-wrapped / 1 fault.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROVROOT="${TF_PROVIDERS_DIR:-$(pwd)/.terraform/providers}"
LOCK="${TF_LOCK_FILE:-$(pwd)/.terraform.lock.hcl}"
SHIM_DYLIB="$ROOT/scripts/trust_shim/smalt_trust_shim.dylib"
MARKER="SMALT-PROVIDER-WRAP"

[ -f "$SHIM_DYLIB" ] || bash "$ROOT/scripts/trust_shim/build.sh" >&2 || true
[ -f "$SHIM_DYLIB" ] || { echo "[tf-provider-wrap] FAULT: shim dylib missing: $SHIM_DYLIB" >&2; exit 1; }
[ -d "$PROVROOT" ] || { echo "[tf-provider-wrap] [SKIP] no installed providers at $PROVROOT (run terraform init first)"; exit 0; }
[ -f "$ROOT/.smalt/tls/dev-cert.pem" ] || { echo "[tf-provider-wrap] FAULT: leaf cert missing — run scripts/gen_dev_cert.sh" >&2; exit 1; }

LEAF_FP="$(openssl x509 -in "$ROOT/.smalt/tls/dev-cert.pem" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':')"
[ -n "$LEAF_FP" ] || { echo "[tf-provider-wrap] FAULT: cannot read leaf fingerprint" >&2; exit 1; }

# Dir-variant dirhash Hash1 (x/mod/sumdb/dirhash; validated vs zip variant).
h1_dir() {
  python3 "$ROOT/scripts/tf_h1_dirhash.py" "$1"
}

wrapped=0
while IFS= read -r bin; do
  [ -f "$bin" ] || continue
  pkgdir="$(dirname "$bin")"
  name_dir="$(basename "$(dirname "$(dirname "$pkgdir")")")"          # <name>
  ns_dir="$(basename "$(dirname "$(dirname "$(dirname "$pkgdir")")")")"  # <namespace>

  if [ "$(head -c 2 "$bin")" = "#!" ] && grep -q "$MARKER" "$bin" 2>/dev/null; then
    # Already wrapped: refresh env (leaf fp rotates on remint).
    real="$(sed -n "s/^REAL=\"\(.*\)\"$/\1/p" "$bin")"
    cat > "$bin" <<EOF2
#!/bin/bash
# $MARKER (SHIM-COURT trust lane 2026-10-16) — re-adds DYLD injection that
# terraform strips from plugin env. Real binary: $real
REAL="$real"
export DYLD_INSERT_LIBRARIES="$SHIM_DYLIB"
export SMALT_LEAF_SHA256="$LEAF_FP"
export SMALT_CA_SHA256="$LEAF_FP" # back-compat env (shim reads either)
export SMALT_CA_FILE="$ROOT/.smalt/tls/ca-cert.pem" # v2: anchor-append surface
exec "\$REAL" "\$@"
EOF2
  else
    real="$bin.real"
    mv "$bin" "$real"
    cat > "$bin" <<EOF2
#!/bin/bash
# $MARKER (SHIM-COURT trust lane 2026-10-16) — re-adds DYLD injection that
# terraform strips from plugin env. Real binary: $bin.real
REAL="$bin.real"
export DYLD_INSERT_LIBRARIES="$SHIM_DYLIB"
export SMALT_LEAF_SHA256="$LEAF_FP"
export SMALT_CA_SHA256="$LEAF_FP" # back-compat env (init: shim reads either)
export SMALT_CA_FILE="$ROOT/.smalt/tls/ca-cert.pem" # v2: anchor-append surface
exec "\$REAL" "\$@"
EOF2
  fi
  chmod 755 "$bin"
  wrapped=$((wrapped + 1))

  # Recompute the package dir h1 and ADD it to the lock as an extra h1 entry
  # (kept alongside the mirror-zip h1 so `terraform init` still validates the
  # mirror zip while `terraform plan` validates the wrapped installed dir).
  new_h1="$(h1_dir "$pkgdir")"
  python3 - "$LOCK" "$ns_dir/$name_dir" "$new_h1" <<'PYEOF'
import sys
LOCK, ns_name, new = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(LOCK).read().splitlines(keepends=True)
start = next(i for i, ln in enumerate(lines)
             if ln.strip().startswith(f'provider "registry.terraform.io/{ns_name}"'))
end = next((i for i in range(start + 1, len(lines))
            if lines[i].strip().startswith("provider ")), len(lines))
blk = lines[start:end]
h1_idx = [i for i, ln in enumerate(blk) if ln.strip().startswith('"h1:')]
d = new.split(":", 1)[1]
if h1_idx:
    # Idempotent: append the wrapped hash after the first (mirror-zip) h1
    # line when not already present.
    if not any(new in blk[i] for i in h1_idx):
        blk.insert(h1_idx[0] + 1, f'    "h1:{d}",\n')
else:
    hidx = next(i for i, ln in enumerate(blk) if ln.strip() == "hashes = [")
    blk.insert(hidx + 1, f'    "h1:{d}",\n')
lines[start:end] = blk
text = "".join(lines)
assert f'"h1:{d}"' in text, f"lock missing wrapped h1 for {ns_name}"
open(LOCK, "w").write(text)
print(f"[tf-provider-wrap]   lock h1 added: {ns_name} -> {new}")
PYEOF
done < <(find "$PROVROOT" -type f -name 'terraform-provider-*' ! -name '*.real' ! -name '*.wrapped')

echo "[tf-provider-wrap] wrapped $wrapped provider(s); leaf fp ${LEAF_FP:0:16}...; SHIM-COURT marker: SHIM-COURT"
exit 0
