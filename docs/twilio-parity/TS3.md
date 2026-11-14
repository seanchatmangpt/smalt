# TS3 route law Elixir mirror

Standing: UNVERIFIED

Written offline; not compiled or run (coordinator gates).

- lib/smalt/routelaw.ex: parse/1, Guard plug (400 typed, 403 cross_role, halts before assigns),
  twilio_signature/3
- test/fixtures/routelaw_vectors.json: shared vectors; arcus TW5 should consume the same cases
- test/routelaw_test.exs
- Assumed policy: role -> lead otype + ent; principal also qa/stl/inv.
- Refusal order: bad_shape, bad_role, bad_surface, bad_otype, bad_typeid, cross_role.

Rerun (coordinator): cd /Users/sac/smalt && mix test test/routelaw_test.exs
