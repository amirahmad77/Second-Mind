# NOUS Capture (Chrome extension)

MV3 extension that saves web selections/links and Google Meet sessions to your
NOUS knowledge graph.

## Load

1. `chrome://extensions` → toggle **Developer mode**.
2. **Load unpacked** → select the `nous-extension/` directory.
3. Open the popup, set the **backend URL** (your Cloud Run URL), then enter
   the 6-digit code from **iOS › Settings › Pair browser**.

## Hotkey

- `⌘⇧J` (mac) / `Ctrl+Shift+J` — save selection, or page link if nothing
  selected.
- Right-click → **Save selection to NOUS** / **Save link to NOUS**.

## Meet

Any `meet.google.com/*` tab starts observing captions on load. If no captions
appear within ~25s, the extension falls back to recording tab audio (offscreen
document → MediaRecorder → `/v1/stt`). All turns are batched every 45s and on
tab close, keyed by `meetID` so a reconnected tab appends to the same atom.

## Icons

Drop `icon16.png`, `icon48.png`, `icon128.png` into `icons/` before publishing.
