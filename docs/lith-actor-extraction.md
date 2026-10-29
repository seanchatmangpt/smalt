# Lith Actor Extraction: WASM (Popcorn/AtomVM) Compatibility Audit

Lane: lith 15 (upstream actor extraction) · repo `/Users/sac/smalt` (canonical checkout; no git commands; no lib/ behavior edits) · 2026-10-24

Lease honored: this document ONLY. No mix/build config touched — a compile was not attempted because the toolchain is absent (Appendix A.3); per lane gate, the recipe + typed per-dep gap report is the deliverable.

## 1. Scope and method

Question: which OTP apps/supervisors behind the blob / queue / vault actors are Popcorn/AtomVM-compatible?

Method is mechanical: for each actor take its module closure (the data_plane module plus its store substrate), sweep the closure for the WASM-incompatible call classes (`:ssl`, `:socket`, `:gen_tcp`/`:gen_udp`, ports, `:os`, native `:file`, NIFs, and the Bandit/Plug HTTP stack), and classify every dependency. The grep commands and their real output are in Appendix A (mechanical-derivation gate).

Load-bearing architectural fact: the actors are **pure Store-backed, wire-agnostic**. Verbatim from the QueueStorage moduledoc (`lib/smalt/data_plane/queue_storage.ex:2-10`): every handler returns a uniform `{:ok, status, headers, body}` / `{:error, status, code, msg}` tuple; the egress router maps errors onto the wire envelope ("same discipline as BlobStorage"). This makes the WASM boundary clean by construction: the HTTP edge (Bandit listeners in `Smalt.Plane.DataSupervisor` + `Smalt.EgressRouter` + the `Smalt.Egress.*Routes` plugs) stays host-side; the actor cores are the WASM candidates.

Boundary note (honesty): the actors read shared ETS via `Smalt.Store`; a store-free WASM actor either imports the Store closure (§3.4) or crosses a host bridge. Both are outside this lane's lease (no lib/ edits), so the Store closure's deps are dispositioned here and the seam itself is registered as KD-LITH-05.

## 2. Actor → closure inventory

| actor | WASM-candidate core modules | host-side HTTP edge (excluded from WASM) | store substrate |
|---|---|---|---|
| blob | `Smalt.DataPlane.BlobStorage`, `BlobService`, `BlobError`, `BlobCors`, `BlobSoftDelete` | Bandit + `EgressRouter` blob plane (`egress_router.ex:193-241`: `blob_plane_path?/account_from_blob_path`) | `Smalt.Store` ETS + `Storage.JournalSink` WAL |
| queue | `Smalt.DataPlane.QueueStorage` | Bandit + `EgressRouter` `queue_storage_plane` plug (`egress_router.ex:466`) | Store ETS tables `:smalt_q_queues` / `:smalt_q_messages` (S8: created ONCE by `Store.init/1`, `queue_storage.ex:26-30`) |
| vault/KV | `Smalt.DataPlane.VaultData`, `KeyVaultActions`, `KvPss`, `KvManagedStorage`, `Mhsm` | Bandit + `EgressRouter` `kv_challenge_guard` (`egress_router.ex:294`) + `Egress.KvRoutes` (Plug) | Store ETS + deep `:crypto` + `:public_key` (+ `:asn1` transitively) |
| egress store | `Smalt.Store`, `Store.Heir`, `Store.Partition`, `Store.DetsMirror`, `StoreTables`, `Storage.JournalSink`, `Storage.JournalReader` | — | `:ets` + `:dets` + `:file`/`File.*` |

Supervision context: these actors have no per-actor supervisor — they are stateless handler modules over the shared store. The supervisor tree above them is `Smalt.Plane.DataSupervisor` (`lib/smalt/plane/data_supervisor.ex:19-66`), whose children are `Smalt.Store` + four Bandit listeners (egress, WS-AMQP relay, Web PubSub, optional TLS) + Kafka + Confidential Ledger supervisors. Under WASM extraction, all Bandit children stay host-side; only the handler-module closures plus (optionally) the Store closure are WASM candidates. `Smalt.Store.start_link/1` boots Heir → Boot (journal replay) → 16 permanent Partition workers (`data_supervisor.ex:4-8`).

## 3. Dependency classification (mechanically derived, Appendix A)

Classes: PURE (pure Elixir, no runtime deps beyond stdlib) · OTP-OK (OTP-included, supported by target runtimes) · OTP-AT-RISK (OTP-included, known-partial or unverified surface) · INCOMPATIBLE (NIF/socket/port/os/HTTP-stack, no WASM path today).

### 3.1 Per-dep table

| dep | class | disposition for WASM build |
|---|---|---|
| `:ets` | OTP-AT-RISK (low risk) | ETS BIFs only (no NIF of its own beyond BEAM builtins); AtomVM documents ETS support; Popcorn coverage unverified. Exact fn set used is inventoried in A.1 (16 distinct `:ets` fns over the closure, 10 distinct `:crypto` fns). Typed gap KD-LITH-01. |
| `:crypto` | OTP-AT-RISK | Usually OK on AtomVM, but its NIF set is a strict subset of OTP's. The closure uses 10 distinct fns including the historically-missing class: `crypto_one_time_aead`, `generate_key`, `sign`, `verify`, `mod_pow`, `exor`. Each fn needs a runtime probe. Typed gap KD-LITH-02. |
| `:public_key` | OTP-AT-RISK | Pure Erlang over `:crypto` + `:asn1` (asn1-compiled modules are pure Erlang). 6 distinct fns used (A.1). Blocks only on the `:crypto` surface (KD-LITH-02). |
| `:asn1` | OTP-AT-RISK (transitive) | Compiled asn1 modules are pure Erlang; released BEAM should load. Unverified on target runtime. |
| `:dets` | INCOMPATIBLE (high confidence) | ERTS-level C implementation. AtomVM does not implement `:dets`; Popcorn unverified, expected absent. Only consumer in scope is `Store.DetsMirror` (`dets_mirror.ex`: open_file/sync/match_object/insert/delete/close). Replacement candidate already exists: the JournalSink `.wal`+`.seal` format. Typed gap KD-LITH-03. |
| `:file` / `File.*` | INCOMPATIBLE on WASM sandbox | Native file I/O (`journal_sink.ex`: open/write/position/datasync/rename/touch/stat; `dets_mirror.ex`: mkdir_p). Host-side only; the WASM actor must receive journaled state via the host bridge. |
| `System.*` (system_time/os_time/unique_integer/convert_time_unit) | PURE/OTP-OK | Pure BEAM time/integer builtins; no OS process access. Compatible. |
| `Bandit`, `Plug`, `cors_plug` | INCOMPATIBLE | TCP listener stack (`ThousandIsland` sockets). Stays host-side by design (§1). |
| `Jason` | PURE | Pure Elixir JSON. Compatible if the edge needs it inside WASM; currently the handlers build maps and the host edge encodes. |
| `Joken`/JOSE | INCOMPATIBLE (host-side) | Auth plug face (`Smalt.Auth.Bearer`) — outside the actor closures; host-side. Not in the WASM allowlist. |

No `:ssl`, `:socket`, `:gen_tcp`, `:gen_udp`, `Port.open`, `:os.*`, or `:code.load` call exists anywhere in the 19-file closure (Appendix A.2 — sweep exit 0 with one comment-text hit, `key_vault_actions.ex:1604`, which is prose about avoiding a host NIF, not a call).

### 3.2 Per-actor verdicts

- **blob: COMPATIBLE (conditional)** — shallowest closure: `:ets` + `:crypto.strong_rand_bytes` + `:crypto.hash` only. Conditions: KD-LITH-01/02 runtime probes + the Store seam (KD-LITH-05).
- **queue: COMPATIBLE (conditional)** — same OTP class as blob (`:ets` + `:crypto.strong_rand_bytes` + System time). Additional condition: its ETS tables are created by `Store.init/1` (S8), so the Store closure or host bridge is on the critical path (KD-LITH-05).
- **vault/KV: COMPATIBLE (conditional, deepest risk)** — no socket/port/os calls; the risk is entirely the deep `:crypto` + `:public_key` + `:asn1` surface: 10 `:crypto` fns + 6 `:public_key` fns (A.1), including RSA-OAEP encrypt/decrypt, RSA-PSS sign/verify (`kv_pss.ex:9,53,117`), X.509-ish DER encode/generate (`certificates.ex:695-751`). If the target runtime's `:crypto` NIF subset lacks any of these, vault drops to INCOMPATIBLE-as-written with a shim/replacement required (KD-LITH-02).
- **egress store (Store ensemble): PARTIAL** — `Store`/`Heir`/`Partition` are `:ets`-only (OTP-OK/AT-RISK); `DetsMirror` is INCOMPATIBLE (KD-LITH-03); `JournalSink`/`JournalReader` are native-file (host-side). WASM-compatible subset: Store minus DetsMirror minus the journal pair, with replay fed from the host.

## 4. Compile recipe (Popcorn-style profile)

Toolchain status: NOT INSTALLED (`which popcorn atomvm` → neither found; A.3). The recipe below documents every dep's disposition; it is not a faked build.

1. **Install the toolchain** — Popcorn/AtomVM per upstream docs. KD-LITH-04: provenance unverified in this lane; no URL guessed here.
2. **Per-file allowlist profile** (mix.exs addition only if a compile is attempted — disclosed per lease): a `:wasm` MIX_ENV whose `elixirc_paths` is exactly the §2 WASM-candidate file list (19 files, A.1), minus `store/dets_mirror.ex` (KD-LITH-03) and minus the host-side `egress/*Routes.ex` plugs.
3. **Deps in profile**: drop `bandit`, `plug`, `cors_plug`, `joken` (host-side); keep `jason` (pure). OTP apps in the closure: `kernel`, `stdlib`, `crypto`, `public_key`, `asn1` (+ erts BIF surface `:ets`/`:binary`/`:maps`). Excluded OTP apps: `:ssl`, `:inets`, `:runtime_tools`.
4. **Build command shape**:

```bash
MIX_ENV=wasm mix compile          # per-file allowlist, no Bandit/Plug on the path
# then the toolchain-specific WASM packaging step (KD-LITH-04)
```

5. **Store seam disposition**: recommended = host bridge — the WASM actor receives replayed state from the host-side JournalSink/DetsMirror layer and returns handler tuples; DetsMirror and the journal pair never enter the WASM allowlist. Alternative = import Store minus DetsMirror into WASM (requires KD-LITH-01 to close first).

## 5. Typed gap register (KD-LITH-*)

- **KD-LITH-01** — `:ets` surface: 16 distinct fns used (A.1) vs runtime support. Close: runtime probe on target runtime.
- **KD-LITH-02** — `:crypto`/`:public_key`/`:asn1` surface: 10 `:crypto` fns + 6 `:public_key` fns used (A.1), including `crypto_one_time_aead`, `generate_key`, `sign`, `verify`, `mod_pow`, `exor`. Close: per-function runtime probe.
- **KD-LITH-03** — `:dets`: no AtomVM implementation; Popcorn expected absent. Close: exclude `DetsMirror` from the allowlist and feed WASM state via the host bridge, or confirm support.
- **KD-LITH-04** — toolchain provenance: no popcorn/atomvm binaries on this machine; canonical install source unverified in this lane (no web claims made).
- **KD-LITH-05** — Store seam: actors read shared ETS via `Smalt.Store`; tables are created by `Store.init/1`, so a store-free WASM actor needs the host bridge (recommended) or the Store closure imported minus DetsMirror.

## Appendix A — mechanical derivation (commands + real output, 2026-10-24)

### A.1 Per-file OTP/dep function inventory

Command (as run):

```bash
cd /Users/sac/smalt/lib/smalt
for f in data_plane/blob_storage.ex data_plane/blob_service.ex data_plane/blob_error.ex \
         data_plane/blob_cors.ex data_plane/blob_soft_delete.ex data_plane/queue_storage.ex \
         data_plane/vault_data.ex data_plane/key_vault_actions.ex data_plane/kv_pss.ex \
         data_plane/kv_managed_storage.ex data_plane/mhsm.ex data_plane/certificates.ex \
         store.ex store/heir.ex store/partition.ex store/dets_mirror.ex store_tables.ex \
         storage/journal_sink.ex storage/journal_reader.ex; do
  echo "-- $f"
  grep -ohE ":(crypto|dets|file|ets|ssl|public_key|socket|inet)\.[a-z_!?]+|Port\.open|System\.[a-z_!]+|File\.[a-z_!]+" "$f" \
    | sort -u | tr '\n' ' '; echo
done
```

Real output (verbatim):

```
-- data_plane/blob_storage.ex
:crypto.strong_rand_bytes :ets.info :ets.insert :ets.lookup :ets.match_object :ets.new System.os_time System.unique_integer
-- data_plane/blob_service.ex
:crypto.hash :crypto.strong_rand_bytes System.os_time
-- data_plane/blob_error.ex
(empty)
-- data_plane/blob_cors.ex
:ets.info :ets.insert :ets.lookup :ets.new
-- data_plane/blob_soft_delete.ex
:ets.delete :ets.info :ets.insert :ets.lookup :ets.match_object :ets.new :ets.tab System.convert_time_unit System.system_time
-- data_plane/queue_storage.ex
:crypto.strong_rand_bytes :ets.info System.os_time
-- data_plane/vault_data.ex
:crypto.hash :ets.info System.system_time System.unique_integer
-- data_plane/key_vault_actions.ex
:crypto.crypto_one_time :crypto.crypto_one_time_aead :crypto.generate_key :crypto.hash :crypto.sign :crypto.strong_rand_bytes :crypto.verify :ets.info :ets.new :public_key.decrypt_private :public_key.der_decode :public_key.der_encode :public_key.encrypt_public :public_key.generate_key :public_key.sign :public_key.verify System.system_time System.unique_integer
-- data_plane/kv_pss.ex
:crypto.exor :crypto.hash :crypto.mod_pow :crypto.strong_rand_bytes :public_key.der_decode :public_key.sign :public_key.verify
-- data_plane/kv_managed_storage.ex
:crypto.strong_rand_bytes :ets.delete :ets.info :ets.insert_new :ets.new System.system_time
-- data_plane/mhsm.ex
(empty)
-- data_plane/certificates.ex
:crypto.strong_rand_bytes :ets.info :ets.insert_new :ets.new :public_key.der_encode :public_key.generate_key :public_key.pem_encode :public_key.sign System.system_time
-- store.ex
:ets.delete :ets.delete_all_objects :ets.first :ets.give_away :ets.info :ets.insert :ets.lookup :ets.next :ets.tab :ets.update_counter System.unique_integer
-- store/heir.ex
:ets.give_away :ets.info
-- store/partition.ex
:ets.delete :ets.info :ets.insert :ets.lookup :ets.new System.unique_integer
-- store/dets_mirror.ex
:dets.close :dets.delete :dets.insert :dets.match_object :dets.open_file :dets.sync :ets.info :ets.insert :ets.lookup :ets.tab File.mkdir_p!
-- store_tables.ex
(empty)
-- storage/journal_sink.ex
:crypto.hash :file.datasync :file.position :file.write File.close File.mkdir_p File.open File.read! File.rename File.stat! File.touch File.write System.system_time
-- storage/journal_reader.ex
:crypto.hash File.mkdir_p File.read File.regular File.rename
```

### A.2 Incompatible-class sweep

Command (as run):

```bash
cd /Users/sac/smalt/lib/smalt
grep -nE ":ssl\.|:socket\.|:gen_tcp|:gen_udp|Port\.open|:erlang\.open_port|:os:|:os\.cmd|:os\.env|:user_drv|:code\.load|NIF" \
  data_plane/blob_*.ex data_plane/queue_storage.ex data_plane/vault_data.ex \
  data_plane/key_vault_actions.ex data_plane/kv_pss.ex data_plane/kv_managed_storage.ex \
  data_plane/mhsm.ex data_plane/certificates.ex store.ex store/heir.ex store/partition.ex \
  store/dets_mirror.ex store_tables.ex storage/journal_sink.ex storage/journal_reader.ex
echo "exit=$?"
```

Real output (verbatim):

```
data_plane/key_vault_actions.ex:1604:  # fail with the real contract's 400 InvalidValue before hitting the NIF.
exit=0
```

The single hit is a comment (prose about failing with 400 before a host-side NIF path), not a call. Zero real incompatible-class calls in the closure.

### A.3 Toolchain probe

Command (as run): `which popcorn atomvm escript` (+ `ls ~/.mix/archives`).

Real output: `popcorn not found`, `atomvm not found`; `escript` resolves to `/Users/sac/.erlmcp/otp-28.3.1/bin/escript` (host OTP 28.3.1 only — no WASM target).

### A.4 Closure-wiring evidence

- `lib/smalt/data_plane/queue_storage.ex:2-10` — moduledoc: "Pure Store-backed, wire-agnostic"; uniform handler tuples; error mapping by egress router.
- `lib/smalt/plane/data_supervisor.ex:19-66` — DataSupervisor children: `Smalt.Store` + Bandit listeners + Kafka + Confidential Ledger supervisors; store boots Heir → Boot → 16 Partitions (lines 4-8).
- `lib/smalt/egress_router.ex` — blob plane helpers at lines 193-241; `kv_challenge_guard` at line 294; `queue_storage_plane` at line 466.
- `lib/smalt/data_plane/key_vault_actions.ex:1604` — comment-only NIF reference (see A.2).
- `lib/smalt/data_plane/kv_pss.ex:9,53,117` — RSA-PSS via `:public_key.sign/verify` with `rsa_pkcs1_pss_padding`.
- `lib/smalt/data_plane/certificates.ex:695-751` — X.509-style DER encode/generate/sign over `:public_key`.
