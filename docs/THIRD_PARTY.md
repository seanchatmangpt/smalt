# Third-Party Dependencies

Smalt depends on the following Hex packages. Licenses were verified from the
vendored sources under `deps/` (each package's `mix.exs` `licenses:` field,
`.app.src`, or LICENSE file), at the exact versions pinned in `mix.lock`. All
are permissive licenses compatible with smalt's Apache-2.0 license. The
packages are not modified by smalt and are not themselves part of the smalt
distribution; they are fetched at build time via `mix deps.get` from hex.pm.

## Dependencies (from mix.lock)

| Package | Version | License | Origin |
|---|---|---|---|
| ash | 3.36.0 | MIT | hex.pm |
| bandit | 1.12.5 | MIT | hex.pm |
| cors_plug | 3.0.3 | Apache-2.0 | hex.pm |
| crux | 0.1.4 | MIT | hex.pm |
| decimal | 3.2.0 | Apache-2.0 | hex.pm |
| ecto | 3.14.2 | Apache-2.0 | hex.pm |
| ets | 0.9.0 | MIT | hex.pm |
| ex_ast | 0.16.0 | MIT | hex.pm |
| finch | 0.24.0 | MIT | hex.pm |
| glob_ex | 0.1.12 | MIT | hex.pm |
| hpax | 1.1.0 | Apache-2.0 | hex.pm |
| igniter | 0.8.4 | MIT | hex.pm |
| iterex | 0.1.2 | MIT | hex.pm |
| jason | 1.4.5 | Apache-2.0 | hex.pm |
| jcs | 0.2.0 | Apache-2.0 | hex.pm |
| joken | 2.7.0 | Apache-2.0 | hex.pm |
| jose | 1.11.12 | MIT | hex.pm |
| mime | 2.0.7 | Apache-2.0 | hex.pm |
| mint | 1.11.0 | Apache-2.0 | hex.pm |
| multigraph | 0.16.1-mg.5 | MIT | hex.pm |
| nimble_csv | 1.3.0 | Apache-2.0 | hex.pm |
| nimble_options | 1.1.1 | Apache-2.0 | hex.pm |
| nimble_pool | 1.1.0 | Apache-2.0 | hex.pm |
| owl | 0.13.1 | Apache-2.0 | hex.pm |
| plug | 1.20.3 | Apache-2.0 | hex.pm |
| plug_crypto | 2.2.0 | Apache-2.0 | hex.pm |
| protocol_ex | 0.5.1 | MIT | hex.pm |
| rdf | 3.0.1 | MIT | hex.pm |
| reactor | 1.0.7 | MIT | hex.pm |
| req | 0.7.5 | Apache-2.0 | hex.pm |
| rewrite | 1.3.0 | MIT | hex.pm |
| rustler | 0.38.0 | MIT / Apache-2.0 (dual) | hex.pm |
| rustler_precompiled | 0.10.0 | Apache-2.0 | hex.pm |
| sourceror | 1.12.4 | Apache-2.0 | hex.pm |
| spark | 2.7.6 | MIT | hex.pm |
| sparql | 0.3.12 | MIT | hex.pm |
| spitfire | 0.4.2 | MIT | hex.pm |
| splode | 0.3.2 | MIT | hex.pm |
| stream_data | 1.4.0 | Apache-2.0 | hex.pm |
| sweet_xml | 0.7.5 | MIT | hex.pm |
| telemetry | 1.4.2 | Apache-2.0 | hex.pm |
| text_diff | 0.1.0 | MIT | hex.pm |
| thousand_island | 1.5.0 | MIT | hex.pm |
| toml | 0.7.0 | Apache-2.0 | hex.pm |
| uniq | 0.6.3 | Apache-2.0 | hex.pm |
| wasmex | 0.15.1 | MIT | hex.pm |
| websock | 0.5.3 | MIT | hex.pm |
| yamerl | 0.10.0 | BSD-2-Clause | hex.pm |
| yaml_elixir | 2.12.2 | MIT | hex.pm |
| ymlr | 5.1.6 | MIT | hex.pm |

50 packages total. License tally: 26 MIT, 22 Apache-2.0,
1 dual MIT/Apache-2.0 (rustler), 1 BSD-2-Clause (yamerl).

## Apache-2.0 NOTICE compatibility

Apache-2.0 §4(d) requires that NOTICE-file contents be attributed when a
package carrying a NOTICE file is distributed. Every dependency above is
permissively licensed (MIT, Apache-2.0, or BSD-2-Clause) and all are
compatible with smalt's Apache-2.0 license:

- **bandit (MIT)**: MIT has no NOTICE requirement; attribution in this file
  satisfies best practice. No conflict with Apache-2.0.
- **joken (Apache-2.0)**: Apache-2.0 dependencies are compatible with smalt
  by definition (same license). If a NOTICE file is present in the
  dependency source, its contents must be preserved in downstream
  distributions that ship the dependency's source or binaries; smalt does
  not ship dependency sources in its release artifact.
- **yamerl (BSD-2-Clause)**: requires retention of its copyright notice in
  distributions that include its source; satisfied by this table pointing
  at the vendored `deps/yamerl/LICENSE`.
- **rustler (MIT / Apache-2.0 dual)**: either license term may be chosen;
  both are permissive and compatible.

No copyleft (GPL/AGPL/ MPL/ EPL) dependencies are present in `mix.lock`.
