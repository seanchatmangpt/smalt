#!/usr/bin/env python3
"""tf_h1_dirhash.py — recompute terraform's h1: (dirhash) for a provider package dir or zip.

Algorithm source (honest citation): golang.org/x/mod/sumdb/dirhash Hash1, read
from upstream source v0.21.0 (fetched from proxy.golang.org and cross-checked).
Terraform computes its lock-file "h1:" values via dirhash.HashZip over the
provider zip (names + uncompressed contents; zip metadata ignored), so for
mirror zips we hash the zip members directly.

Hash1 summary (from upstream hash.go):
  h = sha256()
  for file in sorted(files):
      hf = sha256(file content)
      h += f"{hf.hex}  {file}\n"   # hex hash, TWO spaces, name, newline
  return "h1:" + base64.StdEncoding(h.digest())
"""

import base64, hashlib, os, sys, zipfile

def h1_files(items):
    # items: sorted list of (name, bytes)
    h = hashlib.sha256()
    for name, data in sorted(items):
        fh = hashlib.sha256(data).hexdigest()
        h.update(f"{fh}  {name}\n".encode())
    return "h1:" + base64.b64encode(h.digest()).decode()

def h1_dir(dirpath):
    items = []
    for root, _dirs, names in os.walk(dirpath):
        for n in names:
            p = os.path.join(root, n)
            if os.path.islink(p) or not os.path.isfile(p):
                continue
            items.append((os.path.relpath(p, dirpath), open(p, 'rb').read()))
    return h1_files(items)

def h1_zip(zippath):
    with zipfile.ZipFile(zippath) as z:
        return h1_files([(i.filename, z.read(i)) for i in z.infolist() if not i.is_dir()])

if __name__ == "__main__":
    p = sys.argv[1]
    print(h1_zip(p) if p.endswith('.zip') else h1_dir(p))
