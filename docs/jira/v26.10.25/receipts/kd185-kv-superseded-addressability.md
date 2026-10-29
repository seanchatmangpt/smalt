# Receipt — KD-185 (KD-R17-4 note-row): superseded-version addressability

Standing: **CLOSED-WITH-EVIDENCE** (mint-then-close; the disjunctive law
collapses to one behavior with the version-history landing). Context: solo
(wrap census, pinned 2026-10-25).

Context pin: the disjunctive law (addressable-on-live | 404-on-wire, both
typed) existed because the two upstream courts ran against different
substrate generations. The KD-R17-3 fix (stable latest resolution) was the
named precondition; the version-history retention landing (V20a/V20b, KvRoutes
version rows) satisfies it: superseded version ids answer 200 with retained
values on the smalt wire (witnessed by the versions courts below).

- Close condition (from the handoff): fix KD-R17-3 + version history → the
  disjunction collapses. Both witnessed green in the wrap census:
  `test/internal/kds3_s4_secret_version_history_test.exs` (3-newest-first
  legacy round-trip) + `test/internal/kdlith_w2_versions_list_test.exs`
  (newest-first + `version` member).
- Falsifier: a versions court red, or an upstream court re-witnessing the
  404 arm of the disjunction on the smalt wire.
