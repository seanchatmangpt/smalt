/**
 * ATH-2 law-reticle worker — WebAssembly guard for the browser client.
 *
 * Loads the pinned graphlaw.wasm artifact (public/wasm/graphlaw.wasm, a static
 * asset copied from graphlaw priv/) and evaluates admission calls through its
 * documented buffer ABI: `gl_alloc(len) -> ptr`, `gl_call(ptr, len) -> packed`
 * (packed = (out_ptr << 32) | out_len), `gl_free(ptr, len)`. The wire request
 * is the standard graphlaw JSON ABI (`{"op": ..., ...}`) — op byte 1 maps to
 * the SHACL preflight request, op byte 2 to the N3 admission request. The
 * reticle bytes (law text) ride the INIT message and are attached per call.
 *
 * Deviation, disclosed: the reticle is passed per request in the JSON body
 * (`shapes` field) because the pinned artifact exports no `gl_load_reticle`;
 * the documented init path in this artifact family is the JSON request body
 * itself (graphlaw src/abi.rs — every op is a self-contained JSON request).
 *
 * A minimal wasi_snapshot_preview1 shim satisfies the module's WASI imports
 * (clock/random/env/stdio stubs); no host functions beyond WASI are linked,
 * matching the artifact's own ABI test contract. IPC uses packet-4
 * length-prefixed frames (u32 BE length + payload) — the same framing the
 * smalt WASM-1 port driver uses server-side.
 */

/// <reference lib="webworker" />

export interface RequestMsg {
  type: "INIT" | "ADMIT_INPUT";
  id: number;
  /** packet-4 framed bytes (u32 BE length + payload). */
  reticle?: Uint8Array;
  op?: 1 | 2;
  node?: bigint;
  body?: Uint8Array;
}

export interface ResponseMsg {
  id: number;
  verdict:
    | { status: 0; ms: number }
    | { status: 1; reason: string; ms: number }
    | { status: 2; detail: string; ms: number };
}

const WASM_URL = new URL("/wasm/graphlaw.wasm", self.location.origin);

let instance: WebAssembly.Instance | null = null;
let memory: WebAssembly.Memory | null = null;
let glAlloc: (len: number) => number;
let glFree: (ptr: number, len: number) => void;
let glCall: (ptr: number, len: number) => bigint;
let reticleText = "";

// --- minimal wasi_snapshot_preview1 shim ------------------------------------

const wasiShim = {
  wasi_snapshot_preview1: {
    args_sizes_get: (_argc: number, _buf: number) => 0,
    args_get: () => 0,
    environ_sizes_get: (c: number, l: number) => {
      const dv = new DataView(memory!.buffer);
      dv.setUint32(c, 0, true);
      dv.setUint32(l, 0, true);
      return 0;
    },
    environ_get: () => 0,
    clock_time_get: (id: number, _prec: bigint, out: number) => {
      const t =
        id === 0 ? BigInt(Date.now()) * 1_000_000n : BigInt(performance.now() * 1_000_000);
      const dv = new DataView(memory!.buffer);
      dv.setBigUint64(out, t, true);
      return 0;
    },
    random_get: (buf: number, len: number) => {
      const bytes = new Uint8Array(memory!.buffer, buf, len);
      crypto.getRandomValues(bytes);
      return 0;
    },
    fd_write: (_fd: number, _iovs: number, _n: number, _nwritten: number) => 0,
    fd_read: () => 8, // ERRNO badf-equivalent: guest stdio is inert here
    fd_close: () => 0,
    fd_seek: () => 70, // ERRNO SPIPE-family refusal, never a trap
    fd_fdstat_get: () => 58, // ERRNO badf
    proc_exit: () => {
      throw new Error("guest proc_exit");
    },
    sched_yield: () => 0,
  },
};

// --- wasm loading ------------------------------------------------------------

async function loadWasm(): Promise<{ ok: true } | { ok: false; detail: string }> {
  if (instance) return { ok: true };
  try {
    const res = await fetch(WASM_URL);
    if (!res.ok) return { ok: false, detail: `wasm asset fetch -> ${res.status}` };
    const bytes = await res.arrayBuffer();
    const wm = await WebAssembly.compile(bytes);
    const needed = WebAssembly.Module.imports(wm).map((i) => `${i.module}.${i.name}`);
    const provided = new Set(Object.keys(wasiShim.wasi_snapshot_preview1));
    const missing = [...new Set(needed)].filter(
      (n) => n.startsWith("wasi_snapshot_preview1.") && !provided.has(n.slice(23)),
    );
    if (missing.length > 0) {
      return { ok: false, detail: `unlinked WASI imports: ${missing.join(", ")}` };
    }
    instance = await WebAssembly.instantiate(wm, wasiShim);
    const ex = instance.exports;
    memory = (ex.memory ?? null) as WebAssembly.Memory | null;
    if (!memory) return { ok: false, detail: "module exports no memory" };
    const init = ex._initialize as (() => void) | undefined;
    init?.();
    glAlloc = ex.gl_alloc as (len: number) => number;
    glFree = ex.gl_free as (ptr: number, len: number) => void;
    glCall = ex.gl_call as (ptr: number, len: number) => bigint;
    if (!glAlloc || !glFree || !glCall) {
      return { ok: false, detail: "module missing gl_alloc/gl_call/gl_free" };
    }
    return { ok: true };
  } catch (e) {
    return { ok: false, detail: String(e).slice(0, 300) };
  }
}

// --- gl_call over the JSON ABI -----------------------------------------------

function callGl(requestJson: string):
  | { ok: true; value: Record<string, unknown> }
  | { ok: false; reason: string } {
  const reqBytes = new TextEncoder().encode(requestJson);
  const ptr = glAlloc(reqBytes.length);
  if (ptr === 0) {
    return { ok: false, reason: `gl_alloc refused ${reqBytes.length} bytes` };
  }
  new Uint8Array(memory!.buffer, ptr, reqBytes.length).set(reqBytes);
  const packed = glCall(ptr, reqBytes.length);
  const outPtr = Number(packed >> 32n);
  const outLen = Number(packed & 0xffffffffn);
  const out = new Uint8Array(memory!.buffer, outPtr, outLen).slice();
  glFree(outPtr, outLen);
  glFree(ptr, reqBytes.length);
  try {
    const value = JSON.parse(new TextDecoder().decode(out)) as Record<string, unknown>;
    return { ok: true, value };
  } catch {
    return { ok: false, reason: "gl_call response was not JSON" };
  }
}

/**
 * Pure sieve evaluation over an injected gl JSON-call function — the real
 * `callGl` in the worker, a fake responder in plain-node courts. Exported so
 * the fail-closed admission contract is courtable without WebAssembly.
 *
 * W1 (expl1) fail-closed law: admission (status 0) requires an
 * explicitly-present, boolean-typed `conforms === true` on op-1. A missing
 * field refuses typed `SHACL_VERDICT_ABSENT`; any other wrong shape —
 * non-boolean, missing results, wrong ABI — refuses typed
 * `SIEVE_RESPONSE_MALFORMED`. The gate can never admit on a silent ABI drift.
 */
export function evaluateSieve(
  op: 1 | 2,
  payload: Uint8Array,
  call: (requestJson: string) =>
    | { ok: true; value: Record<string, unknown> }
    | { ok: false; reason: string },
):
  | { status: 0 }
  | { status: 1; reason: string }
  | { status: 2; detail: string } {
  const text = new TextDecoder("utf-8", { fatal: false }).decode(payload);
  const request =
    op === 1
      ? { op: "shacl", data: { text }, shapes: reticleText }
      : { op: "n3", text };
  const r = call(JSON.stringify(request));
  if (!r.ok) return { status: 1, reason: r.reason };
  if (r.value.ok !== true) {
    const errObj = r.value.error as { message?: string; kind?: string } | undefined;
    const reason = errObj?.message ?? errObj?.kind ?? "refused";
    return { status: 1, reason: String(reason).slice(0, 512) };
  }
  if (op === 1) {
    // Fail-closed: admission requires `conforms` present AND boolean-typed.
    // An absent verdict (ABI drift) refuses typed SHACL_VERDICT_ABSENT; any
    // other non-boolean shape refuses SIEVE_RESPONSE_MALFORMED.
    if (!("conforms" in r.value)) {
      return { status: 1, reason: "SHACL_VERDICT_ABSENT: conforms field absent from shacl verdict" };
    }
    if (typeof r.value.conforms !== "boolean") {
      return {
        status: 1,
        reason: `SIEVE_RESPONSE_MALFORMED: non-boolean conforms (${typeof r.value.conforms})`,
      };
    }
    // op-1 verdict ABI also requires the results array to be present.
    if (!Array.isArray(r.value.results)) {
      return {
        status: 1,
        reason: "SIEVE_RESPONSE_MALFORMED: results field absent from shacl verdict",
      };
    }
    if (r.value.conforms === false) {
      const results = r.value.results as Array<Record<string, unknown>>;
      const first = results[0];
      const why = first
        ? `${String(first.component ?? "violation")} at ${String(first.focus ?? "?")}`
        : "non-conformant";
      return { status: 1, reason: `non-conformant: ${why}` };
    }
  }
  return { status: 0 };
}

function evaluate(op: 1 | 2, payload: Uint8Array):
  | { status: 0 }
  | { status: 1; reason: string }
  | { status: 2; detail: string } {
  return evaluateSieve(op, payload, callGl);
}

// --- message loop ------------------------------------------------------------

self.onmessage = async (ev: MessageEvent<RequestMsg>) => {
  const msg = ev.data;
  const t0 = performance.now();
  const ms = () => Math.round(performance.now() - t0);
  try {
    if (msg.type === "INIT") {
      const load = await loadWasm();
      if (!load.ok) {
        const out: ResponseMsg = { id: msg.id, verdict: { status: 2, detail: load.detail, ms: ms() } };
        (self as unknown as Worker).postMessage(out);
        return;
      }
      reticleText = msg.reticle ? new TextDecoder().decode(unpack4(msg.reticle)) : "";
      const cap = callGl(JSON.stringify({ op: "capabilities" }));
      const detail = cap.ok ? `artifact up; abi=${String(cap.value.abi_version)}` : "artifact up; capabilities probe refused";
      const out: ResponseMsg = { id: msg.id, verdict: { status: 0, ms: ms() } };
      void detail;
      (self as unknown as Worker).postMessage(out);
      return;
    }
    // ADMIT_INPUT
    if (!instance) {
      const out: ResponseMsg = {
        id: msg.id,
        verdict: { status: 2, detail: "wasm not initialized", ms: ms() },
      };
      (self as unknown as Worker).postMessage(out);
      return;
    }
    const body = msg.body ? unpack4(msg.body) : new Uint8Array();
    const v = evaluate(msg.op ?? 2, body);
    const verdict: ResponseMsg["verdict"] =
      v.status === 0
        ? { status: 0, ms: ms() }
        : v.status === 1
          ? { status: 1, reason: v.reason, ms: ms() }
          : { status: 2, detail: v.detail, ms: ms() };
    (self as unknown as Worker).postMessage({ id: msg.id, verdict } satisfies ResponseMsg);
  } catch (e) {
    // W6 (expl1): a malformed frame or any unexpected throw inside the
    // handler must still post a typed status-2 verdict — the main thread's
    // pending call settles within the Guard timeout via this response, not
    // by hanging until GUARD_TIMEOUT.
    (self as unknown as Worker).postMessage({
      id: msg.id,
      verdict: { status: 2, detail: `WORKER_FAULT: ${String(e).slice(0, 300)}`, ms: ms() },
    } satisfies ResponseMsg);
  }
};

function unpack4(frame: Uint8Array): Uint8Array {
  const dv = new DataView(frame.buffer, frame.byteOffset, frame.byteLength);
  const len = dv.getUint32(0, false);
  if (4 + len !== frame.length) {
    throw new Error(`packet-4 length prefix mismatch: ${len} vs ${frame.length - 4}`);
  }
  return frame.slice(4);
}
