// Thin typed wrapper over chrome.storage.local. All keys live in one namespace
// so we can wipe/migrate cleanly in the future.

const KEYS = {
  backendUrl: "nous.backendUrl",
  token: "nous.token",
  label: "nous.label",
  userId: "nous.userId", // surfaced for debugging only; extension never sends it
  axiomToken:   "nous.axiom.token",
  axiomDataset: "nous.axiom.dataset",
  axiomUrl:     "nous.axiom.url",
};

const DEFAULT_BACKEND = "https://nous-backend-k7xtwifwcq-uc.a.run.app";

export async function getBackendUrl() {
  const v = await chrome.storage.local.get(KEYS.backendUrl);
  return (v[KEYS.backendUrl] || DEFAULT_BACKEND).replace(/\/+$/, "");
}

export async function setBackendUrl(url) {
  await chrome.storage.local.set({ [KEYS.backendUrl]: url });
}

export async function getToken() {
  const v = await chrome.storage.local.get(KEYS.token);
  return v[KEYS.token] || null;
}

export async function setToken(token, { label, userId } = {}) {
  const next = { [KEYS.token]: token };
  if (label != null) next[KEYS.label] = label;
  if (userId != null) next[KEYS.userId] = userId;
  await chrome.storage.local.set(next);
}

export async function clearAuth() {
  await chrome.storage.local.remove([KEYS.token, KEYS.label, KEYS.userId]);
}

// ─── Axiom config ──────────────────────────────────────────────────────

export async function getAxiomConfig() {
  const v = await chrome.storage.local.get([KEYS.axiomToken, KEYS.axiomDataset, KEYS.axiomUrl]);
  return {
    token:   v[KEYS.axiomToken]   || null,
    dataset: v[KEYS.axiomDataset] || "nous-extension",
    url:     v[KEYS.axiomUrl]     || "https://api.axiom.co",
  };
}

export async function setAxiomConfig({ token, dataset, url } = {}) {
  const next = {};
  if (token   != null) next[KEYS.axiomToken]   = token;
  if (dataset != null) next[KEYS.axiomDataset] = dataset;
  if (url     != null) next[KEYS.axiomUrl]     = url;
  await chrome.storage.local.set(next);
}

export async function getPairInfo() {
  const v = await chrome.storage.local.get([KEYS.token, KEYS.label, KEYS.userId]);
  return {
    token: v[KEYS.token] || null,
    label: v[KEYS.label] || null,
    userId: v[KEYS.userId] || null,
  };
}

// ─── Diagnostics ──────────────────────────────────────────────────────

const DIAG = {
  lastEvent: "nous.diag.lastEvent",
  lastError: "nous.diag.lastError",
  okCount: "nous.diag.okCount",
  errCount: "nous.diag.errCount",
};

export async function recordSuccess(summary) {
  const cur = await chrome.storage.local.get([DIAG.okCount]);
  await chrome.storage.local.set({
    [DIAG.lastEvent]: { at: new Date().toISOString(), ok: true, ...summary },
    [DIAG.okCount]: (cur[DIAG.okCount] || 0) + 1,
  });
  await appendLog("info", summary.where || "capture", "capture ok", summary);
}

export async function recordError(summary) {
  const cur = await chrome.storage.local.get([DIAG.errCount]);
  await chrome.storage.local.set({
    [DIAG.lastEvent]: { at: new Date().toISOString(), ok: false, ...summary },
    [DIAG.lastError]: { at: new Date().toISOString(), ...summary },
    [DIAG.errCount]: (cur[DIAG.errCount] || 0) + 1,
  });
  await appendLog("error", summary.where || "extension", summary.error || "error", summary);
}

export async function getDiag() {
  const v = await chrome.storage.local.get([
    DIAG.lastEvent, DIAG.lastError, DIAG.okCount, DIAG.errCount,
  ]);
  return {
    lastEvent: v[DIAG.lastEvent] || null,
    lastError: v[DIAG.lastError] || null,
    okCount: v[DIAG.okCount] || 0,
    errCount: v[DIAG.errCount] || 0,
  };
}

// ─── Axiom live shipper (imported lazily to avoid top-level await) ────
// axiomAppend is called from appendLog; import is done inline to keep the
// module loadable even when axiom.js isn't bundled (e.g., unit tests).
let _axiomAppend = null;
async function getAxiomAppend() {
  if (_axiomAppend) return _axiomAppend;
  try {
    const mod = await import("./axiom.js");
    _axiomAppend = mod.axiomAppend;
  } catch { _axiomAppend = () => {}; }
  return _axiomAppend;
}

// ─── Structured log buffer ────────────────────────────────────────────
//
// Rolling JSONL buffer in chrome.storage.local. Capped at MAX_LOG_ENTRIES.
// Each entry: { t, lvl, cat, msg, meta? }
// Export via getLogs() → JSONL string, or use popup "Copy logs" button.
//
// Claude Code access: click "Copy logs" in the extension popup, then
//   paste into a file or ask Claude to analyze the clipboard content.

const LOG_KEY = "nous.logs";
const MAX_LOG_ENTRIES = 1000;

export async function appendLog(level, category, message, meta = {}) {
  const entry = { t: new Date().toISOString(), lvl: level, cat: category, msg: message };
  // Strip internal keys that inflate noise; keep user-facing meta only.
  const cleanMeta = Object.fromEntries(
    Object.entries(meta).filter(([k]) => !["where"].includes(k))
  );
  if (Object.keys(cleanMeta).length > 0) entry.meta = cleanMeta;

  // 1. Local rolling buffer (offline-safe, readable from popup).
  const v = await chrome.storage.local.get([LOG_KEY]);
  const logs = v[LOG_KEY] || [];
  logs.push(entry);
  if (logs.length > MAX_LOG_ENTRIES) logs.splice(0, logs.length - MAX_LOG_ENTRIES);
  await chrome.storage.local.set({ [LOG_KEY]: logs });

  // 2. Axiom live shipper — build Axiom-shaped payload (_time required for indexing).
  const axiomEntry = {
    _time: entry.t,
    level,
    category,
    message,
    platform: "chrome-extension",
    ...cleanMeta,
  };
  const append = await getAxiomAppend();
  append(axiomEntry);
}

/** Returns all buffered log entries as a JSONL string (one JSON object per line). */
export async function getLogs() {
  const v = await chrome.storage.local.get([LOG_KEY]);
  return (v[LOG_KEY] || []).map((e) => JSON.stringify(e)).join("\n");
}

/** Clears the log buffer. */
export async function clearLogs() {
  await chrome.storage.local.remove([LOG_KEY]);
}
