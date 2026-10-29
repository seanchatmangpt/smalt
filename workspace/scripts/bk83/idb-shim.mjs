// BK-83 minimal in-memory IndexedDB shim (BK-92-F1 fix). Implements only the
// API surface journal-sync.ts uses. Real state over real Maps: real puts,
// real deletes, real cursor writes; assertions run on final court state.
//
// BK-92-F1 root cause (typed in receipts/bk92-receipt-sot.md): the old Tx
// completed the first time `pending` hit 0. journal-sync's transactions issue
// a request, `await` its result, THEN schedule another op on the same tx
// (e.g. _appendLocal: openCursor -> await -> put -> txDone). Between the two
// ops `pending` is transiently 0, so `maybeComplete` set completed=true and
// fired oncomplete early; the second op's completion could never re-fire it
// and `await txDone(tx)` hung forever (exit-13 unsettled top-level await).
//
// Deterministic fix: count scheduled ops per transaction (pending = ops
// scheduled minus ops settled) and only complete the tx from a MACROTASK
// (setTimeout 0) check scheduled when pending last hit 0. Every microtask
// continuation (including the `await req(...)` resumption that schedules the
// tx's next op) drains before the check runs, so completion fires exactly
// once, after the final op settles. Errors propagate: a failed request marks
// tx.error and fires onabort (txDone rejects) instead of oncomplete.
export function installIdbShim() {
  const dbs = new Map();

  class Request {
    constructor(tx, exec) {
      this.onsuccess = null;
      this.onerror = null;
      this.result = undefined;
      this.error = null;
      const done = (result, error) => {
        queueMicrotask(() => {
          // Handlers may schedule further ops on this tx synchronously; their
          // pending increment lands before our decrement, so pending only
          // reaches 0 when no chained op is outstanding.
          if (error !== undefined) {
            this.error = error;
            if (this.onerror) this.onerror({ target: this });
            if (tx) tx.fail(error);
            return;
          }
          this.result = result;
          if (this.onsuccess) this.onsuccess({ target: this });
          if (tx) tx.settle();
        });
      };
      exec(done);
    }
  }

  class Store {
    constructor(tx, rows, keyPath) {
      this.tx = tx;
      this.rows = rows;
      this.keyPath = keyPath;
    }
    put(value, key) {
      this.tx.schedule();
      const rows = this.rows;
      const keyPath = this.keyPath;
      return new Request(this.tx, (done) => {
        queueMicrotask(() => {
          rows.set(key !== undefined ? key : value[keyPath], value);
          done(value);
        });
      });
    }
    get(key) {
      this.tx.schedule();
      const rows = this.rows;
      return new Request(this.tx, (done) => {
        queueMicrotask(() => done(rows.get(key)));
      });
    }
    getAll() {
      this.tx.schedule();
      const rows = this.rows;
      return new Request(this.tx, (done) => {
        queueMicrotask(() => done([...rows.values()]));
      });
    }
    delete(key) {
      this.tx.schedule();
      const rows = this.rows;
      return new Request(this.tx, (done) => {
        queueMicrotask(() => {
          rows.delete(key);
          done(undefined);
        });
      });
    }
    openCursor(range, dir) {
      this.tx.schedule();
      const rows = this.rows;
      return new Request(this.tx, (done) => {
        queueMicrotask(() => {
          if (rows.size === 0) {
            done(null);
            return;
          }
          const keys = [...rows.keys()].sort((a, b) => b - a);
          const k = dir === "prev" ? keys[0] : keys[keys.length - 1];
          done({ key: k, value: rows.get(k) });
        });
      });
    }
  }

  class Tx {
    constructor(stores) {
      this.pending = 0; // scheduled-but-unsettled op count
      this.completed = false;
      this.aborted = false;
      this.error = null;
      this.oncomplete = null;
      this.onerror = null;
      this.onabort = null;
      this.stores = stores;
      this._checkScheduled = false;
    }
    objectStore(name) {
      if (this.completed || this.aborted) {
        throw new Error("IDB-SHIM transaction already finished");
      }
      const meta = this.stores.get(name);
      if (!meta) throw new Error("IDB-SHIM no such store: " + name);
      return new Store(this, meta.rows, meta.keyPath);
    }
    schedule() {
      this.pending += 1;
      this._checkScheduled = false; // new work: the drain check must re-arm
    }
    settle() {
      this.pending -= 1;
      this._maybeArmCheck();
    }
    fail(error) {
      if (this.completed || this.aborted) return;
      this.aborted = true;
      this.error = error;
      queueMicrotask(() => {
        if (this.onabort) this.onabort({ target: this });
        if (this.onerror) this.onerror({ target: this });
      });
    }
    _maybeArmCheck() {
      if (this.pending !== 0 || this.completed || this.aborted) return;
      if (this._checkScheduled) return;
      this._checkScheduled = true;
      // Macrotask: all microtask continuations (the awaited-request
      // resumptions that schedule this tx's remaining ops) drain first.
      setTimeout(() => {
        this._checkScheduled = false;
        if (this.pending === 0 && !this.completed && !this.aborted) {
          this.completed = true;
          if (this.oncomplete) this.oncomplete({ target: this });
        }
      }, 0);
    }
  }

  class Db {
    constructor(name) {
      this.name = name;
      this.stores = new Map();
      this.objectStoreNames = { contains: (n) => this.stores.has(n) };
    }
    createObjectStore(name, opts) {
      this.stores.set(name, { rows: new Map(), keyPath: opts ? opts.keyPath : undefined });
    }
    transaction(names) {
      const storeMap = new Map();
      for (const n of names) storeMap.set(n, this.stores.get(n));
      return new Tx(storeMap);
    }
  }

  globalThis.indexedDB = {
    open(name, _version) {
      const req = { onupgradeneeded: null, onsuccess: null, onerror: null, result: undefined };
      queueMicrotask(() => {
        let db = dbs.get(name);
        let fresh = false;
        if (!db) {
          db = new Db(name);
          dbs.set(name, db);
          fresh = true;
        }
        req.result = db;
        try {
          if (fresh && req.onupgradeneeded) req.onupgradeneeded({ target: req });
        } catch (e) {
          if (req.onerror) req.onerror({ target: req, error: e });
          return;
        }
        if (req.onsuccess) req.onsuccess({ target: req });
      });
      return req;
    },
  };
}
