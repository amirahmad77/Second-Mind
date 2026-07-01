import { api } from "../lib/api.js";
import {
  clearAuth,
  clearLogs,
  getAxiomConfig,
  getBackendUrl,
  getDiag,
  getLogs,
  getPairInfo,
  setAxiomConfig,
  setBackendUrl,
  setToken,
} from "../lib/storage.js";

const $ = (id) => document.getElementById(id);

async function render() {
  const { token, label, userId } = await getPairInfo();
  const backend = await getBackendUrl();
  $("backend").value = backend;
  const axiom = await getAxiomConfig();
  $("axiom-token").value = axiom.token || "";
  $("axiom-dataset").value = axiom.dataset || "nous-extension";
  if (token) {
    $("headline").textContent = "NOUS paired";
    $("pair-view").hidden = true;
    $("ok-view").hidden = false;
    $("who").textContent = label || userId?.slice(0, 8) || "this browser";
    await renderDiag();
  } else {
    $("headline").textContent = "Pair this browser";
    $("pair-view").hidden = false;
    $("ok-view").hidden = true;
  }
}

function ago(iso) {
  const s = Math.max(0, (Date.now() - new Date(iso).getTime()) / 1000);
  if (s < 60) return `${Math.round(s)}s ago`;
  if (s < 3600) return `${Math.round(s / 60)}m ago`;
  if (s < 86400) return `${Math.round(s / 3600)}h ago`;
  return `${Math.round(s / 86400)}d ago`;
}

async function renderDiag() {
  const d = await getDiag();
  $("ok-count").textContent = d.okCount;
  $("err-count").textContent = d.errCount;

  if (d.lastEvent) {
    const e = d.lastEvent;
    const tag = e.ok
      ? `${e.kind || "?"} ${e.appended ? "(appended)" : ""}${e.refined ? " · refined" : ""}`
      : `${e.where || "?"}: ${e.error || "?"}`;
    $("last-event").textContent = `${ago(e.at)} — ${tag}`;
    $("last-event").style.color = e.ok ? "var(--phos)" : "var(--danger)";
  } else {
    $("last-event").textContent = "no captures yet";
  }

  if (d.lastError) {
    $("last-error-label").hidden = false;
    $("last-error").hidden = false;
    $("last-error").textContent =
      `${ago(d.lastError.at)} — ${d.lastError.where || "?"}: ${d.lastError.error || "?"}`;
  }
}

async function healthCheck() {
  const status = $("diag-status");
  status.className = "status";
  status.textContent = "checking…";
  const base = (await getBackendUrl()).replace(/\/+$/, "");
  try {
    const t0 = performance.now();
    const r = await fetch(`${base}/health`);
    const ms = Math.round(performance.now() - t0);
    if (!r.ok) throw new Error(`HTTP ${r.status}`);
    status.className = "status ok";
    status.textContent = `backend up · ${ms}ms`;
  } catch (e) {
    status.className = "status err";
    status.textContent = `backend unreachable: ${e.message}`;
  }
}

async function sendTestCapture() {
  const status = $("diag-status");
  status.className = "status";
  status.textContent = "sending test capture…";
  try {
    const res = await api.capture({
      source: {
        kind: "web",
        url: "https://nous.test/diagnostic",
        domain: "nous.test",
        title: "NOUS extension diagnostic",
      },
      text: `Diagnostic capture from extension at ${new Date().toISOString()}.`,
      client_nonce: `diag-${Date.now()}`,
    });
    status.className = "status ok";
    status.textContent = `ok · atom ${String(res.atom_id).slice(0, 8)} · refined=${res.refined}`;
    await renderDiag();
  } catch (e) {
    status.className = "status err";
    status.textContent = String(e.message || e);
    await renderDiag();
  }
}

// ─── Local bridge ──────────────────────────────────────────────────────
// The bridge connection + the app's recording state are owned by the service
// worker and mirrored into chrome.storage.session (see lib/bridge.js). We fetch
// once on open and live-update via a session-storage change listener.

async function renderBridge() {
  let state;
  try {
    state = await chrome.runtime.sendMessage({ type: "NOUS_GET_BRIDGE_STATE" });
  } catch (_) {
    state = null;
  }
  const statusEl = $("bridge-status");
  const recEl = $("bridge-rec");
  if (!statusEl) return;

  const ws = state?.wsState || "disconnected";
  statusEl.textContent = ws;
  // Reuse the diagnostic color vars: phosphor = connected, muted = otherwise.
  statusEl.style.color =
    ws === "connected" ? "var(--phos)" : ws === "connecting" ? "var(--muted)" : "var(--danger)";

  // "Local recording — cloud capture paused" indicator.
  if (state?.recordingActive) {
    recEl.hidden = false;
    const room = state.recordingRoom ? ` (${state.recordingRoom})` : "";
    recEl.textContent = `● local recording${room} — cloud capture paused`;
    recEl.style.color = "var(--danger)";
  } else {
    recEl.hidden = true;
  }
}

async function loadBridgeToken() {
  const input = $("bridge-token");
  if (!input) return;
  const { bridgeToken } = await chrome.storage.local.get("bridgeToken");
  if (bridgeToken) input.value = bridgeToken;
}

async function saveBridgeToken() {
  const v = ($("bridge-token").value || "").trim();
  // Writing bridgeToken triggers background.js to reconnect with the new token.
  await chrome.storage.local.set({ bridgeToken: v });
  const s = $("bridge-token-status");
  s.className = "status ok";
  s.textContent = v ? "bridge token saved · reconnecting" : "bridge token cleared";
  setTimeout(() => { s.textContent = ""; }, 2500);
}

async function pair() {
  const code = $("code").value.trim();
  const label = $("label").value.trim() || null;
  const status = $("pair-status");
  status.className = "status";
  if (!/^\d{6}$/.test(code)) {
    status.className = "status err";
    status.textContent = "Enter the 6-digit code from the NOUS iOS app.";
    return;
  }
  status.textContent = "Pairing…";
  try {
    const res = await api.pairComplete(code, label);
    await setToken(res.token, { label, userId: res.user_id });
    status.className = "status ok";
    status.textContent = "Paired.";
    render();
  } catch (e) {
    status.className = "status err";
    status.textContent = String(e.message || e);
  }
}

async function unpair() {
  await clearAuth();
  render();
}

async function copyLogs() {
  const status = $("diag-status");
  try {
    const logs = await getLogs();
    if (!logs) { status.className = "status"; status.textContent = "no logs yet"; return; }
    await navigator.clipboard.writeText(logs);
    status.className = "status ok";
    status.textContent = `copied ${logs.split("\n").filter(Boolean).length} log lines`;
  } catch (e) {
    status.className = "status err";
    status.textContent = `copy failed: ${e.message}`;
  }
}

async function openLogsTab() {
  const logs = await getLogs();
  const lines = logs.split("\n").filter(Boolean);
  const html = `<!doctype html><html><head><meta charset=utf-8><title>NOUS logs</title>
<style>body{background:#0e0e10;color:#c8ffd7;font:12px/1.6 ui-monospace,monospace;padding:16px}
pre{margin:0;white-space:pre-wrap;word-break:break-all}
.err{color:#ff7a7a}.warn{color:#ffca7a}.info{color:#c8ffd7}.debug{color:#8a8a8f}</style></head>
<body><pre id=out></pre><script>
const lines=${JSON.stringify(lines)};
const out=document.getElementById('out');
out.innerHTML=lines.map(l=>{try{const e=JSON.parse(l);const cls=e.lvl==='error'?'err':e.lvl==='warning'?'warn':e.lvl==='debug'?'debug':'info';return\`<span class="\${cls}">\${e.t} [\${e.cat}] \${e.msg}\${e.meta?' '+JSON.stringify(e.meta):''}</span>\`;}catch{return l;}}).join('\\n');
</script></body></html>`;
  const blob = new Blob([html], { type: "text/html" });
  const url = URL.createObjectURL(blob);
  chrome.tabs.create({ url });
}

document.addEventListener("DOMContentLoaded", () => {
  render();
  loadBridgeToken();
  renderBridge();
  $("bridge-save")?.addEventListener("click", saveBridgeToken);
  $("pair-btn").addEventListener("click", pair);
  $("code").addEventListener("keydown", (e) => { if (e.key === "Enter") pair(); });
  $("unpair").addEventListener("click", unpair);
  $("backend").addEventListener("change", async (e) => {
    await setBackendUrl(e.target.value.trim());
  });
  $("health")?.addEventListener("click", healthCheck);
  $("capture-test")?.addEventListener("click", sendTestCapture);
  $("copy-logs")?.addEventListener("click", copyLogs);
  $("open-logs")?.addEventListener("click", openLogsTab);
  $("clear-logs")?.addEventListener("click", async () => {
    await clearLogs();
    const s = $("diag-status");
    s.className = "status ok";
    s.textContent = "logs cleared";
  });
  $("axiom-save")?.addEventListener("click", async () => {
    const token   = $("axiom-token").value.trim();
    const dataset = $("axiom-dataset").value.trim() || "nous-extension";
    await setAxiomConfig({ token: token || null, dataset });
    const s = $("diag-status");
    s.className = "status ok";
    s.textContent = token ? "Axiom configured ✓" : "Axiom token cleared";
  });
  // Live-refresh diag (local) + bridge status (session) while popup is open.
  chrome.storage.onChanged.addListener((changes, area) => {
    if (area === "local") renderDiag().catch(() => {});
    // Bridge connection + recording state live in session storage; re-render
    // the bridge UI whenever any of those keys change.
    if (area === "session") {
      const touched = Object.keys(changes).some((k) => k.startsWith("nous.bridge."));
      if (touched) renderBridge().catch(() => {});
    }
  });
});
