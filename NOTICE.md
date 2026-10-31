# NOTICE

## Clean-room interoperability statement

Smalt is an independent implementation of publicly documented cloud wire
protocols, built for local development and testing. It emulates a control
plane, a data plane, and AMQP-based messaging surfaces on the BEAM so that
clients (SDKs, CLIs, infrastructure tooling) can be exercised against a
loopback substrate without contacting any cloud service.

- Smalt was produced as a clean-room work: no proprietary source code from
  any cloud provider was consulted, copied, or included. Behavior was
  derived exclusively from publicly available protocol documentation.
- Product and company names that appear in wire-protocol strings (host
  headers, error codes, namespace identifiers, and similar protocol
  elements) are trademarks of their respective owners. They appear solely
  for protocol compatibility, so that existing clients interoperate
  unmodified.
- Smalt is not affiliated with, sponsored by, or endorsed by any cloud
  provider. It is a testing substrate, not a hosted service, and it makes
  no claim of production fidelity beyond what its documentation states.

## Third-party dependencies

Smalt's runtime and test dependencies are Hex packages fetched at build time
via `mix deps.get`; they are not distributed with smalt. All are permissively
licensed (MIT, Apache-2.0, BSD-2-Clause, or dual MIT/Apache-2.0) and
compatible with smalt's governing license (see `LICENSE.md`). The full
table of packages, versions, and licenses is in `docs/THIRD_PARTY.md`.

CI test-time note: the `sdk-smoke` tier exercises smalt against vendored
`@azure` SDK packages (`@azure/cosmos`, `@azure/event-hubs`,
`@azure/service-bus`, `@azure/storage-blob`, MIT licensed) loaded at test
time from an external `node_modules` directory supplied via `SMALT_SDK_ROOT`.
CI installs these packages for verification only; they are NOT distributed
with smalt and are not part of its release artifacts.

## Bundled artifacts

`priv/wasm/affidavit_wasm.wasm` is a bundled build artifact of the
[affidavit](https://github.com/seanchatmangpt/affidavit) project, dual
licensed under the MIT License and the Apache License, Version 2.0.
Copyright 2026 Sean Chatman. The full license texts are available in the
affidavit source repository as `LICENSE-APACHE` and `LICENSE-MIT`; they are
not redistributed here. The artifact is bundled, not generated, by smalt;
the WASM source and its build pipeline live in the affidavit repository.

## License

Smalt is governed solely by the P28 Sovereign Invariant License
(P28-SIL v2.1.0, `urn:smalt:license:p28-sil:v2.1.0-sovereign`). No SPDX
expression — the instrument is identified by URN (§9 of the instrument).
See `LICENSE.md` and `LICENSE-P28-SIL.md`. The retired Apache-2.0 text
is preserved at `LICENSE-APACHE-2.0.md`.
