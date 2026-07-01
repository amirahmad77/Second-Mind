# NOUS Log Access for Claude Code

## iOS App Logs

Logs land at: `{SimulatorContainer}/Documents/nous.logs.jsonl`
Each line is a JSON object: `{ "t": ISO8601, "lvl": "info|error|warning|debug", "cat": "gemini|sync|store|...", "msg": "...", "meta": {...} }`

### Quick access commands

```bash
# Tail live (color-coded)
./nous-logs

# Dump all entries
./nous-logs cat

# Search for errors
./nous-logs grep '"lvl":"error"'

# Pretty-print last 50
./nous-logs jq

# Find the exact file path
xcrun simctl get_app_container booted com.nous-core.NOUS-0 data
```

### Read latest errors
```bash
./nous-logs cat | python3 -c "
import sys, json
errs = [json.loads(l) for l in sys.stdin if l.strip()]
errs = [e for e in errs if e.get('lvl') in ('error','fault','warning')]
for e in errs[-20:]:
    meta = ' ' + json.dumps(e.get('meta',{})) if e.get('meta') else ''
    print(f\"{e['t']} [{e['cat']}] {e['msg']}{meta}\")
"
```

### Log categories
| Category | Covers |
|---|---|
| `gemini` | Refine calls, embed calls, API errors, HTTP status |
| `sync` | Supabase push/pull, backoff, embed failures |
| `store` | startRefine failures, atom lifecycle |
| `voice` | Recording start/stop/cancel |
| `auth` | Sign-in, token refresh |

---

## Chrome Extension Logs

Extension logs are stored in `chrome.storage.local` as a rolling 1000-entry buffer.

### Access options

1. **Open logs tab**: Click the NOUS extension icon → "Open logs" button → opens a color-coded log viewer tab
2. **Copy logs**: Click "Copy logs" → JSONL in clipboard → paste to Claude
3. **Chrome DevTools**: Open DevTools on any page → Console → run:
   ```js
   chrome.storage.local.get(['nous.logs'], r => console.log(r['nous.logs']?.map(e=>JSON.stringify(e)).join('\n')))
   ```
4. **Background service worker DevTools**: `chrome://extensions` → NOUS → "Service worker" → Console → same snippet

### Format
Same as iOS: `{ "t", "lvl", "cat", "msg", "meta?" }` — compatible with the same grep/jq commands.

---

## Axiom Cloud Observability (optional but recommended)

Both iOS and extension ship logs to Axiom when configured. This enables real-time querying from anywhere — including Claude Code.

### Account setup (already done ✓)

Datasets, monitors, and saved views are pre-configured:

**Datasets**
- `nous-ios` — iOS app logs (gemini, sync, store, voice, auth)
- `nous-extension` — Chrome extension logs (capture, meet, background, offscreen)

**Monitors** (alert on error conditions)
- `[iOS] Error spike` — any error/fault in 5-min window
- `[iOS] Gemini refine failure` — Gemini API errors
- `[iOS] Sync failure` — Supabase push/pull failures
- `[iOS] Sustained error rate` — 5+ errors in 15 min (systemic failure)
- `[Extension] Error spike` — any extension error in 5 min
- `[Extension] Capture failure` — web capture backend errors
- `[Extension] Meet recording error` — offscreen/AudioContext errors

**Saved views** (pre-built APL queries in Axiom UI)
- `nous-ios-all-errors`, `nous-ios-gemini`, `nous-ios-sync`, `nous-ios-error-rate`
- `nous-ext-all-errors`, `nous-ext-captures`, `nous-ext-meet`
- `nous-all-platforms` — cross-platform summary

**Remaining manual step — add notifier**: Monitors fire silently until you attach a notifier.
→ axiom.co → Monitors → pick any monitor → Add notifier → Email or Slack webhook

### Connect sources

**iOS app** — already configured in `LocalSecrets.xcconfig` with token + dataset `nous-ios`

**Chrome extension** — paste token in extension popup → set dataset `nous-extension` → Save

**Claude Code MCP** — `.mcp.json` already has the token. Restart Claude Code to activate.

---

## How Claude Should Use These Logs

When debugging NOUS, Claude Code can:

1. **With Axiom MCP**: Query directly — "Show errors from dataset nous-ios in the last 30 minutes"
2. **iOS local**: Run `./nous-logs cat` to get the full iOS log
3. **Extension local**: Ask the user to click "Copy logs" in the extension popup and paste the output
4. Look for `"lvl":"error"` entries first, then correlate by timestamp
5. Cross-reference iOS sync errors with extension capture timestamps

Example Claude prompt: _"Run `./nous-logs jq` and show me all errors from the last session"_
