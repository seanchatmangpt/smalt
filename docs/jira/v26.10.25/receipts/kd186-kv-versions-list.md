# Receipt — KD-186 (KD-R17-5 / V20a/V20b): versions-list bundles dropped the `version` member

Standing: **CLOSED-WITH-EVIDENCE**
(mint-then-close per KD-180 precedent). Context: solo (wrap census,
2026-10-25).

- Surface: `lib/smalt/egress/KvRoutes.ex` — `get "/secrets/:name/versions"`.
- Divergence: the list face projected through `public_secret_record/1` which
  drops the documented SecretBundle `version` member — every upstream
  s19(2b)/s10.4 bundle read `bundle.version === undefined`; real Azure
  answers `version` on every versions entry (KV 7.4).
- Fix (V20a): the versions-list face projects with
  `Map.drop(row, ["versions", "created_seq", "is_version_row"])` — `version`
  and `value` ride every bundle; internal bookkeeping never leaves the vault.
- Fix (V20b): the SecretBundle `id` leaked the internal scoped storage key —
  the PUT now stores under the scoped key but builds the stored id from the
  UNSCOPED route name (tenant identity rides the bearer, never the URL);
  home-tenant ids byte-identical; foreign ids match the documented
  `https://{host}/versions/...` shape; the fence leg asserts the id names the
  secret and carries no tenant segment.
- Evidence (in-repo, real output): `test/internal/kdlith_w2_versions_list_test.exs`
  + `test/integration/tenant_fence_blob_kv_queue_test.exs` versions fence leg
  — green in the wrap census + full-suite re-run at the landing SHA.
- Falsifier: the versions-list court red, or an upstream court reading
  `bundle.version === undefined` again.
