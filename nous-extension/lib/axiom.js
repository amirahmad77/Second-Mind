// Axiom log shipper for Chrome extension.
//
// Config stored in chrome.storage.local:
//   nous.axiom.token   — ingest/personal token from axiom.co
//   nous.axiom.dataset — target dataset (default: "nous-extension")
//   nous.axiom.url     — base URL (default: "https://api.axiom.co")
//
// Behaviour:
//   • Buffers entries in memory (max 200) in the service worker.
//   • Flushes every 15 seconds or when 30 entries accumulate.
//   • Fire-and-forget — never throws, never delays callers.
//   • Disabled when token is not set.
//
// Setup: click the NOUS extension icon → paste your Axiom token → Save.
//
// Claude Code: once axiom-mcp is in settings.json, ask Claude to query
//   dataset="nous-extension" to see all extension logs.

import { getAxiomConfig } from "./storage.js";

const AXIOM_BASE = "https://api.axiom.co";
const FLUSH_MS   = 15_000;
const AUTO_FLUSH = 30;
const MAX_BUF    = 200;

let buffer = [];
let flushTimer = null;

function scheduleFlush() {
  if (flushTimer) return;
  flushTimer = setTimeout(() => {
    flushTimer = null;
    flush().catch(() => {});
  }, FLUSH_MS);
}

export function axiomAppend(entry) {
  // Called from appendLog in storage.js — always async, never awaited by caller.
  scheduleFlush();
  buffer.push(entry);
  if (buffer.length >= AUTO_FLUSH) {
    clearTimeout(flushTimer); flushTimer = null;
    flush().catch(() => {});
  }
}

async function flush() {
  if (buffer.length === 0) return;
  const cfg = await getAxiomConfig();
  if (!cfg.token) return; // not configured

  const batch = buffer.splice(0, buffer.length > MAX_BUF ? MAX_BUF : buffer.length);
  const dataset = cfg.dataset || "nous-extension";
  const url = `${cfg.url || AXIOM_BASE}/v1/datasets/${dataset}/ingest`;

  try {
    const res = await fetch(url, {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${cfg.token}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(batch),
    });
    if (!res.ok) {
      console.warn(`[nous-axiom] flush HTTP ${res.status}`);
      // Put batch back on failure so it retries next interval.
      buffer.unshift(...batch);
    }
  } catch (e) {
    console.warn("[nous-axiom] flush error", e.message);
    buffer.unshift(...batch);
  }
}
