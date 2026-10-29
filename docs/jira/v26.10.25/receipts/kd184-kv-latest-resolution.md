# Receipt — KD-184 (KD-R17-3): keyvault "latest" is not last-write

Standing: **CLOSED-WITH-EVIDENCE** (mint-then-close per KD-180 precedent).
Context: solo (wrap census, 2026-10-25).

- Surface: `lib/smalt/data_plane/key_vault_actions.ex` +
  `lib/smalt/egress/KvRoutes.ex` — "latest" (version-omitted GET) resolved as
  the lexically-greatest version UUID, not last-write (S19.3 witness).
- Fix landed: version rows carry a monotonic `created_seq` ordering; the
  versions-list face projects newest-first and the version-omitted GET
  resolves by write order, never version-id comparison (V20a/V20b + KD-S3/S4
  lane diff, `lib/smalt/egress/KvRoutes.ex`).
- Evidence (in-repo, real output): `test/internal/kds3_s4_secret_version_history_test.exs`
  + `test/internal/kdlith_w2_versions_list_test.exs` — green in the wrap
  census + full-suite re-run at the landing SHA; upstream handoff
  `docs/kd_register_integration_2026-10-24.md` rows KD-R17-3/4/5 (s19 4/4,
  s10 4/4 witnessed upstream 2026-10-25T06:05Z).
- Falsifier: the versions courts red, or an upstream court re-witnessing a
  lexically-greatest latest resolution.
