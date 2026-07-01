// Service worker entrypoint.
//   - Registers the context menu + shortcut for web capture
//   - Brokers capture requests from content scripts
//   - Manages the offscreen document for Meet tab-audio recording
//   - Maintains the LOCAL BRIDGE connection to the NOUS macOS app and
//     coordinates dedup: when the app is locally recording a Meet, the
//     extension suppresses its own cloud Meet capture for that meeting.

import { api } from "./lib/api.js";
import { getToken, recordError, recordSuccess, appendLog } from "./lib/storage.js";
import {
  initBridge,
  sendToBridge,
  getBridgeState,
  setRecordingChangeHandler,
} from "./lib/bridge.js";

// ─── Meet capture suppression (dedup with local app) ─────────────────────
//
// The macOS app reports `{recording, active, meetingRoom}` over the bridge.
// When it is locally recording a meeting, the extension must NOT also push
// that meeting's captions / tab-audio to the cloud — otherwise the same
// conversation is captured twice. We track the "suppressed room" in
// chrome.storage.session so it survives a brief SW restart and is readable
// by the popup, then broadcast a flag to every Meet content script.
//
// Matching rule (per the integration spec):
//   - active === false  → suppress nothing (resume capture everywhere)
//   - active === true && meetingRoom set → suppress only that room
//   - active === true && meetingRoom empty → app didn't say which room, so
//     treat it as "recording the active meeting" → suppress ALL open Meet
//     tabs (conservative: better to under-capture than double-capture).
//
// Web-clip / link / page capture is UNAFFECTED — only Meet capture is gated.

const SUPPRESS_KEY = {
  active: "nous.suppress.active",       // bool — app is recording something
  room: "nous.suppress.room",           // string|null — specific room, or null = all meets
};

// Normalize a Meet room id for comparison: lowercase, strip query/hash, and
// ignore the path slashes so "abc-defg-hij" matches regardless of formatting.
function normalizeRoom(room) {
  if (!room) return null;
  return String(room).toLowerCase().replace(/^\/+/, "").split(/[?#]/)[0].trim() || null;
}

// Decide, for a given Meet room, whether cloud capture should be suppressed.
function shouldSuppressRoom(suppressActive, suppressRoom, room) {
  if (!suppressActive) return false;        // app not recording → never suppress
  if (!suppressRoom) return true;           // app recording but unspecified room → suppress all
  return normalizeRoom(suppressRoom) === normalizeRoom(room);
}

// Called by the bridge whenever the app's recording state flips. Persists the
// suppression decision and pushes the per-room flag to each Meet tab.
async function onAppRecordingChange({ active, meetingRoom }) {
  const room = normalizeRoom(meetingRoom);
  await chrome.storage.session.set({
    [SUPPRESS_KEY.active]: !!active,
    [SUPPRESS_KEY.room]: room,
  });
  await appendLog("info", "meet", "suppression updated", {
    appRecording: !!active,
    room: room || "(all)",
  });
  await broadcastSuppression(!!active, room);
}

// Push the current suppression decision to every open Meet tab. Each tab
// resolves its OWN room → gets a tab-specific boolean so two simultaneous
// meetings are handled independently.
async function broadcastSuppression(active, room) {
  const tabs = await chrome.tabs.query({ url: "https://meet.google.com/*" });
  for (const t of tabs) {
    if (!t.id) continue;
    // We don't know each tab's room here without messaging it, so we let the
    // content script compare against its own MEET_ID. Send the raw decision;
    // the content script applies shouldSuppress logic locally too. To keep the
    // SW authoritative we still send a computed flag using the tab URL when we
    // can parse a room from it.
    let suppressForTab = active;
    try {
      const url = new URL(t.url || "");
      const tabRoom = normalizeRoom(url.pathname);
      suppressForTab = shouldSuppressRoom(active, room, tabRoom);
    } catch (_) {
      /* unparseable URL — fall back to global `active` */
    }
    chrome.tabs
      .sendMessage(t.id, { type: "NOUS_MEET_SUPPRESS", suppress: suppressForTab, room })
      .catch(() => {});
  }
}

// Resolve whether a SPECIFIC room is currently suppressed (used when a Meet
// content script boots and asks for its initial state).
async function isRoomSuppressed(room) {
  const v = await chrome.storage.session.get([SUPPRESS_KEY.active, SUPPRESS_KEY.room]);
  return shouldSuppressRoom(v[SUPPRESS_KEY.active] || false, v[SUPPRESS_KEY.room] || null, room);
}

// ─── Bridge bootstrap ─────────────────────────────────────────────────────
// Open the local bridge socket and route recording-state changes into the
// suppression logic above. Runs at top level so the SW connects on wake.
setRecordingChangeHandler(onAppRecordingChange);
initBridge();

// ─── Install / menu ─────────────────────────────────────────────────────

chrome.runtime.onInstalled.addListener((details) => {
  chrome.contextMenus.create({
    id: "nous-capture-selection",
    title: "Save selection to NOUS",
    contexts: ["selection"],
  });
  chrome.contextMenus.create({
    id: "nous-capture-link",
    title: "Save link to NOUS",
    contexts: ["link", "page"],
  });
  appendLog("info", "extension", `installed reason=${details.reason}`, { version: chrome.runtime.getManifest().version }).catch(() => {});
});

chrome.contextMenus.onClicked.addListener((info, tab) => {
  if (!tab?.id) return;
  if (info.menuItemId === "nous-capture-selection") {
    triggerSelectionCapture(tab.id);
  } else if (info.menuItemId === "nous-capture-link") {
    triggerLinkCapture(tab.id, info.linkUrl || info.pageUrl);
  }
});

chrome.commands.onCommand.addListener(async (command) => {
  if (command !== "capture-selection") return;
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (tab?.id) triggerSelectionCapture(tab.id);
});

async function triggerSelectionCapture(tabId) {
  // Preferred path: content script owns the selection & page metadata.
  try {
    await chrome.tabs.sendMessage(tabId, { type: "NOUS_CAPTURE_SELECTION" });
    return;
  } catch (_) {
    // Fall through — content script not injected (chrome://, PDF viewer,
    // view-source, CSP-stripped page, or fresh tab before idle).
  }
  // Fallback: inject a one-shot grabber via chrome.scripting, capture here.
  try {
    const [{ result } = {}] = await chrome.scripting.executeScript({
      target: { tabId },
      func: () => {
        const sel = (window.getSelection?.().toString() || "").trim();
        return {
          text: sel,
          url: location.href,
          title: document.title,
          domain: location.hostname,
        };
      },
    });
    if (!result) throw new Error("injection returned nothing");
    const text = result.text || `[page] ${result.title || result.url}`;
    await captureDirect({
      source: { kind: "web", url: result.url, domain: result.domain, title: result.title },
      text,
      client_nonce: `trig-${Date.now()}`,
    });
  } catch (e) {
    await recordError({
      where: "trigger",
      error: `can't capture on this page (${String(e?.message || e)})`,
    });
    await badgeFlash("?", "#ff7a7a", 3000);
  }
}

async function triggerLinkCapture(tabId, url) {
  try {
    await chrome.tabs.sendMessage(tabId, { type: "NOUS_CAPTURE_LINK", url });
    return;
  } catch (_) { /* fall through to direct */ }
  try {
    await captureDirect({
      source: { kind: "web", url, domain: new URL(url).hostname, title: url },
      text: `[link] ${url}`,
      client_nonce: `trig-link-${Date.now()}`,
    });
  } catch (e) {
    await recordError({ where: "trigger-link", error: String(e?.message || e) });
    await badgeFlash("?", "#ff7a7a", 3000);
  }
}

/// Capture directly from the service worker — bypasses content script so the
/// shortcut / context menu works on pages without an injected script.
/// Retries up to 3 times with exponential backoff on transient failures.
async function captureDirect(payload) {
  const token = await getToken();
  if (!token) {
    await recordError({ where: "capture", error: "not paired" });
    await badgeFlash("?", "#ff7a7a", 3000);
    return;
  }
  const RETRIES = 3;
  let lastErr;
  for (let attempt = 0; attempt < RETRIES; attempt++) {
    if (attempt > 0) await new Promise((r) => setTimeout(r, 800 * 2 ** (attempt - 1)));
    try {
      const res = await api.capture(payload);
      await recordSuccess({
        where: "capture",
        kind: payload.source.kind,
        atomId: res.atom_id,
        appended: res.appended,
        refined: res.refined,
      });
      await badgeFlash(res.appended ? "+" : "✓", "#b8ff5e", 2500);
      return;
    } catch (e) {
      lastErr = e;
      // Don't retry 4xx — those are permanent errors (auth, validation).
      const status = parseInt(String(e?.message || "").match(/failed: (\d{3})/)?.[1]);
      if (status >= 400 && status < 500) break;
    }
  }
  await recordError({ where: "capture", error: String(lastErr?.message || lastErr) });
  await badgeFlash("!", "#ff7a7a", 4000);
}

// ─── Message broker ─────────────────────────────────────────────────────

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  (async () => {
    try {
      if (msg.type === "NOUS_CAPTURE") {
        const token = await getToken();
        if (!token) {
          await recordError({ where: "capture", error: "not paired" });
          await badgeFlash("?", "#ff7a7a", 3000);
          sendResponse({ ok: false, error: "not paired" });
          return;
        }
        try {
          // Retry up to 3 times; don't retry 4xx (permanent errors).
          const RETRIES = 3;
          let res, lastErr;
          for (let attempt = 0; attempt < RETRIES; attempt++) {
            if (attempt > 0) await new Promise((r) => setTimeout(r, 800 * 2 ** (attempt - 1)));
            try {
              res = await api.capture(msg.payload);
              break;
            } catch (e) {
              lastErr = e;
              const status = parseInt(String(e?.message || "").match(/failed: (\d{3})/)?.[1]);
              if (status >= 400 && status < 500) throw e;
            }
          }
          if (!res) throw lastErr;
          await recordSuccess({
            where: "capture",
            kind: msg.payload.source.kind,
            atomId: res.atom_id,
            appended: res.appended,
            refined: res.refined,
          });
          await badgeFlash(res.appended ? "+" : "✓", "#b8ff5e", 2500);
          sendResponse({ ok: true, result: res });
        } catch (e) {
          await recordError({
            where: "capture",
            kind: msg.payload?.source?.kind,
            error: String(e?.message || e),
          });
          await badgeFlash("!", "#ff7a7a", 4000);
          sendResponse({ ok: false, error: String(e?.message || e) });
        }
      } else if (msg.type === "NOUS_STT") {
        const res = await api.stt(msg.payload);
        sendResponse({ ok: true, result: res });
      } else if (msg.type === "NOUS_START_AUDIO") {
        const tabId = sender.tab?.id;
        if (!tabId) { sendResponse({ ok: false, error: "no tab" }); return; }
        // tabCapture.getMediaStreamId must run in the service worker /
        // extension page context, NOT in the offscreen document (API is
        // undefined there). Grab the streamId here, hand it to offscreen.
        const streamId = await new Promise((resolve, reject) => {
          chrome.tabCapture.getMediaStreamId({ targetTabId: tabId }, (id) => {
            if (chrome.runtime.lastError) return reject(chrome.runtime.lastError);
            resolve(id);
          });
        });
        await ensureOffscreen();
        await chrome.runtime.sendMessage({
          type: "NOUS_OFFSCREEN_START",
          meetId: msg.meetId,
          tabId,
          streamId,
        });
        await appendLog("info", "meet", "audio recording started", { meetId: msg.meetId, tabId });
        sendResponse({ ok: true });
      } else if (msg.type === "NOUS_STOP_AUDIO") {
        await chrome.runtime.sendMessage({ type: "NOUS_OFFSCREEN_STOP" });
        await appendLog("info", "meet", "audio recording stopped");
        sendResponse({ ok: true });
      } else if (msg.type === "NOUS_MEET_PRESENCE") {
        // Meet content script forwards scraped presence. Relay to the local
        // app over the bridge using the same message shapes the standalone
        // Meet Bridge used, so the app needs no changes.
        const { participants, speaker, meetingRoom } = msg;
        if (meetingRoom) sendToBridge({ type: "meetingRoom", roomID: meetingRoom });
        if (Array.isArray(participants)) sendToBridge({ type: "participants", names: participants });
        if (speaker !== undefined) sendToBridge({ type: "speaker", name: speaker });
        sendResponse({ ok: true });
      } else if (msg.type === "NOUS_MEET_ENDED") {
        // Tell the app the meeting ended so it can clear its presence view.
        sendToBridge({ type: "meetEnded" });
        sendResponse({ ok: true });
      } else if (msg.type === "NOUS_GET_SUPPRESSION") {
        // Meet content script asks, on boot, whether its room is suppressed.
        const suppress = await isRoomSuppressed(normalizeRoom(msg.room));
        sendResponse({ ok: true, suppress });
      } else if (msg.type === "NOUS_GET_BRIDGE_STATE") {
        // Popup asks for live bridge connection + recording status.
        const state = await getBridgeState();
        sendResponse({ ok: true, ...state });
      } else {
        sendResponse({ ok: false, error: "unknown message" });
      }
    } catch (e) {
      sendResponse({ ok: false, error: String(e?.message || e) });
    }
  })();
  return true; // async sendResponse
});

// ─── Offscreen helper ──────────────────────────────────────────────────

// No in-memory flag — always query real contexts. Stale flag was a bug: if the
// offscreen document crashed/was GC'd, the flag stayed true and createDocument
// was never called again, silently breaking audio recording for the session.
async function ensureOffscreen() {
  const contexts = await chrome.runtime.getContexts({
    contextTypes: ["OFFSCREEN_DOCUMENT"],
  });
  if (contexts.length === 0) {
    await chrome.offscreen.createDocument({
      url: "offscreen/offscreen.html",
      reasons: ["USER_MEDIA"],
      justification: "Record Google Meet tab audio when captions are unavailable",
    });
  }
}

// ─── Toolbar badge (visible health signal) ──────────────────────────────

let badgeClearTimer = null;
async function badgeFlash(text, color, ms) {
  try {
    await chrome.action.setBadgeBackgroundColor({ color });
    await chrome.action.setBadgeText({ text });
    if (badgeClearTimer) clearTimeout(badgeClearTimer);
    badgeClearTimer = setTimeout(() => {
      chrome.action.setBadgeText({ text: "" }).catch(() => {});
    }, ms);
  } catch {}
}
