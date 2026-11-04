#!/usr/bin/env python3
"""Generate kano-responses.csv (SEED: 20261104). Deterministic; rerun -> byte-identical."""
import csv, random

random.seed(20261104)
PAIRS = {
    "M": [("I", "M"), ("M", "I")],
    "O": [("A", "I"), ("M", "A")],
    "A": [("A", "M")],
    "I": [("I", "I")],
}
FILL = [("A", "A"), ("A", "M"), ("A", "I"), ("M", "A"), ("M", "M"), ("M", "I"),
        ("I", "A"), ("I", "I")]

# KANO ATTRIBUTES are customer-perception attributes (K-namespace), NOT CTQs.
# The CTQ tree derives FROM them; spine CTQ-1/2/3 are pinned in RUNNING-CASE.md
# and must never share this id space. Derivation: K-01 -> CTQ-1 (bore),
# K-05 -> CTQ-2 (lead time), K-06 -> CTQ-3 (cost).
KANO_ATTRS = {
    "K-01": ("bore-diameter-in-spec", "M", 9),
    "K-02": ("no-leaking-hydraulic-ports", "M", 8),
    "K-03": ("certification-paperwork-per-shipment", "M", 8),
    "K-04": ("bore-surface-finish-low-Ra", "O", 8),
    "K-05": ("order-to-ship-lead-time", "O", 7),
    "K-06": ("competitive-unit-cost", "O", 7),
    "K-07": ("laser-etched-serialization", "A", 7),
    "K-08": ("live-production-status-dashboard", "A", 7),
    "K-09": ("premium-packaging", "I", 6),
    "K-10": ("weekly-quality-trend-report", "I", 6),
}

rows = []
for cid, (name, cls, maj) in KANO_ATTRS.items():
    pairs = [random.choice(PAIRS[cls]) for _ in range(maj)]
    rest = 12 - maj
    fill = random.choices(FILL[:-1] if cls == "I" else FILL, k=rest)
    both = pairs + fill
    random.shuffle(both)
    for i, (f, d) in enumerate(both, 1):
        rows.append({"kano_id": cid, "kano_name": name, "resp_id": f"R{i:02d}",
                     "func": f, "dys": d})

with open("/Users/sac/smalt/docs/dmedi-bb-curriculum/modules/04-voice-of-customer/data/kano-responses.csv", "w", newline="") as fh:
    w = csv.DictWriter(fh, fieldnames=["kano_id", "kano_name", "resp_id", "func", "dys"])
    w.writeheader()
    w.writerows(rows)
print(f"wrote {len(rows)} rows")
