// NOUS backend REST client. All methods auto-inject the extension bearer token.

import { getBackendUrl, getToken } from "./storage.js";

// Default timeout for regular calls. STT ships large audio blobs → longer budget.
const DEFAULT_TIMEOUT_MS = 15_000;
const STT_TIMEOUT_MS     = 90_000;

async function call(path, { method = "POST", body, auth = true, timeoutMs = DEFAULT_TIMEOUT_MS } = {}) {
  const base = await getBackendUrl();
  const headers = { "Content-Type": "application/json" };
  if (auth) {
    const token = await getToken();
    if (!token) throw new Error("not paired");
    headers["Authorization"] = `Bearer ${token}`;
  }

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  let res;
  try {
    res = await fetch(`${base}${path}`, {
      method,
      headers,
      body: body == null ? undefined : JSON.stringify(body),
      signal: controller.signal,
    });
  } catch (e) {
    if (e.name === "AbortError") throw new Error(`${method} ${path} timed out after ${timeoutMs}ms`);
    throw e;
  } finally {
    clearTimeout(timer);
  }

  const txt = await res.text();
  if (!res.ok) {
    throw new Error(`${method} ${path} failed: ${res.status} ${txt.slice(0, 200)}`);
  }
  return txt ? JSON.parse(txt) : null;
}

export const api = {
  pairComplete: (code, label) =>
    call("/v1/pair/complete", { body: { code, label }, auth: false }),
  capture: (payload) => call("/v1/capture", { body: payload }),
  stt: (payload) => call("/v1/stt", { body: payload, timeoutMs: STT_TIMEOUT_MS }),
};
