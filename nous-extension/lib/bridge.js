// ─── Local Bridge client ───────────────────────────────────────────────────
//
// A WebSocket connection to the NOUS macOS app on `ws://localhost:9988`.
// This is SEPARATE from the cloud backend (lib/api.js): the cloud backend
// stores captures; the bridge coordinates with a *locally running* NOUS app
// that may itself be recording the same Google Meet.
//
// Two jobs:
//   1. Forward live Meet presence (participants / speaker / room) to the app
//      so the app's own meeting view can show who's in the call.
//   2. Receive `{type:"recording", active, meetingRoom}` from the app. When
//      the app is locally recording a meeting, the extension SUPPRESSES its
//      own cloud Meet capture for that meeting (see background.js dedup logic)
//      to avoid double-capturing the same conversation.
//
// Ported from the standalone "NOUS Meet Bridge" extension's background.js and
// adapted into a reusable module so the NOUS Capture service worker can own
// both the cloud client and the bridge client side by side.
//
// Design notes:
//   - Single connection, reconnect every ~3s, 20s heartbeat to keep the MV3
//     service worker from being torn down mid-call (Chrome 116+ extends SW
//     life while a WS is open + active).
//   - Reconnect when `bridgeToken` changes in chrome.storage.local (popup save).
//   - All connection-state + last-known recording info lives in
//     chrome.storage.session so it survives a brief SW restart and is readable
//     by the popup and (indirectly) the Meet content script.

import { appendLog } from "./storage.js";

const WS_URL = "ws://localhost:9988";
const RECONNECT_MS = 3_000; // delay between reconnect attempts
const HEARTBEAT_MS = 20_000; // ping cadence to keep the SW + socket alive

// Session-storage keys for bridge state. Session storage is wiped when the
// browser closes — correct for ephemeral connection / recording state.
export const BRIDGE_STATE_KEYS = {
  wsState: "nous.bridge.wsState", // 'connecting' | 'connected' | 'disconnected'
  recordingActive: "nous.bridge.recordingActive", // bool — app is recording
  recordingRoom: "nous.bridge.recordingRoom", // string|null — room the app is recording
};

// ── Module-private connection state ─────────────────────────────────────────
let ws = null;
let heartbeatTimer = null;
let reconnectTimer = null;

// Callback invoked whenever the app's recording state changes. The service
// worker wires this up to recompute Meet-capture suppression. Kept as a hook
// (rather than importing background.js) so this module has no circular dep.
let onRecordingChange = null;

/** Register a callback: ({ active, meetingRoom }) => void. */
export function setRecordingChangeHandler(fn) {
  onRecordingChange = fn;
}

async function setBridgeState(changes) {
  await chrome.storage.session.set(changes);
}

/** Current bridge connection + recording snapshot (for popup / suppression). */
export async function getBridgeState() {
  const v = await chrome.storage.session.get([
    BRIDGE_STATE_KEYS.wsState,
    BRIDGE_STATE_KEYS.recordingActive,
    BRIDGE_STATE_KEYS.recordingRoom,
  ]);
  return {
    wsState: v[BRIDGE_STATE_KEYS.wsState] || "disconnected",
    recordingActive: v[BRIDGE_STATE_KEYS.recordingActive] || false,
    recordingRoom: v[BRIDGE_STATE_KEYS.recordingRoom] || null,
  };
}

// ── Connection management ───────────────────────────────────────────────────

/** Open the bridge socket. Safe to call repeatedly — no-ops if already open. */
export async function connectBridge() {
  if (
    ws &&
    (ws.readyState === WebSocket.CONNECTING || ws.readyState === WebSocket.OPEN)
  ) {
    return;
  }

  await setBridgeState({ [BRIDGE_STATE_KEYS.wsState]: "connecting" });

  // Append the local-bridge pairing token (set in the popup, copied from the
  // NOUS app). Optional today (app runs in soft mode) but required once token
  // enforcement is enabled on the app side.
  let url = WS_URL;
  try {
    const { bridgeToken } = await chrome.storage.local.get("bridgeToken");
    if (bridgeToken) url += "?token=" + encodeURIComponent(bridgeToken);
  } catch (_) {
    /* storage read failed — connect without token (soft mode) */
  }

  try {
    ws = new WebSocket(url);
  } catch (_) {
    // Constructor can throw on a malformed URL; reschedule and bail.
    scheduleReconnect();
    return;
  }

  ws.onopen = async () => {
    await setBridgeState({ [BRIDGE_STATE_KEYS.wsState]: "connected" });
    clearTimeout(reconnectTimer);
    startHeartbeat();
    await appendLog("info", "bridge", "bridge connected", { url: WS_URL });
  };

  ws.onmessage = async (ev) => {
    let msg;
    try {
      msg = JSON.parse(ev.data);
    } catch (_) {
      return; // ignore non-JSON frames (e.g. heartbeat acks)
    }
    // App → Extension: recording state change.
    // Shape: { type:"recording", active:bool, meetingRoom?:"<room>" }
    if (msg && msg.type === "recording") {
      const active = !!msg.active;
      const meetingRoom = msg.meetingRoom || null;
      await setBridgeState({
        [BRIDGE_STATE_KEYS.recordingActive]: active,
        [BRIDGE_STATE_KEYS.recordingRoom]: meetingRoom,
      });
      await appendLog("info", "bridge", "app recording state", {
        active,
        meetingRoom,
      });
      if (onRecordingChange) {
        try {
          await onRecordingChange({ active, meetingRoom });
        } catch (_) {
          /* never let a handler error kill the socket */
        }
      }
    }
  };

  ws.onclose = async () => {
    await onDisconnected();
    scheduleReconnect();
  };

  ws.onerror = async () => {
    // onerror is usually followed by onclose; mark disconnected defensively but
    // let onclose schedule the reconnect to avoid duplicate timers.
    await onDisconnected();
  };
}

// When the socket drops we must clear the "app is recording" flag so cloud
// Meet capture RESUMES (the app may have crashed mid-recording). Otherwise a
// dead bridge would silently suppress capture forever.
async function onDisconnected() {
  stopHeartbeat();
  await setBridgeState({
    [BRIDGE_STATE_KEYS.wsState]: "disconnected",
    [BRIDGE_STATE_KEYS.recordingActive]: false,
    [BRIDGE_STATE_KEYS.recordingRoom]: null,
  });
  await appendLog("warning", "bridge", "bridge disconnected — resuming cloud capture");
  if (onRecordingChange) {
    try {
      await onRecordingChange({ active: false, meetingRoom: null });
    } catch (_) {}
  }
}

function scheduleReconnect() {
  clearTimeout(reconnectTimer);
  reconnectTimer = setTimeout(connectBridge, RECONNECT_MS);
}

function startHeartbeat() {
  stopHeartbeat();
  heartbeatTimer = setInterval(() => {
    if (ws && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: "ping" }));
    }
  }, HEARTBEAT_MS);
}

function stopHeartbeat() {
  if (heartbeatTimer) {
    clearInterval(heartbeatTimer);
    heartbeatTimer = null;
  }
}

/** Fire-and-forget send to the app. No-op if the socket isn't open. */
export function sendToBridge(obj) {
  if (ws && ws.readyState === WebSocket.OPEN) {
    try {
      ws.send(JSON.stringify(obj));
    } catch (_) {
      /* socket may have closed between the check and send */
    }
  }
}

// ── Lifecycle wiring ────────────────────────────────────────────────────────

/**
 * Install the storage listener that reconnects when the bridge token changes,
 * then open the initial connection. Call once at service-worker startup.
 */
export function initBridge() {
  chrome.storage.onChanged.addListener((changes, area) => {
    if (area === "local" && changes.bridgeToken) {
      // Token changed (popup save / clear): drop the old socket and reconnect
      // with the new token appended.
      try {
        if (ws) ws.close();
      } catch (_) {}
      connectBridge();
    }
  });
  connectBridge();
}
