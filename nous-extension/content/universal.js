// Runs on every page. Listens for capture commands from the background worker,
// builds a payload with selection + page context, and ships it.

(() => {
  if (window.__nousUniversalLoaded) return;
  window.__nousUniversalLoaded = true;

  function getPageMeta() {
    const meta = (name) =>
      document.querySelector(
        `meta[name="${name}" i], meta[property="${name}" i]`
      )?.getAttribute("content") || null;
    return {
      url: location.href,
      domain: location.hostname,
      title: document.title || null,
      metaDescription:
        meta("description") || meta("og:description") || meta("twitter:description"),
    };
  }

  function getSelectionText() {
    const sel = window.getSelection?.();
    if (!sel || sel.isCollapsed) return "";
    return (sel.toString() || "").trim();
  }

  function fallbackPageGist() {
    // No selection? Grab a short readable gist: meta description + first few
    // prominent paragraphs. Backend refiner does the real compression.
    const meta = getPageMeta().metaDescription || "";
    const paras = Array.from(document.querySelectorAll("article p, main p, p"))
      .map((p) => p.textContent?.trim() || "")
      .filter((t) => t.length > 60)
      .slice(0, 4)
      .join("\n\n");
    return [meta, paras].filter(Boolean).join("\n\n").slice(0, 4000);
  }

  function nonce() {
    return `${Date.now()}-${Math.random().toString(36).slice(2, 10)}`;
  }

  async function capture({ includeSelection = true, forcedUrl = null } = {}) {
    const meta = getPageMeta();
    if (forcedUrl) meta.url = forcedUrl;
    const sel = includeSelection ? getSelectionText() : "";
    const text = sel || fallbackPageGist();
    if (!text || text.length < 3) {
      flash("Nothing to save on this page.", true);
      return;
    }
    flash("Saving to NOUS…");
    let res;
    try {
      res = await chrome.runtime.sendMessage({
        type: "NOUS_CAPTURE",
        payload: {
          source: { kind: "web", ...meta },
          text,
          client_nonce: nonce(),
        },
      });
    } catch (e) {
      // Extension context was invalidated (e.g. extension reloaded while page open).
      flash("NOUS extension reloaded — refresh page to re-enable.", true);
      return;
    }
    if (!res?.ok) {
      flash(`Save failed: ${res?.error || "unknown"}`, true);
    }
  }

  chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
    if (msg?.type === "NOUS_CAPTURE_SELECTION") {
      capture({ includeSelection: true });
      sendResponse({ ok: true });
    } else if (msg?.type === "NOUS_CAPTURE_LINK") {
      capture({ includeSelection: false, forcedUrl: msg.url });
      sendResponse({ ok: true });
    }
    return false;
  });

  // ─── Toast ────────────────────────────────────────────────────────────
  let toastEl = null;
  function flash(text, isError = false) {
    if (!toastEl) {
      toastEl = document.createElement("div");
      toastEl.style.cssText = [
        "position:fixed",
        "right:16px",
        "bottom:16px",
        "z-index:2147483647",
        "padding:10px 14px",
        "border-radius:10px",
        "font:500 13px/1.2 -apple-system,system-ui,sans-serif",
        "color:#f5f5f5",
        "background:rgba(18,18,18,0.92)",
        "backdrop-filter:blur(8px)",
        "box-shadow:0 6px 24px rgba(0,0,0,0.35)",
        "opacity:0",
        "transform:translateY(6px)",
        "transition:opacity 160ms ease-out, transform 160ms ease-out",
        "pointer-events:none",
      ].join(";");
      document.documentElement.appendChild(toastEl);
    }
    toastEl.textContent = text;
    toastEl.style.borderLeft = ""; // no side-stripe — banned
    toastEl.style.color = isError ? "#ff7a7a" : "#c8ffd7";
    requestAnimationFrame(() => {
      toastEl.style.opacity = "1";
      toastEl.style.transform = "translateY(0)";
    });
    clearTimeout(flash._t);
    flash._t = setTimeout(() => {
      toastEl.style.opacity = "0";
      toastEl.style.transform = "translateY(6px)";
    }, 1800);
  }
})();
