# GWS-2 Receipt — crux wasm build trial (graphlaw @ 0af58bf)

**Standing:** PARTIAL_ALIVE — crux typed to exactly one cause; DOCS_RS escape path proven ABI-identical
Context: solo · Date: 2026-10-21 · Toolchain: rustc/cargo 1.97.0, wasm32-wasip1 installed

## Blessed command (js.yml:38)

`cargo build -p graphlaw-wasm --target wasm32-wasip1 --profile wasm --locked`

## Outcomes

- **Baseline blessed build: FAILS on DuckDB link.** All Rust crates compile clean (graphlaw, graphlaw-wasm, purrdf family, arrow); rust-lld fails: `unable to find library -lduckdb`. frozen-duckdb-sys build.rs emits `-l duckdb -L ~/.frozen-duckdb/cache/v2.0.0-dev-arm64` — arm64/x86_64 native dylibs only; **no wasm32 artifact exists in the cache and no wasm32 feature/stub path in frozen-duckdb-sys** (zero "wasm" hits in build.rs). Note: commit 0af58bf made frozen-duckdb unconditional — there is no `duckdb` feature to toggle. Structural cause typed.
- **`--features duckdb`: n/a** — the feature never existed on graphlaw-wasm.
- **(a) DOCS_RS=1 env-only workaround: artifact PRODUCED** (frozen-duckdb-sys's documented docs.rs path, build.rs:30 — skips linking, generates bindings from vendored headers). 48.66s. Artifact: `target/wasm32-wasip1/wasm/graphlaw_wasm.wasm`, 6,663,293 B (pinned 6,654,496 B; +8,797 B expected), sha256 `bb6d8419cddfcb90dbbaa607f3996b5537ae36b444c51f4ef4608a45e60f48c2`. Validity: wasm magic 0x1, 8,494 functions, exports `gl_alloc/gl_call/gl_free`, imports only the 7 standard `wasi_snapshot_preview1` functions, **zero duckdb strings** in the binary.
- **ABI gate: fresh rebuild export-ABI hash `fb656ca6…dfe3f` == pinned `priv/graphlaw.wasm` hash — ABI MATCH.** Strong evidence duckdb call sites contribute nothing to the wasm surface.

## Closing conditions

Full ALIVE requires: blessed command green without DOCS_RS, or a KD-style divergence row declaring DOCS_RS-build as the blessed wasm path (byte-digest pin repin needed; ABI pin already matches). Alternative: stub `libduckdb.a` for wasm32 on the link path (env-only `RUSTFLAGS="-L …"`, untested).

No source files modified; target/ build artifacts only.

## Integrity re-check (CTXFILL-2, 2026-10-21)

The receipt's pinned artifact has DRIFTED on disk — a later rebuild
(file mtime Oct 21 17:02, postdating this receipt) replaced the
DOCS_RS artifact the receipt pinned. Recorded honestly, not silently
reconciled:

```
$ ls -l /Users/sac/graphlaw/target/wasm32-wasip1/wasm/graphlaw_wasm.wasm
-rwxr-xr-x 1 sac staff 6656216 Oct 21 17:02 /Users/sac/graphlaw/target/wasm32-wasip1/wasm/graphlaw_wasm.wasm
exit 0
$ shasum -a 256 /Users/sac/graphlaw/target/wasm32-wasip1/wasm/graphlaw_wasm.wasm
4dcb2421fc858338a704b18b992dc8ffe1d0831fec553cd1424f69b2f17ab592  /Users/sac/graphlaw/target/wasm32-wasip1/wasm/graphlaw_wasm.wasm
$ python3 - <<'PY'
import hashlib
b=open('/Users/sac/graphlaw/target/wasm32-wasip1/wasm/graphlaw_wasm.wasm','rb').read()
print('size',len(b),'magic ok',b[:4]==b'\x00asm')
print('sha256',hashlib.sha256(b).hexdigest())
print('duckdb strings',b.count(b'duckdb'))
print('gl_call export', b'gl_call' in b)
PY
size 6656216 magic ok True
sha256 4dcb2421fc858338a704b18b992dc8ffe1d0831fec553cd1424f69b2f17ab592
duckdb strings 3
gl_call export True
```

Current artifact: valid wasm magic, `gl_call` export present (ABI shape
intact), but sha256 differs from the receipt's pinned `bb6d8419…`
(6,656,216 B vs 6,663,293 B) and now carries 3 `duckdb` strings vs the
receipt's "zero duckdb strings". The receipt's original claims stand
AS OF its own run; the on-disk artifact no longer witnesses them.
Standing unchanged: PARTIAL_ALIVE, with artifact-drift disclosed.
