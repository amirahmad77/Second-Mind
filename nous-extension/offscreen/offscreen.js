// Offscreen audio recorder. Runs in an offscreen document because MV3 service
// workers can't use MediaRecorder. Pipes ~20s webm/opus chunks to the backend
// STT endpoint and forwards transcribed segments back to the Meet content script.

let mediaRecorder = null;
let audioCtx = null;        // closed on stop() to end the monitor tap
let stream = null;
let currentMeetId = null;
let currentTabId = null;
let chunkStart = null;
let consecutiveFailures = 0;
let starting = false;       // guards against concurrent NOUS_OFFSCREEN_START

// 15s chunks: shorter windows mean less speech lost at boundaries, and STT
// latency stays reasonable. 20s was unnecessarily long.
const CHUNK_MS = 15_000;
const MAX_CONSECUTIVE_FAILURES = 5;

chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  (async () => {
    if (msg?.type === "NOUS_OFFSCREEN_START") {
      await start(msg.meetId, msg.tabId, msg.streamId);
      sendResponse({ ok: true });
    } else if (msg?.type === "NOUS_OFFSCREEN_STOP") {
      await stop();
      sendResponse({ ok: true });
    }
  })();
  return true;
});

async function start(meetId, tabId, streamId) {
  // Guard: reject concurrent starts (mediaRecorder is set lazily inside
  // recordChunk, so it's null for a brief window after start() is called).
  if (mediaRecorder || starting) return;
  starting = true;
  try {
    currentMeetId = meetId;
    currentTabId = tabId;
    if (!streamId) throw new Error("missing streamId from background");

    stream = await navigator.mediaDevices.getUserMedia({
      audio: {
        mandatory: {
          chromeMediaSource: "tab",
          chromeMediaSourceId: streamId,
        },
      },
      video: false,
    });

    // Keep tab audio audible to the user while we record.
    audioCtx = new AudioContext();
    audioCtx.createMediaStreamSource(stream).connect(audioCtx.destination);

    loop();
  } finally {
    starting = false;
  }
}

async function loop() {
  while (stream && stream.active) {
    try {
      await recordChunk();
      consecutiveFailures = 0;
    } catch (e) {
      consecutiveFailures++;
      console.warn(`[nous-offscreen] chunk failed (${consecutiveFailures}/${MAX_CONSECUTIVE_FAILURES})`, e);
      if (consecutiveFailures >= MAX_CONSECUTIVE_FAILURES) {
        console.error("[nous-offscreen] too many failures, stopping recorder");
        await stop();
        return;
      }
      await sleep(1000);
    }
  }
}

function recordChunk() {
  return new Promise((resolve, reject) => {
    const rec = new MediaRecorder(stream, { mimeType: "audio/webm;codecs=opus" });
    mediaRecorder = rec;
    const chunks = [];
    chunkStart = new Date();
    rec.ondataavailable = (e) => { if (e.data.size > 0) chunks.push(e.data); };
    rec.onerror = (e) => reject(e.error || e);
    rec.onstop = async () => {
      try {
        if (chunks.length) {
          const blob = new Blob(chunks, { type: "audio/webm" });
          await ship(blob, chunkStart);
        }
        resolve();
      } catch (err) {
        reject(err);
      }
    };
    rec.start();
    setTimeout(() => { if (rec.state !== "inactive") rec.stop(); }, CHUNK_MS);
  });
}

async function ship(blob, startedAt) {
  const b64 = await blobToBase64(blob);
  const res = await chrome.runtime.sendMessage({
    type: "NOUS_STT",
    payload: {
      meetID: currentMeetId,
      chunkStartedAt: startedAt.toISOString(),
      audioBase64: b64,
      mime: "audio/webm",
    },
  });
  if (!res?.ok) return;
  const segments = res.result?.segments || [];
  if (segments.length === 0) return;
  try {
    await chrome.tabs.sendMessage(currentTabId, {
      type: "NOUS_AUDIO_SEGMENTS",
      meetId: currentMeetId,
      segments,
    });
  } catch {}
}

async function stop() {
  const rec = mediaRecorder;
  const oldStream = stream;
  const oldCtx = audioCtx;
  // Null these out so loop() exits on the next iteration check.
  mediaRecorder = null;
  stream = null;
  audioCtx = null;

  if (rec && rec.state !== "inactive") {
    // Wrap onstop so stop() doesn't return until ship() has completed.
    // This lets teardown() swap its order (stop-then-flush) so the last
    // chunk's segments are forwarded to the tab before the final flush.
    await new Promise((resolve) => {
      const orig = rec.onstop;
      rec.onstop = async () => {
        if (orig) await orig();
        resolve();
      };
      try { rec.stop(); } catch { resolve(); }
    });
  }

  if (oldStream) {
    for (const t of oldStream.getTracks()) t.stop();
  }

  // Close AudioContext so the tab audio monitor tap is released.
  // Without this, audio keeps routing to the speakers after recording ends.
  if (oldCtx && oldCtx.state !== "closed") {
    try { await oldCtx.close(); } catch {}
  }
}

function blobToBase64(blob) {
  return new Promise((resolve, reject) => {
    const r = new FileReader();
    r.onloadend = () => {
      const s = r.result || "";
      const i = typeof s === "string" ? s.indexOf(",") : -1;
      resolve(typeof s === "string" && i >= 0 ? s.slice(i + 1) : "");
    };
    r.onerror = () => reject(r.error);
    r.readAsDataURL(blob);
  });
}

function sleep(ms) { return new Promise((r) => setTimeout(r, ms)); }
