# KD-H18

| id | surface | divergence | evidence | close condition |
|---|---|---|---|---|
| KD-H18-1 | unknown route inside a known plane | sub-routers (Treasury/Erp/Twilio) own their 404 bodies; shapes untyped/inconsistent | `Smalt.Planes.Router` fallback `{"type":"not_found"}` | coordinator mounts `Smalt.H18.Router` in front of `Smalt.Planes.Router`; per-plane typed 404 needs sub-router edits (not owned) |
| KD-H18-2 | egress/ARM/MCP/APIM planes | not in `PlaneTable` (their dispatch is plug-chain, not forward table); `/healthz` exists egress-wide via `Smalt.HealthPlug` only | `lib/smalt/egress_router.ex:45` | extend `PlaneTable` once those faces expose a route table |
| KD-H18-3 | tests unrun | UNVERIFIED: no compile/run permitted this lane | n/a | coordinator runs `mix test test/h18` |
