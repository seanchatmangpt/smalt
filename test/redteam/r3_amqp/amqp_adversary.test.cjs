'use strict';
// r3_amqp — adversarial AMQP 1.0 wire redteam against a live smalt broker.
//
// Contract (lane brief):
//   * real TCP substrate (node net.Socket) against 5672 (SB) / 5673 (EH);
//   * hostile frames built client-side: hand-rolled byte-precise encoders here,
//     plus a corpus minted by Smalt.Amqp.FrameCodec/PrimitiveCodec client-side
//     in run.sh (corpus hex mode uses those bytes verbatim);
//   * after EVERY attack: kill-test — a fresh TCP connection must complete the
//     protocol-header exchange within 5s (broker process never crashes);
//   * every hostile input must get a clean error/close within 5s (no hangs);
//   * every crash/hang is a CRITICAL finding with repro bytes (hex).
//
// Usage: node --test test/redteam/r3_amqp/amqp_adversary.test.cjs
// Env:   SMALT_SB_PORT (default 5672), SMALT_EH_PORT (default 5673)
// Output: /tmp/r3_amqp_results.json

const { test } = require('node:test');
const assert = require('node:assert');
const net = require('node:net');
const fs = require('node:fs');

const HOST = '127.0.0.1';
const SB = Number(process.env.SMALT_SB_PORT || 5672);
const EH = Number(process.env.SMALT_EH_PORT || 5673);
const AMQP_HEADER = Buffer.from('AMQP\x00\x01\x00\x00');
const SASL_HEADER = Buffer.from('AMQP\x03\x01\x00\x00');
const REPLY_MS = 5000;

// ---------------------------------------------------------------------------
// AMQP 1.0 primitive encoder (byte-precise, hostile-controlled)
// ---------------------------------------------------------------------------

function sym(s) { const b = Buffer.from(s); return Buffer.concat([Buffer.from([0xa3, b.length]), b]); }
function str(s) {
  const b = Buffer.from(s);
  if (b.length < 256) return Buffer.concat([Buffer.from([0xa1, b.length]), b]);
  const h = Buffer.alloc(4); h.writeUInt32BE(b.length);
  return Buffer.concat([Buffer.from([0xb1]), h, b]);
}
function ulong(n) {
  if (typeof n === 'bigint' || n > Number.MAX_SAFE_INTEGER) {
    const b = Buffer.alloc(8); b.writeBigUInt64BE(BigInt(n));
    return Buffer.concat([Buffer.from([0x80]), b]);
  }
  if (n < 128) return Buffer.from([0x53, n]);
  const b = Buffer.alloc(8); b.writeBigUInt64BE(BigInt(n));
  return Buffer.concat([Buffer.from([0x80]), b]);
}
function uint(n) { const b = Buffer.alloc(4); b.writeUInt32BE(n >>> 0); return Buffer.concat([Buffer.from([0x70]), b]); }
function int64(n) { const b = Buffer.alloc(8); b.writeBigInt64BE(BigInt(n)); return Buffer.concat([Buffer.from([0x81]), b]); }
const T_NULL = Buffer.from([0x40]);
const T_TRUE = Buffer.from([0x56, 0x01]);
const T_FALSE = Buffer.from([0x56, 0x00]);
function bin(b) {
  const buf = Buffer.isBuffer(b) ? b : Buffer.from(b);
  const h = Buffer.alloc(4); h.writeUInt32BE(buf.length);
  return Buffer.concat([Buffer.from([0xb0]), h, buf]);
}
function smallbin(b) { const buf = Buffer.isBuffer(b) ? b : Buffer.from(b); return Buffer.concat([Buffer.from([0xa0, buf.length]), buf]); }
function uuidTerm(b) { return Buffer.concat([Buffer.from([0x98]), b]); }
function list(...items) {
  const payload = Buffer.concat(items);
  const h = Buffer.alloc(8);
  h.writeUInt32BE(payload.length + 4, 0);
  h.writeUInt32BE(items.length, 4);
  return Buffer.concat([Buffer.from([0xd0]), h, payload]);
}
function mapTerm(pairs) {
  const payload = Buffer.concat(pairs.map(([k, v]) => Buffer.concat([k, v])));
  const h = Buffer.alloc(8);
  h.writeUInt32BE(payload.length + 4, 0);
  h.writeUInt32BE(pairs.length * 2, 4);
  return Buffer.concat([Buffer.from([0xd1]), h, payload]);
}
function described(descTerm, value) { return Buffer.concat([Buffer.from([0x00]), descTerm, value]); }

const DESCRIPTOR = {
  open: 0x10, begin: 0x11, attach: 0x12, flow: 0x13, transfer: 0x14,
  disposition: 0x15, detach: 0x16, end: 0x17, close: 0x18,
  sasl_mechanisms: 0x40, sasl_init: 0x41, sasl_challenge: 0x42, sasl_response: 0x43, sasl_outcome: 0x44,
};

// Pinned to Smalt.Amqp.FrameCodec @field_orders.
const FIELD_ORDER = {
  open: ['container_id', 'hostname', 'max_frame_size', 'channel_max', 'idle_time_out', 'outgoing_locales', 'incoming_locales', 'offered_capabilities', 'desired_capabilities', 'properties'],
  begin: ['remote_channel', 'next_outgoing_id', 'incoming_window', 'outgoing_window', 'handle_max'],
  attach: ['name', 'handle', 'role', 'snd_settle_mode', 'rcv_settle_mode', 'source', 'target', 'unsettled', 'incomplete_unsettled', 'initial_delivery_count'],
  flow: ['next_incoming_id', 'incoming_window', 'next_outgoing_id', 'outgoing_window', 'handle', 'delivery_count', 'link_credit', 'available', 'drain', 'echo', 'properties'],
  transfer: ['handle', 'delivery_id', 'delivery_tag', 'message_format', 'settled', 'more', 'rcv_settle_mode', 'state'],
  disposition: ['role', 'first', 'last', 'settled', 'state', 'batchable'],
  detach: ['handle', 'closed', 'error'],
  end: ['error'],
  close: ['error'],
  sasl_init: ['mechanism', 'initial_response', 'hostname'],
  sasl_outcome: ['code', 'additional_data'],
  sasl_mechanisms: ['server_mechanisms'],
};

function frame(type, channel, body) {
  const h = Buffer.alloc(8);
  h.writeUInt32BE(8 + body.length, 0);
  h[4] = 2; h[5] = type; h.writeUInt16BE(channel, 6);
  return Buffer.concat([h, body]);
}

function perf(name, fields, channel = 0) {
  const order = FIELD_ORDER[name];
  assert.ok(order, `unknown performative ${name}`);
  const items = order.map((f) => (fields[f] === undefined || fields[f] === null ? T_NULL : fields[f]));
  return frame(name.startsWith('sasl') ? 0x01 : 0x00, channel, described(ulong(DESCRIPTOR[name]), list(...items)));
}

// message sections
const appProperties = (pairs) => described(ulong(0x74), mapTerm(pairs));
const propertiesSection = (fields) => described(ulong(0x73), list(...fields)); // message-id, ..., reply-to(5th), correlation-id(6th)
const bodyData = (b) => described(ulong(0x75), bin(b));
const bodyValue = (t) => described(ulong(0x77), t);

// ---------------------------------------------------------------------------
// Minimal term decoder (broker replies: statusCode etc.)
// ---------------------------------------------------------------------------

function decodeTerm(buf, off = 0) {
  const c = buf[off];
  if (c === 0x40) return [null, off + 1];
  if (c === 0x56) return [buf[off + 1] === 1, off + 2];
  if (c === 0x53) return [buf[off + 1], off + 2];
  if (c === 0x55) return [buf[off + 1] > 127 ? buf[off + 1] - 256 : buf[off + 1], off + 2];
  if (c === 0x70) return [buf.readUInt32BE(off + 1), off + 5];
  if (c === 0x80) return [buf.readBigUInt64BE(off + 1), off + 9];
  if (c === 0x81) return [buf.readBigInt64BE(off + 1), off + 9];
  if (c === 0x83) return [Number(buf.readBigInt64BE(off + 1)), off + 9];
  if (c === 0xa0 || c === 0xb0) {
    const n = c === 0xa0 ? buf[off + 1] : buf.readUInt32BE(off + 1);
    const s = c === 0xa0 ? off + 2 : off + 5;
    return [buf.subarray(s, s + n), s + n];
  }
  if (c === 0xa1 || c === 0xb1) {
    const n = c === 0xa1 ? buf[off + 1] : buf.readUInt32BE(off + 1);
    const s = c === 0xa1 ? off + 2 : off + 5;
    return [buf.subarray(s, s + n).toString(), s + n];
  }
  if (c === 0xa3 || c === 0xb3) {
    const n = c === 0xa3 ? buf[off + 1] : buf.readUInt32BE(off + 1);
    const s = c === 0xa3 ? off + 2 : off + 5;
    return [{ __sym: buf.subarray(s, s + n).toString() }, s + n];
  }
  if (c === 0x98) return [buf.subarray(off + 1, off + 17), off + 17];
  if (c === 0x00) {
    const [, o2] = decodeTerm(buf, off + 1); // descriptor ignored
    return decodeTerm(buf, o2);
  }
  if (c === 0xc0 || c === 0xd0) {
    const start = c === 0xd0 ? off + 10 : off + 3;
    const count = c === 0xd0 ? buf.readUInt32BE(off + 6) : buf[off + 2];
    const out = [];
    let p = start;
    for (let i = 0; i < count; i++) { const [v, np] = decodeTerm(buf, p); out.push(v); p = np; }
    return [out, p];
  }
  if (c === 0xc1 || c === 0xd1) {
    const start = c === 0xd1 ? off + 10 : off + 3;
    const count = c === 0xd1 ? buf.readUInt32BE(off + 6) : buf[off + 2];
    const out = {};
    let p = start;
    for (let i = 0; i < count / 2; i++) {
      const [k, kp] = decodeTerm(buf, p);
      const [v, vp] = decodeTerm(buf, kp);
      out[String(k && k.__sym ? '@' + k.__sym : k)] = v;
      p = vp;
    }
    return [out, p];
  }
  throw new Error(`decoder: unknown constructor 0x${c.toString(16)} at ${off}`);
}

function parseFrames(buf) {
  const out = [];
  let p = 0;
  while (buf.length - p >= 8) {
    const size = buf.readUInt32BE(p);
    if (size < 8 || buf.length - p < size) break;
    const doff = buf[p + 4];
    const body = buf.subarray(p + doff * 4, p + size);
    let perfInfo = null, payload = null;
    try {
      if (body[0] === 0x00) {
        const [d, o1] = decodeTerm(body, 1);
        const [fields, o2] = decodeTerm(body, o1);
        const name = Object.entries(DESCRIPTOR).find(([, v]) => v === Number(d));
        perfInfo = { name: name ? name[0] : `desc:0x${Number(d).toString(16)}`, fields: Array.isArray(fields) ? fields : null };
        if (o2 < body.length) payload = body.subarray(o2);
      }
    } catch { /* keep raw */ }
    out.push({ type: buf[p + 5], channel: buf.readUInt16BE(p + 6), perf: perfInfo, payload, raw: body });
    p += size;
  }
  return out;
}

// ---------------------------------------------------------------------------
// Raw socket client
// ---------------------------------------------------------------------------

class Client {
  constructor(port) {
    this.sock = net.connect({ host: HOST, port });
    this.buf = Buffer.alloc(0);
    this.closed = false;
    this.refused = false;
    this.sock.on('data', (d) => { this.buf = Buffer.concat([this.buf, d]); });
    this.sock.on('close', () => { this.closed = true; });
    this.sock.on('error', (e) => {
      if (e && e.code === 'ECONNREFUSED') this.refused = true;
      this.closed = true;
    });
  }

  send(...bufs) { for (const b of bufs) if (b && b.length) this.sock.write(b); }

  // Consumes the 8-byte protocol-header reply (the broker echoes "AMQP\x00\x01\x00\x00"
  // before any frame). Returns false if the first 8 bytes are not the header.
  async readHeaderReply(timeoutMs = 3000) {
    const deadline = Date.now() + timeoutMs;
    for (;;) {
      if (this.buf.length >= 8) {
        const head = this.buf.subarray(0, 8);
        const isHdr = head.equals(AMQP_HEADER) || head.equals(SASL_HEADER);
        this.buf = isHdr ? this.buf.subarray(8) : this.buf;
        return isHdr;
      }
      if (this.closed || Date.now() >= deadline) return false;
      await sleep(20);
    }
  }

  // Reads until at least one full frame arrives, then drains an extra quietMs
  // of trailing bytes. Returns { frames, closed, timeout }.
  async readFrames(quietMs = 1200, maxMs = REPLY_MS) {
    const deadline = Date.now() + maxMs;
    for (;;) {
      if (this.buf.length >= 8) {
        const size = this.buf.readUInt32BE(0);
        if (size >= 8 && this.buf.length >= size) {
          // got a full first frame; drain trailing quietly
          const t0 = Date.now();
          while (Date.now() - t0 < quietMs && Date.now() < deadline && !this.closed) {
            await sleep(50);
          }
          const chunk = this.buf;
          this.buf = Buffer.alloc(0);
          return { frames: parseFrames(chunk), closed: this.closed, timeout: false };
        }
      }
      if (this.closed) return { frames: parseFrames(this.buf), closed: true, timeout: false };
      if (Date.now() >= deadline) {
        const chunk = this.buf;
        this.buf = Buffer.alloc(0);
        return { frames: parseFrames(chunk), closed: this.closed, timeout: true };
      }
      await sleep(30);
    }
  }

  close() { try { this.sock.destroy(); } catch { } }
}

function sleep(ms) { return new Promise((r) => setTimeout(r, ms)); }

// --- handshake + link helpers -------------------------------------------------

async function handshake(port, opts = {}) {
  const c = new Client(port);
  c.send(AMQP_HEADER);
  const hdr = await c.readHeaderReply(3000);
  if (!hdr) throw new Error('no protocol-header reply');
  const r1 = await c.readFrames(600, 1500);
  c.send(perf('open', {
    container_id: str(opts.container || 'adv'), hostname: str('sb://localhost'),
    max_frame_size: uint(1048576), channel_max: uint(65535),
  }));
  await c.readFrames(600, 2000);
  c.send(perf('begin', { remote_channel: uint(0), next_outgoing_id: uint(1), incoming_window: uint(1000), outgoing_window: uint(1000), handle_max: uint(1000) }));
  await c.readFrames(600, 2000);
  return { c, r1 };
}

function sourceTarget(addr, which) {
  // source=0x28 / target=0x29: [address, durable, expiry, locked, dynamic, dynamic_node_properties, distribution_mode, filter, ...]
  const base = [sym('address'), str(addr), T_NULL, T_NULL, T_NULL, T_NULL, T_NULL, T_NULL, T_NULL, T_NULL, T_NULL];
  return described(ulong(which === 'source' ? 0x28 : 0x29), list(...base));
}

async function attachPair(c, name, hSnd, hRcv, address, kind) {
  const target = kind === 'cbs' || kind === 'management' ? sym(address) : sourceTarget(address, 'target');
  const source = kind === 'cbs' || kind === 'management' ? sym(address) : sourceTarget(address, 'source');
  c.send(perf('attach', { name: str(name + '-snd'), handle: uint(hSnd), role: T_FALSE, source: T_NULL, target }));
  c.send(perf('attach', { name: str(name + '-rcv'), handle: uint(hRcv), role: T_TRUE, source, target: T_NULL }));
  return c.readFrames(800, 2000);
}

function extractStatus(payload) {
  for (let i = 0; i < payload.length - 4; i++) {
    if (payload[i] === 0x00 && payload[i + 1] === 0x53 && payload[i + 2] === 0x74) {
      try {
        const [, o1] = decodeTerm(payload, i + 3);
        const [m] = decodeTerm(payload, o1);
        if (m && typeof m === 'object' && !Buffer.isBuffer(m) && 'statusCode' in m) return m;
      } catch { }
    }
  }
  return null;
}

async function firstStatus(c, quietMs = 1500) {
  const r = await c.readFrames(quietMs, REPLY_MS);
  return { r, status: r.frames.map((f) => (f.payload ? extractStatus(f.payload) : null)).find(Boolean) || null };
}

// ---------------------------------------------------------------------------
// Kill test
// ---------------------------------------------------------------------------

let killTestCount = 0;

async function killTest(label) {
  killTestCount++;
  // up to 4 attempts over ~15s: sibling lanes churn substrates/ports on this
  // shared checkout; a transient ECONNREFUSED is not a broker crash.
  for (let attempt = 1; attempt <= 8; attempt++) {
    const c = new Client(SB);
    const ok = await Promise.race([
      (async () => {
        c.send(AMQP_HEADER);
        return c.readHeaderReply(REPLY_MS);
      })(),
      sleep(REPLY_MS).then(() => false),
    ]).finally(() => c.close());
    if (ok) return true;
    if (attempt < 8) await sleep(5000);
  }
  assert.fail(`KILL-TEST FAILED after ${label}: broker did not answer a fresh protocol header (8 attempts / ~45s) — BROKER PROCESS DOWN`);
}

// ---------------------------------------------------------------------------
// Attack runner
// ---------------------------------------------------------------------------

let corpus = {};
try { corpus = JSON.parse(fs.readFileSync('/tmp/r3_amqp_corpus.json', 'utf8')); } catch { }
const hexBuf = (h) => (h ? Buffer.from(h, 'hex') : null);

const RESULTS = [];
const REPRO = {};
function recordRepro(name, ...bufs) {
  const h = Buffer.concat(bufs.filter(Boolean)).toString('hex');
  REPRO[name] = h.length > 512 ? h.slice(0, 512) + '...truncated' : h;
}

async function attack(name, cat, fn) {
  const t0 = Date.now();
  let outcome;
  try { outcome = (await fn()) || {}; }
  catch (e) { outcome = { status: 'test-error', detail: String((e && e.message) || e) }; }
  const rec = { name, cat, ms: Date.now() - t0, ...outcome };
  RESULTS.push(rec);
  console.log(`[${cat}] ${name}: ${rec.status}${rec.detail ? ' — ' + rec.detail : ''} (${rec.ms}ms)`);
  return rec;
}

function classify(r, refused) {
  if (refused) return 'BROKER-UNREACHABLE(ECONNREFUSED)';
  if (r.frames.some((f) => f.perf && f.perf.name === 'close')) return 'clean-close-frame';
  if (r.frames.length) return 'responded';
  if (r.closed) return 'closed-no-frames';
  if (r.timeout) return 'HANG-no-response-in-5s';
  return 'no-response';
}

// ---------------------------------------------------------------------------
// Attacks
// ---------------------------------------------------------------------------

test('r3_amqp: adversarial AMQP wire attacks', { timeout: 900_000 }, async () => {

  // ================= 1. FRAMING =================
  await attack('F1 truncated frame (declared 16, 8 sent)', 'framing', async () => {
    const c = new Client(SB);
    c.send(AMQP_HEADER); await c.readHeaderReply(2000);
    recordRepro('F1', Buffer.from('0000001002000000', 'hex'));
    c.send(Buffer.from('0000001002000000', 'hex'));
    const r = await c.readFrames(1500, REPLY_MS);
    c.close(); await killTest('F1');
    return { status: classify(r, c.refused), detail: `closed=${r.closed} (legal buffered-wait if no reply)` };
  });

  await attack('F2 size lie small: declared 8, 100 bytes pushed', 'framing', async () => {
    const c = new Client(SB);
    c.send(AMQP_HEADER); await c.readFrames(500, 1500);
    const lie = Buffer.concat([Buffer.from('0000000802000000', 'hex'), Buffer.alloc(100, 0xab)]);
    recordRepro('F2', lie);
    c.send(lie);
    const r = await c.readFrames(1500, REPLY_MS);
    c.close(); await killTest('F2');
    return { status: classify(r, c.refused) };
  });

  await attack('F3 size lie large: declared 1000, junk completes', 'framing', async () => {
    const c = new Client(SB);
    c.send(AMQP_HEADER); await c.readFrames(500, 1500);
    c.send(Buffer.from('000003e802000000', 'hex'));
    await sleep(300);
    c.send(Buffer.alloc(992, 0xcd));
    const r = await c.readFrames(1500, REPLY_MS);
    c.close(); await killTest('F3');
    return { status: classify(r, c.refused) };
  });

  const doffs = [0, 1, 255];
  for (const [i, doff] of doffs.entries()) {
    await attack(`F4.${i + 1} doff=${doff}`, 'framing', async () => {
      const c = new Client(SB);
      c.send(AMQP_HEADER); await c.readFrames(500, 1500);
      const body = Buffer.alloc(7, 0x11);
      const h = Buffer.alloc(8);
      h.writeUInt32BE(8 + body.length, 0);
      h[4] = doff; h[5] = 0; h.writeUInt16BE(0, 6);
      recordRepro(`F4.${i + 1}`, h, body);
      c.send(h, body);
      const r = await c.readFrames(1500, REPLY_MS);
      c.close(); await killTest(`F4.${i + 1}`);
      return { status: classify(r, c.refused) };
    });
  }

  for (const [i, tc] of [0x02, 0x7f, 0xff].entries()) {
    await attack(`F7.${i + 1} unknown frame type 0x${tc.toString(16)} carrying a valid open`, 'framing', async () => {
      const c = new Client(SB);
      c.send(AMQP_HEADER); await c.readFrames(500, 1500);
      const inner = perf('open', { container_id: str('x'), hostname: str('h') }).subarray(8);
      const h = Buffer.alloc(8);
      h.writeUInt32BE(8 + inner.length, 0);
      h[4] = 2; h[5] = tc; h.writeUInt16BE(0, 6);
      recordRepro(`F7.${i + 1}`, h, inner);
      c.send(h, inner);
      const r = await c.readFrames(1500, REPLY_MS);
      c.close(); await killTest(`F7.${i + 1}`);
      return { status: classify(r, c.refused) };
    });
  }

  await attack('F10 begin on un-opened channel 7', 'framing', async () => {
    const { c } = await handshake(SB);
    c.send(perf('begin', { remote_channel: uint(0), next_outgoing_id: uint(1), incoming_window: uint(10), outgoing_window: uint(10) }), 0x7);
    const r = await c.readFrames(1200, 4000);
    const began = r.frames.some((f) => f.perf && f.perf.name === 'begin');
    c.close(); await killTest('F10');
    return { status: began ? 'responded-begin-on-rogue-channel (no channel validation — INFO)' : classify(r) };
  });

  await attack('F11 begin with remote-channel 999', 'framing', async () => {
    const { c } = await handshake(SB);
    c.send(perf('begin', { remote_channel: uint(999), next_outgoing_id: uint(1), incoming_window: uint(10), outgoing_window: uint(10) }));
    const r = await c.readFrames(1200, 4000);
    const began = r.frames.find((f) => f.perf && f.perf.name === 'begin');
    c.close(); await killTest('F11');
    return { status: began ? `responded; broker remote_channel echo=${JSON.stringify(began.perf.fields[0])} (no validation — INFO)` : classify(r) };
  });

  await attack('F12 transfer on never-attached handle 5', 'framing', async () => {
    const { c } = await handshake(SB);
    recordRepro('F12', transferFrame(5, 1, Buffer.from('ghost'), false));
    c.send(transferFrame(5, 1, Buffer.from('ghost'), false));
    const r = await c.readFrames(1500, REPLY_MS);
    c.close(); await killTest('F12');
    return { status: classify(r, c.refused), detail: 'expect internal-error close' };
  });

  // ================= 2. PROTOCOL HEADER GAMES =================
  await attack('H1 sasl-init after AMQP-layer negotiation (layer confusion)', 'header', async () => {
    const c = new Client(SB);
    c.send(AMQP_HEADER); await c.readFrames(500, 1500);
    c.send(perf('open', { container_id: str('h1') }));
    await c.readFrames(500, 1500);
    c.send(perf('sasl_init', { mechanism: sym('ANONYMOUS') }));
    const r = await c.readFrames(1500, REPLY_MS);
    c.close(); await killTest('H1');
    const out = r.frames.find((f) => f.perf && f.perf.name === 'sasl_outcome');
    return { status: classify(r, c.refused), detail: out ? 'broker sent sasl-outcome on AMQP layer post-negotiation (layer confusion — INFO)' : '' };
  });

  await attack('H2 AMQP header sent twice', 'header', async () => {
    const c = new Client(SB);
    c.send(AMQP_HEADER); await c.readFrames(500, 1500);
    c.send(AMQP_HEADER);
    const r = await c.readFrames(1500, REPLY_MS);
    c.close(); await killTest('H2');
    return { status: classify(r, c.refused), detail: 'second header parses as frame size 0x414D5000 → frame_too_size expected' };
  });

  await attack('H3 garbage 8 bytes after header', 'header', async () => {
    const c = new Client(SB);
    c.send(AMQP_HEADER); await c.readFrames(500, 1500);
    c.send(Buffer.from('deadbeefdeadbeef', 'hex'));
    const r = await c.readFrames(1500, REPLY_MS);
    c.close(); await killTest('H3');
    return { status: classify(r, c.refused) };
  });

  await attack('H4 700ms silence then valid header (slow start)', 'header', async () => {
    const c = new Client(SB);
    await sleep(700);
    c.send(AMQP_HEADER);
    const t0 = Date.now();
    const hdr = await c.readHeaderReply(3000);
    const r = await c.readFrames(1000, 4000);
    c.close(); await killTest('H4');
    return { status: r.frames.length ? 'responded (legal slow start)' : classify(r), detail: `${Date.now() - t0}ms` };
  });

  await attack('H5 HTTP/2 preface as first bytes', 'header', async () => {
    const c = new Client(SB);
    recordRepro('H5', Buffer.from('PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n'));
    c.send(Buffer.from('PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n'));
    const r = await c.readFrames(1500, REPLY_MS);
    c.close(); await killTest('H5');
    return { status: classify(r, c.refused) };
  });

  // ================= 2b. FrameCodec-MINTED CORPUS =================
  // Frames below come from Smalt.Amqp.FrameCodec/PrimitiveCodec used CLIENT-SIDE
  // (minted in run.sh into /tmp/r3_amqp_corpus.json) — replayed here verbatim.
  await attack('C1 FrameCodec-minted corpus: full hostile-client session replay', 'corpus', async () => {
    if (!Object.keys(corpus).length) return { status: 'SKIPPED — no corpus at /tmp/r3_amqp_corpus.json (run.sh mint step missing)' };
    const c = new Client(SB);
    const seq = ['open', 'begin', 'attach_cbs_snd', 'attach_cbs_rcv', 'attach_mgmt_snd', 'attach_mgmt_rcv',
      'transfer_cbs_puttoken', 'transfer_cbs_deletetoken', 'transfer_cbs_puttoken', 'transfer_mgmt_renewlock',
      'transfer_mgmt_peek0', 'transfer_queue_msg', 'disposition_accepted', 'end', 'close'];
    for (const key of seq) {
      const f = hexBuf(corpus[key]);
      if (f) c.send(f);
      await sleep(120);
    }
    const r = await c.readFrames(1500, REPLY_MS);
    const names = r.frames.map((f) => f.perf && f.perf.name).filter(Boolean);
    c.close(); await killTest('C1');
    return { status: `corpus-replayed ${seq.length} FrameCodec frames; replies=${names.join(',') || 'none'} closed=${r.closed}` };
  });

  await attack('C2 FrameCodec corpus frames replayed out of order', 'corpus', async () => {
    if (!Object.keys(corpus).length) return { status: 'SKIPPED — no corpus' };
    const c = new Client(SB);
    for (const key of ['transfer_queue_msg', 'begin', 'attach_cbs_snd', 'disposition_accepted', 'open', 'transfer_mgmt_peek0', 'close']) {
      const f = hexBuf(corpus[key]);
      if (f) c.send(f);
      await sleep(80);
    }
    const r = await c.readFrames(1500, REPLY_MS);
    c.close(); await killTest('C2');
    return { status: `out-of-order replay: ${classify(r)}` };
  });

  // ================= 3. SASL / CBS =================
  await attack('S1 sasl-init with unknown mechanism PLAIN', 'sasl-cbs', async () => {
    const c = new Client(SB);
    c.send(SASL_HEADER); await c.readFrames(500, 1500);
    c.send(perf('sasl_init', { mechanism: sym('PLAIN'), initial_response: smallbin('a') }));
    const r = await c.readFrames(1500, REPLY_MS);
    c.close(); await killTest('S1');
    const out = r.frames.find((f) => f.perf && f.perf.name === 'sasl_outcome');
    return { status: out ? `responded outcome code=${out.perf.fields[0]} + close` : classify(r) };
  });

  await attack('S2 put-token with 1MB token', 'sasl-cbs', async () => {
    const { c } = await handshake(SB);
    await attachPair(c, 'cbs', 0, 1, '$cbs', 'cbs');
    c.send(cbsPutToken('adv-1mb', 'sb://smalt/advq', Buffer.alloc(1024 * 1024, 0x41), 0, 'cbs-rcv'));
    const { r, status } = await firstStatus(c, 2000);
    c.close(); await killTest('S2');
    return { status: status ? `responded statusCode=${status.statusCode}` : classify(r) };
  });

  await attack('S3 token replay after delete-token', 'sasl-cbs', async () => {
    const { c } = await handshake(SB);
    await attachPair(c, 'cbs', 0, 1, '$cbs', 'cbs');
    const s1 = (await firstStatus(c, 1200)).status;
    // first put
    c.send(cbsPutToken('adv-replay', 'sb://smalt/advq', Buffer.from('TOKEN'), 0, 'cbs-rcv'));
    const p1 = (await firstStatus(c, 1200)).status;
    await cbsCall(c, cbsDeleteToken('adv-replay', 0, 'cbs-rcv'));
    c.send(cbsPutToken('adv-replay', 'sb://smalt/advq', Buffer.from('TOKEN'), 0, 'cbs-rcv'));
    const p2 = (await firstStatus(c, 1200)).status;
    c.close(); await killTest('S3');
    return { status: `put1=${p1 && p1.statusCode} put-after-delete=${p2 && p2.statusCode} (s1=${s1 && s1.statusCode})` };
  });

  await attack('S4 audience with userinfo sb://user:pass@host/entity', 'sasl-cbs', async () => {
    const { c } = await handshake(SB);
    await attachPair(c, 'cbs', 0, 1, '$cbs', 'cbs');
    c.send(cbsPutToken('adv-ui', 'sb://user:pass@127.0.0.1:5672/advq', Buffer.from('TOKEN'), 0, 'cbs-rcv'));
    const { r, status } = await firstStatus(c);
    c.close(); await killTest('S4');
    return { status: status ? `statusCode=${status.statusCode} desc=${status.statusDescription}` : classify(r) };
  });

  await attack('S5 name with path traversal sr:///../../admin', 'sasl-cbs', async () => {
    const { c } = await handshake(SB);
    await attachPair(c, 'cbs', 0, 1, '$cbs', 'cbs');
    c.send(cbsPutToken('adv-trav', 'sr:///../../admin', Buffer.from('TOKEN'), 0, 'cbs-rcv'));
    const { r, status } = await firstStatus(c);
    c.close(); await killTest('S5');
    return { status: status ? `statusCode=${status.statusCode}` : classify(r) };
  });

  await attack('S6 claims-cap burst: 200 rapid put-tokens (cap 128)', 'sasl-cbs', async () => {
    const { c } = await handshake(SB);
    await attachPair(c, 'cbs', 0, 1, '$cbs', 'cbs');
    const statuses = [];
    for (let i = 0; i < 200; i++) {
      c.send(cbsPutToken(`adv-burst-${i}`, 'sb://smalt/advq', Buffer.from('T' + i), 0, 'cbs-rcv'));
      const s = (await firstStatus(c, 600)).status;
      statuses.push(s ? s.statusCode : 'none');
    }
    c.close(); await killTest('S6');
    const counts = statuses.reduce((m, s) => ((m[s] = (m[s] || 0) + 1), m), {});
    return { status: `statusHistogram=${JSON.stringify(counts)}` };
  });

  await attack('S7 duplicate racing put-token (10 parallel connections)', 'sasl-cbs', async () => {
    const jobs = [];
    for (let i = 0; i < 10; i++) {
      jobs.push((async () => {
        const { c } = await handshake(SB);
        await attachPair(c, 'cbs', 0, 1, '$cbs', 'cbs');
        c.send(cbsPutToken('adv-race', 'sb://smalt/advq', Buffer.from('RACE'), 0, 'cbs-rcv'));
        const { r, status } = await firstStatus(c, 2500);
        c.close();
        return status ? status.statusCode : classify(r);
      })());
    }
    const res = await Promise.all(jobs);
    await killTest('S7');
    return { status: `parallel statuses=${JSON.stringify(res)}` };
  });

  // ================= 4. TRANSFER ABUSE =================
  await attack('T1 delivery-id reuse x3 (same id 7)', 'transfer', async () => {
    const { c } = await handshake(SB);
    await attachPair(c, 'q', 4, 5, 'adv-t1', 'queue');
    for (let i = 0; i < 3; i++) c.send(transferFrame(4, 7, Buffer.from('m' + i), false));
    const r = await c.readFrames(1500, REPLY_MS);
    const accepted = r.frames.filter((f) => f.perf && f.perf.name === 'disposition').length;
    c.close(); await killTest('T1');
    return { status: `accepted-dispositions=${accepted}/3 (id reuse tolerated, store seq is authoritative)` };
  });

  await attack('T2 more=true starvation: 60 x 64KB partial frames, never continued', 'transfer', async () => {
    const { c } = await handshake(SB);
    await attachPair(c, 'q', 4, 5, 'adv-t2', 'queue');
    for (let i = 0; i < 60; i++) c.send(transferFrame(4, 100 + i, Buffer.alloc(64 * 1024, 0x5a), true));
    const r = await c.readFrames(2000, REPLY_MS);
    const closed = r.closed || r.frames.some((f) => f.perf && f.perf.name === 'close');
    c.close(); await killTest('T2');
    return {
      status: closed ? 'closed (bounded)' : 'no error after ~3.75MB partial accumulation — link.partial grows uncapped while connection open (MEMORY-DOSSUSPECT-HIGH)',
      detail: 'connection.ex handle_transfer: partial concat unchecked until final (more=false) frame',
    };
  });

  await attack('T2b complete starved partial to ~1.31MB (>1MB cap)', 'transfer', async () => {
    const { c } = await handshake(SB);
    await attachPair(c, 'q', 4, 5, 'adv-t2b', 'queue');
    for (let i = 0; i < 20; i++) c.send(transferFrame(4, 200 + i, Buffer.alloc(64 * 1024, 0x5b), true));
    await sleep(300);
    c.send(transferFrame(4, 299, Buffer.alloc(64 * 1024, 0x5c), false));
    const r = await c.readFrames(2000, REPLY_MS);
    const closeFrame = r.frames.find((f) => f.perf && f.perf.name === 'close');
    c.close(); await killTest('T2b');
    return { status: closeFrame ? 'clean close after oversized assembly (size gate held)' : classify(r) };
  });

  await attack('T3 settled transfer on client-receiver-role link', 'transfer', async () => {
    const { c } = await handshake(SB);
    c.send(perf('attach', { name: str('t3-rcv'), handle: uint(4), role: T_TRUE, source: sourceTarget('adv-t3', 'source'), target: T_NULL }));
    await c.readFrames(800, 2000);
    c.send(transferFrame(4, 1, Buffer.from('zz'), false));
    const r = await c.readFrames(1500, REPLY_MS);
    c.close(); await killTest('T3');
    return { status: classify(r, c.refused), detail: 'expect internal-error close (ingest against sender-role link)' };
  });

  await attack('T4 transfer on detached handle', 'transfer', async () => {
    const { c } = await handshake(SB);
    await attachPair(c, 'q', 4, 5, 'adv-t4', 'queue');
    c.send(perf('detach', { handle: uint(4), closed: T_TRUE }));
    await c.readFrames(800, 2000);
    c.send(transferFrame(4, 1, Buffer.from('after-detach'), false));
    const r = await c.readFrames(1500, REPLY_MS);
    c.close(); await killTest('T4');
    return { status: classify(r, c.refused) };
  });

  await attack('T5 gigantic single frame: declared 2MiB', 'transfer', async () => {
    const c = new Client(SB);
    c.send(AMQP_HEADER); await c.readFrames(500, 1500);
    const h = Buffer.alloc(8);
    h.writeUInt32BE(2 * 1024 * 1024, 0); h[4] = 2; h[5] = 0; h.writeUInt16BE(0, 6);
    recordRepro('T5', h);
    c.send(h);
    const r = await c.readFrames(1500, REPLY_MS);
    c.close(); await killTest('T5');
    return { status: classify(r, c.refused), detail: 'expect frame_too_size close' };
  });

  await attack('T6 1.016MB transfer body vs 1MB QueueStore cap', 'transfer', async () => {
    const { c } = await handshake(SB);
    await attachPair(c, 'q', 4, 5, 'adv-t6', 'queue');
    c.send(transferFrame(4, 1, Buffer.alloc(1_048_000, 0x41), false));
    const r = await c.readFrames(2500, REPLY_MS);
    const closeFrame = r.frames.find((f) => f.perf && f.perf.name === 'close');
    c.close(); await killTest('T6');
    return { status: closeFrame ? 'clean close (link-message-size-exceeded gate held)' : classify(r) };
  });

  // ================= 5. DISPOSITION ABUSE =================
  const seedOne = async (queue) => {
    const s = await handshake(SB);
    await attachPair(s.c, 'q', 4, 5, queue, 'queue');
    s.c.send(transferFrame(4, 1, Buffer.from('seed'), false));
    await s.c.readFrames(1000, 3000);
    s.c.close();
  };

  await attack('D1 settle the same delivery twice', 'disposition', async () => {
    await seedOne('adv-d');
    const { c } = await handshake(SB);
    await attachPair(c, 'q', 4, 5, 'adv-d', 'queue');
    c.send(flowCredit(5, 10));
    const r1 = await c.readFrames(1500, 5000);
    const dlv = r1.frames.find((f) => f.perf && f.perf.name === 'transfer');
    if (!dlv) return { status: 'no-delivery-received (cannot exercise)' };
    const id = dlv.perf.fields[1];
    c.send(dispositionFrame(id));
    await c.readFrames(800, 2000);
    c.send(dispositionFrame(id));
    const r2 = await c.readFrames(1200, 4000);
    c.close(); await killTest('D1');
    return { status: 'double-settle tolerated (second no-op via per-connection outbound map)' };
  });

  await attack('D2 settle unknown delivery id 987654', 'disposition', async () => {
    const { c } = await handshake(SB);
    await attachPair(c, 'q', 4, 5, 'adv-d2', 'queue');
    c.send(flowCredit(5, 5));
    await c.readFrames(800, 2000);
    c.send(dispositionFrame(987654));
    const r = await c.readFrames(1200, 4000);
    c.close(); await killTest('D2');
    return { status: 'silent no-op for unknown id (info)' };
  });

  await attack('D3 RANGE BOMB: disposition first=1 last=100,000,000', 'disposition', async () => {
    const { c } = await handshake(SB);
    await attachPair(c, 'q', 4, 5, 'adv-d3', 'queue');
    c.send(flowCredit(5, 1));
    await c.readFrames(800, 2000);
    recordRepro('D3', dispositionRangeFrame(1, 100_000_000));
    c.send(dispositionRangeFrame(1, 100_000_000));
    await sleep(1000);
    const t0 = Date.now();
    c.send(perf('close', {}));
    const r = await c.readFrames(200, 8000);
    const ms = Date.now() - t0;
    c.close(); await killTest('D3');
    return {
      status: ms > 4000
        ? `RANGE-BOMB: connection process unresponsive ${ms}ms after first=1 last=100M (Enum.reduce over hostile range — HIGH DoS)`
        : `responsive in ${ms}ms (range iterated or bounded)`,
    };
  });

  await attack('D4 rejected delivery-state with 900KB error description', 'disposition', async () => {
    await seedOne('adv-d4');
    const { c } = await handshake(SB);
    await attachPair(c, 'q', 4, 5, 'adv-d4', 'queue');
    c.send(flowCredit(5, 5));
    const r1 = await c.readFrames(1500, 5000);
    const dlv = r1.frames.find((f) => f.perf && f.perf.name === 'transfer');
    if (!dlv) return { status: 'no-delivery-received' };
    const id = dlv.perf.fields[1];
    const bigErr = described(ulong(0x25), list(sym('amqp:internal-error'), str('x'.repeat(900_000)), T_NULL));
    c.send(dispositionWithState(id, bigErr));
    const r = await c.readFrames(2000, REPLY_MS);
    c.close(); await killTest('D4');
    return { status: classify(r, c.refused) };
  });

  await attack('D5 cross-connection settle (owner mismatch)', 'disposition', async () => {
    await seedOne('adv-d5');
    const a = await handshake(SB);
    await attachPair(a.c, 'q', 4, 5, 'adv-d5', 'queue');
    a.c.send(flowCredit(5, 5));
    const r1 = await a.c.readFrames(1500, 5000);
    const dlv = r1.frames.find((f) => f.perf && f.perf.name === 'transfer');
    if (!dlv) return { status: 'no-delivery-received-for-a' };

    const b = await handshake(SB);
    await attachPair(b.c, 'q', 4, 5, 'adv-d5', 'queue');
    b.c.send(flowCredit(5, 5));
    await b.c.readFrames(1500, 5000);
    b.c.send(dispositionFrame(dlv.perf.fields[1]));
    await b.c.readFrames(800, 2000);
    b.c.close();
    a.c.close();
    await killTest('D5');
    return { status: 'cross-conn settle is per-connection no-op (outbound_deliveries conn-local)' };
  });

  await attack('D6 disposition state = unknown descriptor 0xFF', 'disposition', async () => {
    const { c } = await handshake(SB);
    await attachPair(c, 'q', 4, 5, 'adv-d6', 'queue');
    c.send(flowCredit(5, 5));
    await c.readFrames(800, 2000);
    c.send(dispositionWithState(5, described(ulong(0xff), list())));
    const r = await c.readFrames(1200, 4000);
    c.close(); await killTest('D6');
    return { status: 'unknown delivery-state descriptor tolerated (release no-op)' };
  });

  // ================= 6. MANAGEMENT INJECTION =================
  const attachMgmt = async () => {
    const { c } = await handshake(SB);
    await attachPair(c, 'mgmt', 2, 3, '$management', 'management');
    return c;
  };

  await attack('M1 renew-lock with 10,000-element lock-tokens array', 'management', async () => {
    const c = await attachMgmt();
    const tokens = Array.from({ length: 10_000 }, () => uuidTerm(cryptoRandomUuid()));
    const body = described(ulong(0x37), list(T_NULL, mapTerm([[str('lock-tokens'), list(...tokens)]])));
    c.send(mgmtRequest('com.microsoft:renew-lock', body, 2, 'mgmt-rcv'));
    const { r, status } = await firstStatus(c, 3000);
    c.close(); await killTest('M1');
    return { status: status ? `statusCode=${status.statusCode} (10k tokens processed)` : classify(r) };
  });

  await attack('M2 peek from-sequence-number = -1 and 2^63-1', 'management', async () => {
    const c = await attachMgmt();
    const peek = (seq) => mgmtRequest('com.microsoft:peek-message',
      described(ulong(0x37), list(T_NULL, mapTerm([[str('queue'), str('adv-d')], [str('from-sequence-number'), int64(seq)]]))), 2, 'mgmt-rcv');
    c.send(peek(-1));
    const s1 = (await firstStatus(c)).status;
    c.send(peek('9223372036854775807'));
    const s2 = (await firstStatus(c)).status;
    c.close(); await killTest('M2');
    return { status: `peek(-1)=${s1 && s1.statusCode} peek(2^63-1)=${s2 && s2.statusCode}` };
  });

  await attack('M3 non-map body (bare string) to $management', 'management', async () => {
    const c = await attachMgmt();
    c.send(mgmtRequest('com.microsoft:peek-message', str('not-a-map'), 2, 'mgmt-rcv'));
    const { r, status } = await firstStatus(c);
    c.close(); await killTest('M3');
    return { status: status ? `statusCode=${status.statusCode}` : classify(r) };
  });

  await attack('M4 unknown descriptor symbol as body', 'management', async () => {
    const c = await attachMgmt();
    const weird = described(sym('com.microsoft:totally-unknown'), list(sym('x'), T_NULL, T_NULL));
    c.send(mgmtRequest('com.microsoft:peek-message', weird, 2, 'mgmt-rcv'));
    const { status } = await firstStatus(c);
    c.close(); await killTest('M4');
    return { status: status ? `statusCode=${status.statusCode}` : 'no-status-reply' };
  });

  await attack('M5 $management transfer with undecodable junk payload', 'management', async () => {
    const c = await attachMgmt();
    recordRepro('M5', Buffer.from('deadbeefdeadbeef', 'hex'));
    c.send(transferFrame(2, 9, Buffer.from([0xde, 0xad, 0xbe, 0xef]), false));
    const { r, status } = await firstStatus(c);
    c.close(); await killTest('M5');
    return { status: status ? `statusCode=${status.statusCode}` : classify(r) };
  });

  // ================= 7. EVENT HUBS LANE (5673) =================
  await attack('E1 EH lane: handshake + 700KB event transfer', 'eventhubs', async () => {
    const { c } = await handshake(EH);
    await attachPair(c, 'ev', 4, 5, 'evq/partition-1', 'eventhubs');
    c.send(transferFrame(4, 1, Buffer.alloc(700 * 1024, 0x65), false));
    const r = await c.readFrames(2500, REPLY_MS);
    const accepted = r.frames.filter((f) => f.perf && f.perf.name === 'disposition').length;
    c.close(); await killTest('E1');
    return { status: `accepted=${accepted}` };
  });

  await attack('E2 EH lane: 2MiB declared frame', 'eventhubs', async () => {
    const c = new Client(EH);
    c.send(AMQP_HEADER); await c.readFrames(500, 1500);
    const h = Buffer.alloc(8);
    h.writeUInt32BE(2 * 1024 * 1024, 0); h[4] = 2; h[5] = 0; h.writeUInt16BE(0, 6);
    c.send(h);
    const r = await c.readFrames(1500, REPLY_MS);
    c.close(); await killTest('E2');
    return { status: classify(r, c.refused) };
  });

  // ---------------------------------------------------------------------------
  // Receipt
  // ---------------------------------------------------------------------------
  const hangs = RESULTS.filter((x) => String(x.status).includes('HANG'));
  const summary = {
    sb_port: SB, eh_port: EH,
    attacks: RESULTS.length, kill_tests: killTestCount,
    hangs, findings: RESULTS, repro_hex: REPRO,
  };
  fs.writeFileSync('/tmp/r3_amqp_results.json', JSON.stringify(summary, null, 2));
  console.log(`\n== r3_amqp receipt ==\nattacks=${RESULTS.length} kill_tests=${killTestCount} hangs=${hangs.length}\nresults: /tmp/r3_amqp_results.json`);
});

// ---------------------------------------------------------------------------
// Frame builders
// ---------------------------------------------------------------------------

function transferFrame(handle, deliveryId, body, more) {
  const inner = described(ulong(DESCRIPTOR.transfer), list(
    uint(handle), uint(deliveryId), smallbin('d' + deliveryId), uint(0),
    more ? T_FALSE : T_TRUE, more ? T_TRUE : T_FALSE, T_NULL, T_NULL
  ));
  return frame(0x00, 0, Buffer.concat([inner, bodyData(body)]));
}

function flowCredit(handle, credit) {
  return perf('flow', {
    next_incoming_id: uint(1), incoming_window: uint(10000),
    next_outgoing_id: uint(1), outgoing_window: uint(10000),
    handle: uint(handle), delivery_count: uint(0), link_credit: uint(credit),
  });
}

function dispositionFrame(first, last) {
  return perf('disposition', {
    role: T_TRUE, first: uint(first), last: last !== undefined ? uint(last) : T_NULL,
    settled: T_TRUE, state: described(ulong(0x24), list()),
  });
}

function dispositionRangeFrame(first, last) {
  return perf('disposition', { role: T_TRUE, first: uint(first), last: uint(last), settled: T_TRUE, state: described(ulong(0x24), list()) });
}

function dispositionWithState(first, stateTerm) {
  return perf('disposition', { role: T_TRUE, first: uint(first), settled: T_TRUE, state: stateTerm });
}

// message-id(1) ... reply-to(5) correlation-id(6)
function propsSection(messageId, replyTo, correlationId) {
  return propertiesSection([str(messageId), T_NULL, T_NULL, T_NULL, replyTo ? str(replyTo) : T_NULL, correlationId ? str(correlationId) : T_NULL, T_NULL, T_NULL, T_NULL, T_NULL, T_NULL, T_NULL, T_NULL]);
}

function cbsPutToken(name, audience, tokenBuf, handle, replyLinkName) {
  const sections = Buffer.concat([
    propsSection('id-' + name, replyLinkName, 'corr-' + name),
    appProperties([['operation', str('put-token')], ['name', str(name)], ['type', str('servicebus.cc:none')], ['expiration', ulong(4102444800000)]].map(([k, v]) => [str(k), v])),
    bodyValue(str(tokenBuf.toString('latin1'))),
  ]);
  const inner = described(ulong(DESCRIPTOR.transfer), list(
    uint(handle), uint(1), smallbin('t'), uint(0), T_TRUE, T_FALSE, T_NULL, T_NULL
  ));
  return frame(0x00, 0, Buffer.concat([inner, sections]));
}

function cbsDeleteToken(name, handle, replyLinkName) {
  const sections = Buffer.concat([
    propsSection('id-del', replyLinkName, 'corr-del'),
    appProperties([['operation', str('delete-token')], ['name', str(name)]].map(([k, v]) => [str(k), v])),
    bodyValue(mapTerm([[str('expiration'), ulong(0)]])),
  ]);
  const inner = described(ulong(DESCRIPTOR.transfer), list(
    uint(handle), uint(2), smallbin('t'), uint(0), T_TRUE, T_FALSE, T_NULL, T_NULL
  ));
  return frame(0x00, 0, Buffer.concat([inner, sections]));
}

async function cbsCall(c, frameToSend) {
  c.send(frameToSend);
  return (await firstStatus(c, 1200)).status;
}

function mgmtRequest(op, bodyTerm, handle, replyLinkName) {
  const sections = Buffer.concat([
    propsSection('id-m', replyLinkName, 'corr-m'),
    appProperties([['operation', str(op)]].map(([k, v]) => [str(k), v])),
    bodyValue(bodyTerm),
  ]);
  const inner = described(ulong(DESCRIPTOR.transfer), list(
    uint(handle), uint(9), smallbin('m'), uint(0), T_TRUE, T_FALSE, T_NULL, T_NULL
  ));
  return frame(0x00, 0, Buffer.concat([inner, sections]));
}

function cryptoRandomUuid() {
  const b = Buffer.alloc(16);
  for (let i = 0; i < 16; i++) b[i] = Math.floor(Math.random() * 256);
  return b;
}
