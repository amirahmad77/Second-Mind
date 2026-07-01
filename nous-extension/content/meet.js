// Google Meet watcher.
//   - Extracts the meetID from the URL
//   - Scrapes caption turns from Meet's caption container (multiple selector strategies)
//   - Filters out system notifications (join/leave/recording)
//   - Batches segments and ships to /v1/capture on a cadence + at session end
//   - If no captions appear within a short window, requests background to
//     start tab-audio recording → offscreen page pipes chunks to /v1/stt

(() => {
  if (window.__nousMeetLoaded) return;
  window.__nousMeetLoaded = true;

  const MEET_ID = location.pathname.replace(/^\/+/, "").split("?")[0] || null;
  if (!MEET_ID) return;
  // Meet meeting IDs are shaped `xxx-xxxx-xxx` (lowercase letters).
  // Skip landing / new / lookup / _meet / etc.
  if (!/^[a-z]{3,}-[a-z]{3,}-[a-z]{3,}$/.test(MEET_ID)) return;

  const FLUSH_MS = 45_000;
  const NO_CAPTION_FALLBACK_MS = 25_000;

  const segments = [];
  const seenKeys = new Set();
  let startedAt = new Date();
  let endedAt = null;
  let participants = new Set();
  let audioStarted = false;
  let everHadCaptions = false;  // survives flush() clearing segments[]
  let narrowedContainer = null; // once found, observer scopes to caption node only
  let tornDown = false;         // teardown() idempotency guard

  // ── Local-app dedup ─────────────────────────────────────────────────
  // When the NOUS macOS app is locally recording THIS meeting (signalled by
  // the service worker via the bridge), we must stop pushing captions to the
  // cloud and stop the tab-audio fallback. The SW broadcasts NOUS_MEET_SUPPRESS
  // with a per-room boolean; we also ask once on boot in case the app was
  // already recording before this tab loaded.
  let cloudCaptureSuppressed = false;

  // ── Presence forwarding (to the bridge, via the SW) ─────────────────
  // We piggyback on the existing caption MutationObserver below — NO second
  // observer. After each scrape pass we diff the participant list + active
  // speaker and, when they change, forward them to the SW which relays to the
  // local app. This powers the app's "who's in the meeting" view; it is
  // independent of cloud capture and is never suppressed.
  let lastPresenceKey = "";   // JSON of {participants, speaker} last sent
  let lastSpeaker = null;

  // ── System message filter ───────────────────────────────────────────
  // Meet broadcasts join/leave/recording notices via aria-live. Scraping
  // the live region naively picks these up as captions. Filter them out.

  const SYSTEM_PATTERNS = [
    /\b(joined|left)\b.*(meeting|call|session)/i,
    /\bhas (joined|left)\b/i,
    /turned (on|off)\b.*(caption|recording|transcript|live stream)/i,
    /^(you are|you're) (now )?(muted|unmuted)\.?$/i,
    /^(you|your screen) (are|is) (now )?(being )?(presented|shared)/i,
    /recording (has )?(started|stopped|in progress|been paused)/i,
    /\bwas removed\b/i,
    /admitted from (the )?waiting room/i,
    /^this call is (being )?recorded/i,
    /^live (caption|transcript)/i,
    /captions (are )?off/i,
    /^\s*$/, // blank
  ];

  function isSystemMessage(text) {
    if (!text || text.length < 5) return true;
    // Very long single-word strings are usually class leakage, not speech.
    if (text.split(/\s+/).length === 1 && text.length > 40) return true;
    for (const re of SYSTEM_PATTERNS) {
      if (re.test(text.trim())) return true;
    }
    return false;
  }

  // ── Caption scraping ────────────────────────────────────────────────
  // Strategy 1: explicit Google Meet caption container selectors (more stable).
  // Strategy 2: fallback to aria-live regions with system-message filtering.
  // Both strategies de-duplicate via seenKeys.

  // Known Meet caption container selectors (updated for 2025 UI variants).
  // Meet renders captions at the bottom of the video grid when CC is enabled.
  const CAPTION_CONTAINER_SELECTORS = [
    '[jsname="tgaKEf"]',           // caption tray (older Meet)
    '[jsname="r4nke"]',            // caption block wrapper (2024-2025)
    '[jsname="YSg4Xe"]',           // caption text span (2024-2025)
    '[data-attribution-id]',       // speaker attribution blocks
    '[data-message-id]',           // newer Meet message blocks
    '[class*="caption"]',          // any class containing "caption"
    '[aria-label*="caption" i]',   // labeled caption regions
    '[aria-label*="transcript" i]',
    '.nMcdL',                      // observed in 2024 Meet builds
  ];

  function extractSpeakerAndBody(el) {
    // Approach 0: Meet-specific data attributes (most reliable when present).
    const attrSpeaker = el.getAttribute("data-sender-name")
      || el.querySelector("[data-sender-name]")?.getAttribute("data-sender-name");
    if (attrSpeaker) {
      const body = el.textContent.replace(attrSpeaker, "").replace(/^[\s:]+/, "").trim();
      if (body.length > 3) return { speaker: attrSpeaker, body };
    }

    // Approach A: two sibling spans — first is speaker name, second is text.
    const spans = Array.from(el.querySelectorAll("span")).filter(s => s.textContent.trim());
    if (spans.length >= 2) {
      const maybeSpeaker = spans[0].textContent.trim();
      const maybeBody = spans.slice(1).map(s => s.textContent.trim()).join(" ").trim();
      // Speaker is plausibly a name if it's short and lacks sentence punctuation.
      if (maybeSpeaker.length < 60 && !/[.!?]/.test(maybeSpeaker) && maybeBody.length > 3) {
        return { speaker: maybeSpeaker, body: maybeBody };
      }
    }

    // Approach B: "Speaker: text" colon separator in full text.
    const full = el.textContent.trim();
    const colonIdx = full.indexOf(":");
    if (colonIdx > 0 && colonIdx < 60) {
      const candidate = full.slice(0, colonIdx).trim();
      const body = full.slice(colonIdx + 1).trim();
      if (candidate.split(/\s+/).length <= 4 && body.length > 3) {
        return { speaker: candidate, body };
      }
    }

    // Approach C: whole element is the text (speaker unknown).
    return { speaker: null, body: full };
  }

  function tryAddSegment(speaker, body) {
    if (!body || body.length < 5) return;
    if (isSystemMessage(body)) return;
    // Normalize for dedup: lowercase + collapse whitespace. Store original text.
    const normKey = `${(speaker || "?").toLowerCase()}::${body.toLowerCase().replace(/\s+/g, " ").trim()}`;
    if (seenKeys.has(normKey)) return;
    seenKeys.add(normKey);
    segments.push({ speaker: speaker || null, text: body, at: new Date().toISOString() });
    if (speaker) participants.add(speaker);
    everHadCaptions = true;
  }

  function scrapeByTargetedSelectors() {
    for (const sel of CAPTION_CONTAINER_SELECTORS) {
      const containers = document.querySelectorAll(sel);
      for (const c of containers) {
        const { speaker, body } = extractSpeakerAndBody(c);
        tryAddSegment(speaker, body);
      }
    }
  }

  function scrapeAriaLiveRegions() {
    // Only use aria-live="off" and "polite"; "assertive" is almost always
    // system toasts, not caption text.
    const roots = document.querySelectorAll('[aria-live="polite"], [aria-live="off"]');
    for (const root of roots) {
      // Walk direct block children — avoids double-counting nested spans.
      const blocks = root.querySelectorAll(":scope > div, :scope > li, :scope > p");
      const targets = blocks.length > 0 ? blocks : [root];
      for (const b of targets) {
        const { speaker, body } = extractSpeakerAndBody(b);
        tryAddSegment(speaker, body);
      }
    }
  }

  function maybeNarrowObserver() {
    if (narrowedContainer) return;
    for (const sel of CAPTION_CONTAINER_SELECTORS) {
      const el = document.querySelector(sel);
      // Only narrow if the element has content — avoid locking to an empty placeholder.
      if (el && el.textContent.trim().length > 10) {
        narrowedContainer = el;
        captionObserver.disconnect();
        captionObserver.observe(el, { subtree: true, childList: true, characterData: true });
        return;
      }
    }
  }

  function scrapeCaptions() {
    scrapeByTargetedSelectors();
    scrapeAriaLiveRegions();
    maybeNarrowObserver();
  }

  // ── Presence scraping (participants + active speaker) ────────────────
  // Ported from the standalone Meet Bridge content script. These read Meet's
  // participant tiles / people panel rather than captions, so presence works
  // even when captions are off. Called from the same observer callback that
  // drives caption scraping — no extra MutationObserver.

  function scrapeParticipants() {
    const names = new Set();

    // Strategy 1: data-participant-id tiles (main grid).
    document.querySelectorAll("[data-participant-id]").forEach((el) => {
      const tip = el.getAttribute("data-tooltip");
      if (tip && tip.length < 80) names.add(tip.trim());
      const aria = el.getAttribute("aria-label") || "";
      const m = aria.match(/^([^'(]+?)(?:'s video| \()?/);
      if (m?.[1] && m[1].length < 80) names.add(m[1].trim());
    });

    // Strategy 2: people-panel list items.
    document.querySelectorAll('[role="listitem"]').forEach((el) => {
      const selfEl = el.querySelector("[data-self-name]");
      if (selfEl) {
        const n = selfEl.textContent.trim();
        if (n && n.length < 80) names.add(n);
      }
      el.querySelectorAll("span[jsname]").forEach((s) => {
        const n = s.textContent.trim();
        if (n && n.length < 80 && !n.includes("(") && /^[A-Za-z]/.test(n)) names.add(n);
      });
    });

    // Strategy 3: video-tile name labels (class names drift but are stable-ish).
    document.querySelectorAll(".zWGUib, .KF4T6b, .cS7aqe, .XEazBc").forEach((el) => {
      const n = el.textContent.trim();
      if (n && n.length < 80 && !n.includes("(")) names.add(n);
    });

    // Drop "You" variants — the local user is handled by the app's mic channel.
    return [...names].filter(
      (n) => n.toLowerCase() !== "you" && !n.includes("(You)") && n !== ""
    );
  }

  function scrapeSpeaker() {
    const selectors = [
      '[data-is-speaking="true"]',
      '[data-speaking="true"]',
      '[aria-label*="speaking" i]',
      ".speaking",
    ];
    for (const sel of selectors) {
      const el = document.querySelector(sel);
      if (!el) continue;
      const name =
        el.getAttribute("data-tooltip")?.trim() ||
        el.querySelector("[data-tooltip]")?.getAttribute("data-tooltip")?.trim() ||
        el.querySelector(".zWGUib, .KF4T6b, .XEazBc")?.textContent?.trim() ||
        el.getAttribute("aria-label")?.replace(/'s video.*/i, "").trim();
      if (name && name.length < 80 && name.toLowerCase() !== "you") return name;
    }
    return null;
  }

  // Diff presence against the last sent value; forward to the SW only on change
  // so we don't spam the bridge on every DOM mutation.
  function forwardPresence() {
    const list = scrapeParticipants().sort();
    const speaker = scrapeSpeaker();
    lastSpeaker = speaker;
    const key = JSON.stringify({ p: list, s: speaker });
    if (key === lastPresenceKey) return;
    lastPresenceKey = key;
    try {
      chrome.runtime.sendMessage({
        type: "NOUS_MEET_PRESENCE",
        participants: list,
        speaker,
        meetingRoom: MEET_ID,
      });
    } catch (_) {
      // Extension context invalidated (reload) — ignore; next scrape retries.
    }
  }

  let scrapeTimer = null;
  const captionObserver = new MutationObserver(() => {
    clearTimeout(scrapeTimer);
    scrapeTimer = setTimeout(() => {
      scrapeCaptions();
      // Piggyback presence forwarding on the same debounced pass. Presence is
      // always forwarded (independent of cloud-capture suppression).
      forwardPresence();
    }, 120);
  });

  function attachCaptionObserver() {
    if (!document.body) return;
    captionObserver.observe(document.body, {
      subtree: true,
      childList: true,
      characterData: true,
    });
  }

  // ── Audio fallback ──────────────────────────────────────────────────

  async function maybeStartAudioFallback() {
    if (audioStarted) return;
    if (everHadCaptions) return; // captions are working — segments[] may be empty after a flush
    if (cloudCaptureSuppressed) {
      // Local app is recording this meeting — don't spin up the tab-audio
      // fallback (it would double-capture).
      console.info("[nous] audio fallback suppressed — local app is recording");
      return;
    }
    audioStarted = true;
    try {
      await chrome.runtime.sendMessage({ type: "NOUS_START_AUDIO", meetId: MEET_ID });
    } catch (e) {
      console.warn("[nous] audio fallback start failed", e);
    }
  }

  async function stopAudioFallback() {
    if (!audioStarted) return;
    try {
      await chrome.runtime.sendMessage({ type: "NOUS_STOP_AUDIO" });
    } catch {}
    audioStarted = false;
  }

  chrome.runtime.onMessage.addListener((msg) => {
    if (msg?.type === "NOUS_AUDIO_SEGMENTS" && msg.meetId === MEET_ID) {
      for (const seg of msg.segments || []) {
        tryAddSegment(seg.speaker || null, seg.text);
      }
    } else if (msg?.type === "NOUS_MEET_SUPPRESS") {
      // The SW computed this tab's suppression boolean (per-room). Apply it.
      applySuppression(!!msg.suppress);
    }
  });

  // Toggle cloud-capture suppression for this Meet tab. When turning ON while
  // the audio fallback is live, stop it so the local app is the sole recorder.
  function applySuppression(suppress) {
    if (suppress === cloudCaptureSuppressed) return; // no change
    cloudCaptureSuppressed = suppress;
    if (suppress) {
      console.info("[nous] cloud Meet capture SUPPRESSED — local app recording this meeting");
      // If the tab-audio fallback was already running, shut it down.
      if (audioStarted) stopAudioFallback();
    } else {
      console.info("[nous] cloud Meet capture RESUMED — local app no longer recording");
      // Captions resume on the next observer pass / flush tick automatically.
    }
  }

  // ── Flushing ────────────────────────────────────────────────────────

  async function flush({ final = false } = {}) {
    if (cloudCaptureSuppressed) {
      // Local app is recording this meeting. Discard buffered captions so we
      // don't (a) double-capture this stretch of the call into the cloud, nor
      // (b) dump a large stale backlog when capture resumes. Presence
      // forwarding is unaffected — only cloud capture is gated.
      if (segments.length > 0) {
        console.info(`[nous] dropping ${segments.length} captions — local app is recording`);
        segments.splice(0, segments.length);
      }
      return;
    }
    if (segments.length === 0 && !final) return;
    const batch = segments.splice(0, segments.length);
    if (batch.length === 0) return;
    const payload = {
      source: {
        kind: "meet",
        meetID: MEET_ID,
        url: location.href,
        title: document.title,
        participants: Array.from(participants),
        startedAt: startedAt.toISOString(),
        endedAt: (endedAt || (final ? new Date() : null))?.toISOString() || null,
      },
      segments: batch,
      client_nonce: `${MEET_ID}-${Date.now()}`,
    };
    try {
      await chrome.runtime.sendMessage({ type: "NOUS_CAPTURE", payload });
    } catch (e) {
      segments.unshift(...batch);
      console.warn("[nous] meet flush failed", e);
    }
  }

  // ── Lifecycle ──────────────────────────────────────────────────────

  function boot() {
    attachCaptionObserver();
    scrapeCaptions();
    forwardPresence(); // send initial roster/speaker to the app right away
    // Ask the SW whether the local app is ALREADY recording this room (it may
    // have started before this tab loaded). The SW also broadcasts changes.
    queryInitialSuppression();
    setTimeout(maybeStartAudioFallback, NO_CAPTION_FALLBACK_MS);
    setInterval(() => { flush(); }, FLUSH_MS);
  }

  async function queryInitialSuppression() {
    try {
      const res = await chrome.runtime.sendMessage({
        type: "NOUS_GET_SUPPRESSION",
        room: MEET_ID,
      });
      if (res?.ok) applySuppression(!!res.suppress);
    } catch (_) {
      /* SW not ready / context invalidated — change broadcasts will catch up */
    }
  }

  async function teardown() {
    if (tornDown) return;
    tornDown = true;
    endedAt = new Date();
    await stopAudioFallback();
    await flush({ final: true });
    captionObserver.disconnect();
    // Tell the local app (via the SW → bridge) that this meeting ended so it
    // can clear its presence view.
    try {
      await chrome.runtime.sendMessage({ type: "NOUS_MEET_ENDED" });
    } catch (_) {}
  }

  window.addEventListener("beforeunload", teardown);
  window.addEventListener("pagehide", teardown);

  // Detect "leave call" via URL change.
  let lastPath = location.pathname;
  setInterval(() => {
    if (location.pathname !== lastPath) {
      lastPath = location.pathname;
      teardown();
    }
  }, 2000);

  if (document.readyState === "complete" || document.readyState === "interactive") {
    boot();
  } else {
    window.addEventListener("DOMContentLoaded", boot);
  }
})();
