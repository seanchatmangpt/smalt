#!/usr/bin/env python3
"""Lane R3: deterministic OCEL-shaped NDJSON corpus generator (smalt telemetry-shaped).

Deterministic: fixed seed LCG, no wall-clock, no dict-order dependence beyond
Python's stable insertion order. Usage: gen_corpus_r3.py <n_events> <out.ndjson>
"""
import json, sys

SEED = 20261020
ACTIVITIES = ["smalt.amqp.attach", "smalt.amqp.flow", "smalt.blob.put", "smalt.cosmos.query",
              "smalt.arm.deployment", "smalt.kv.secret.get", "smalt.eh.publish", "smalt.mcp.tool.call"]
RESOURCES = ["lane-a", "lane-b", "lane-c", "substrate-9443", "tls-twin-9444",
             "data-plane-8443", "amqp-5672", "mcp-9545"]

class LCG:
    def __init__(self, seed): self.s = seed
    def next(self):
        self.s = (self.s * 6364136223846793005 + 1442695040888963407) % (1 << 64)
        return self.s
    def below(self, n): return self.next() % n

def main():
    n = int(sys.argv[1]); out = sys.argv[2]
    rng = LCG(SEED)
    with open(out, "w") as f:
        for i in range(n):
            a = ACTIVITIES[rng.below(len(ACTIVITIES))]
            r = RESOURCES[rng.below(len(RESOURCES))]
            ev = {
                "event_id": f"ev-{SEED:08d}-{i:08d}",
                "activity": a,
                "resource": r,
                "ts": 1760000000 + i,                # monotonic, i-derived (no wall clock)
                "sequence": i,
                "duration_ms": rng.below(5000),
                "status": ("ok" if rng.below(10) < 9 else "error"),
                "bytes_in": rng.below(65536),
                "bytes_out": rng.below(65536),
                "attributes": {
                    "ocel:otype": "smalt.telemetry.event",
                    "tenant": f"t{rng.below(8)}",
                    "plane": ("control" if rng.below(2) else "data"),
                    "attempt": rng.below(3),
                },
            }
            f.write(json.dumps(ev, sort_keys=True) + "\n")
    print(f"wrote {n} events to {out}")

if __name__ == "__main__":
    main()
