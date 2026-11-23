// glinlandui page store — IndexedDB, and the only place a persisted byte lives.
//
// ## Why this file exists at all
//
// The toolkit keeps an app's settings in `src/core/storage.zig` — a bounded
// document with a version and a migration — and the wasm module imports
// NOTHING (`WebAssembly.Module.imports().length === 0`, asserted by `shim.js`
// and `smoke.mjs`). IndexedDB is page-only and asynchronous, so it cannot live
// on the Zig side of that boundary. This module is the other half: it opens the
// database, reads one value on boot and writes one value when the app says its
// document changed.
//
// ## What it deliberately does NOT do
//
// No decisions about the payload. The key names, the version, the migration and
// what a setting means are all in Zig, where a unit test can reach them. This
// file moves strings and nothing else — the same division `gpu.js` keeps for the
// GPU contexts and `shim.js` keeps for the event loop.
//
// ## Absent is a supported state
//
// `indexedDB` is undefined in Node (where `smoke.mjs` runs), in an insecure
// context, and in some private-browsing modes. Every method here resolves rather
// than throwing, and `available` says which case you are in, so the page can skip
// the whole dance without a `try`/`catch` at the call site. An app that loses its
// settings is a disappointment; a page that fails to boot because a database was
// missing is a bug.

/**
 * Open (or create) the object store an app's document lives in.
 *
 * @param {object} [options]
 * @param {string} [options.name] database name; one per origin, not per app.
 * @param {string} [options.storeName] object store name inside it.
 * @returns {{ available: boolean, name: string, open: () => Promise<IDBDatabase|null>, load: (key: string) => Promise<string|null>, save: (key: string, value: string) => Promise<boolean> }}
 */
export function createStore({ name = "glinlandui", storeName = "state" } = {}) {
  const available = typeof indexedDB !== "undefined" && indexedDB !== null;
  /** @type {IDBDatabase|null} */
  let db = null;
  /** @type {Promise<IDBDatabase|null>|null} */
  let opening = null;

  function open() {
    if (!available) return Promise.resolve(null);
    if (db) return Promise.resolve(db);
    // One open per page: two concurrent `indexedDB.open` calls on the same
    // version race, and the loser gets a `blocked` event that never resolves.
    if (opening) return opening;
    opening = new Promise((resolve) => {
      let request;
      try {
        request = indexedDB.open(name, 1);
      } catch {
        resolve(null);
        return;
      }
      request.onupgradeneeded = () => {
        const idb = request.result;
        if (!idb.objectStoreNames.contains(storeName)) idb.createObjectStore(storeName);
      };
      request.onsuccess = () => {
        db = request.result;
        // A second tab upgrading the schema closes this connection; dropping it
        // means the next call re-opens instead of throwing `InvalidStateError`.
        db.onclose = () => {
          db = null;
          opening = null;
        };
        resolve(db);
      };
      // A failure is not permanent: `opening` is cleared so the next call tries
      // again, because `onblocked` in particular resolves only until the other
      // tab lets go — caching that `null` would disable persistence for the life
      // of the page.
      request.onerror = () => {
        opening = null;
        resolve(null);
      };
      request.onblocked = () => {
        opening = null;
        resolve(null);
      };
    });
    return opening;
  }

  /**
   * The stored document for `key`, or null when there is none.
   *
   * @param {string} key
   * @returns {Promise<string|null>}
   */
  async function load(key) {
    const idb = await open();
    if (!idb) return null;
    return new Promise((resolve) => {
      let tx;
      try {
        tx = idb.transaction(storeName, "readonly");
      } catch {
        resolve(null);
        return;
      }
      const request = tx.objectStore(storeName).get(key);
      request.onsuccess = () => resolve(typeof request.result === "string" ? request.result : null);
      request.onerror = () => resolve(null);
      tx.onabort = () => resolve(null);
    });
  }

  /**
   * Persist `value` under `key`. True once the transaction committed.
   *
   * @param {string} key
   * @param {string} value
   * @returns {Promise<boolean>}
   */
  async function save(key, value) {
    const idb = await open();
    if (!idb) return false;
    return new Promise((resolve) => {
      let tx;
      try {
        tx = idb.transaction(storeName, "readwrite");
        tx.objectStore(storeName).put(value, key);
      } catch {
        // `transaction` throws on a closed connection and `put` on a store that
        // another tab's upgrade removed; both are a failed write, not a crash.
        resolve(false);
        return;
      }
      tx.oncomplete = () => resolve(true);
      tx.onerror = () => resolve(false);
      tx.onabort = () => resolve(false);
    });
  }

  return { available, name, open, load, save };
}
