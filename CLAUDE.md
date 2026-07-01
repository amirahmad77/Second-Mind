# NOUS — Claude Code Development Guide

Quick-reference for every session. Read this before touching any file.

---

## Project Layout

```
NOUS V3/
├── NOUS 0/
│   ├── NOUS 0.xcodeproj/          # Xcode project (PBXFileSystemSynchronizedRootGroup — no manual file registration needed)
│   └── NOUS 0/                    # All source
│       ├── App/                   # AppEnv, NousLogger, RemoteConfig, Secrets, AxiomShipper
│       ├── Auth/                  # AuthClient, AuthSession, Keychain
│       ├── Cloud/                 # GeminiClient, SupabaseClient, SyncDaemon, DeepgramLiveTranscriber
│       ├── Design/                # Tokens.swift (NSColorToken, NFont, NSpace), OKLCH.swift
│       ├── Model/                 # Atom, AtomStore, NoteEvent, Persistence, LinkParser
│       ├── UI/
│       │   ├── Mac/               # macOS-only: MacRootView, MacAtomList, MacAtomDetail, MacSidebar
│       │   ├── Stream/            # iOS: StreamView, AtomRow, DayHeader, AtomDot
│       │   ├── Atom/              # AtomDetailView (shared iOS+macOS)
│       │   └── …                  # Capture, Tags, Search, Synthesis, Daily, Root, Orb …
│       └── Voice/                 # VoiceRecorder, MacMeetingRecorder
├── supabase/
│   └── functions/
│       └── get-config/            # Edge function: returns API keys to authenticated clients
└── CLAUDE.md                      # ← this file
```

---

## ⚠️ Multi-Platform: Two Stream Components

The stream list renders differently per platform. **Always edit both when changing list row behaviour.**

| Platform | File | Component |
|----------|------|-----------|
| iOS | `UI/Stream/AtomRow.swift` | `AtomRow` |
| macOS | `UI/Mac/MacAtomList.swift` | `MacAtomRow` (private, inside same file) |

`AtomDetailView.swift`, `GeminiClient.swift`, `AtomStore.swift`, `NousLogger.swift` — **no platform conditional**, apply to both.

Files wrapped in `#if os(macOS)` (MacAtomList, MacRootView, DeepgramLiveTranscriber, etc.) compile only for macOS. SourceKit will show false-positive "Cannot find X in scope" errors on these files when the active scheme targets iOS — **builds succeed regardless**.

---

## ⚠️ Worktree Awareness

Claude Code sessions run inside git worktrees at `.claude/worktrees/<name>/`. Xcode may have the **worktree project** open rather than the main project. If edits to main don't appear after a clean rebuild:

```bash
# Copy changed files from main → worktree (replace <name> with active worktree)
WT=".claude/worktrees/angry-meitner-fbc0a9"
cp "NOUS 0/NOUS 0/UI/Stream/AtomRow.swift"       "$WT/NOUS 0/NOUS 0/UI/Stream/AtomRow.swift"
cp "NOUS 0/NOUS 0/UI/Mac/MacAtomList.swift"       "$WT/NOUS 0/NOUS 0/UI/Mac/MacAtomList.swift"
# … repeat for each changed file
```

**Always sync both directions.** Edit main first, then copy to the active worktree.

---

## API Keys & Remote Config

**Never hardcode keys.** Priority chain for every key:

1. `ProcessInfo.processInfo.environment[key]` — Xcode scheme env vars (**DELETE these after migration**)
2. `Bundle.main.object(forInfoDictionaryKey:)` — Info.plist / xcconfig build settings
3. `Secrets.swift` — compile-time fallback (gitignored)

**Production path:** Keys live in Supabase Edge Function secrets.
After auth, `RemoteConfig.shared.fetch()` calls the `get-config` edge function and populates `RemoteConfig.shared.geminiAPIKey` / `deepgramAPIKey`. Call `fetch()` once at app bootstrap (already wired in `MacRootView.bootstrap()`).

`GeminiClient` and `DeepgramLiveTranscriber` both use `resolvedKey` which prefers `RemoteConfig` over the compile-time fallback.

**To rotate a key (no app update needed):**
```bash
supabase secrets set GEMINI_API_KEY=<new> --project-ref ssibcqwsaycnlzlxzked
supabase secrets set DEEPGRAM_API_KEY=<new> --project-ref ssibcqwsaycnlzlxzked
```

---

## Models

| Purpose | Model | Where |
|---------|-------|-------|
| Refine + classify + tag | `gemini-flash-latest` | `AppEnv.geminiRefineModel` |
| Embeddings (semantic search) | `gemini-embedding-001` | `AppEnv.geminiEmbedModel` |
| Meeting transcription | `gemini-1.5-flash-latest` | hardcoded in `GeminiClient.transcribeMeeting` |
| Live mic transcription | Deepgram Nova-3 WebSocket | `DeepgramLiveTranscriber` |
| Embedding dimensions | 768 (MRL truncated) | `AppEnv.embedDim` |

> ⚠️ `geminiRefineModel` must support structured JSON output + good tag quality. Current value is `gemini-flash-latest`. Do NOT drop below a flash-tier model — older/smaller models produce malformed schemas.

---

## Logging

Use `NousLogger` everywhere. Never use `print()`.

```swift
NousLogger.debug("category",   "message")
NousLogger.info("category",    "message", ["key": value])
NousLogger.warning("category", "message", ["key": value])
NousLogger.error("category",   "message", ["key": value])
NousLogger.fault("category",   "message")
```

**Categories in use:** `gemini`, `store`, `sync`, `auth`, `deepgram`, `config`, `voice`, `embed`

**What happens to each log:**
- `os.Logger` → Console.app (both iOS + macOS, survives to production)
- `AxiomShipper` → Axiom cloud (structured JSON, both platforms, production + debug). Every entry gets `"platform": "ios"` or `"platform": "macos"` automatically.
- `FileLogger` (DEBUG only) → `Documents/nous.logs.jsonl` (JSONL, local, great for Claude Code inspection)

**Read logs from simulator without Xcode:**
```bash
./nous-logs   # script at project root — tails Documents/nous.logs.jsonl live
# or manually:
tail -f "$(xcrun simctl get_app_container booted com.nous-core.NOUS-0 data)/Documents/nous.logs.jsonl"
```

---

## Design System

All tokens in `Design/Tokens.swift`. Never use raw hex or hard-coded colors.

### Colors (`NSColorToken`)
```swift
// Surfaces (dark OKLCH, blue-tinted)
NSColorToken.inkVoid       // 0.10 — deepest background
NSColorToken.inkPaper      // 0.14 — panel background
NSColorToken.inkRaised     // 0.18 — elevated surfaces, cards

// Text
NSColorToken.textPrimary   // 0.95 — headings, active titles
NSColorToken.textSecondary // 0.72 — body, default text
NSColorToken.textTertiary  // 0.52 — subdued labels
NSColorToken.textGhost     // 0.36 — timestamps, hints, placeholders

// Phosphor (atom type colors)
NSColorToken.Phos.cyan     // thought
NSColorToken.Phos.green    // task
NSColorToken.Phos.amber    // meeting
NSColorToken.Phos.blue     // decision
NSColorToken.Phos.orange   // question
NSColorToken.Phos.violet   // reference
// Access via atom.type.phosphor
```

### Spacing (`NSpace`)
```swift
NSpace.xs   = 4    NSpace.sm  = 8    NSpace.md  = 12
NSpace.lg   = 16   NSpace.xl  = 24   NSpace.xxl = 32
NSpace.xxxl = 48   NSpace.x4  = 64   NSpace.x5  = 96
```

### Fonts (`NFont`)
```swift
NFont.body(_ size)        // humanist body
NFont.detailBody(_ size)  // slightly larger body for detail views
NFont.mono(_ size)        // monospaced — metadata, labels, chrome
NFont.monoSmall(_ size)   // medium weight mono — tags, small labels
NFont.dayHeader(_ size)   // heavy compressed — section headers
// Dynamic Type body (scales with user accessibility setting):
Text("...").nDynamicBody(15)   // NOT .font(NFont.body(15))
```

### Animations
```swift
.animation(.nEaseOutQuint, value: ...)    // most UI transitions
.animation(.nEaseInOutQuint, value: ...)  // content crossfades
.animation(.nDrawer, value: ...)          // panel open/close
.animation(.nPress, value: ...)           // tap feedback
```

---

## Data Model

**Event-sourced, append-only.** Never mutate atoms directly — always write a `NoteEvent`.

```
NoteEventKind: created | updatedRaw | refined | typeChanged |
               linked | tagged | taskToggled | dueSet | deleted
```

`AtomStore` reduces events → `AtomSnapshot` (in-memory read model).
`AtomSnapshot` is a value type — safe to pass anywhere, always a consistent point-in-time view.

**Key AtomStore methods:**
```swift
store.capture(text:)                    // creates atom
store.updateRaw(id:newContent:)         // triggers re-refine
store.startRefine(id:raw:)             // queues Gemini refine job
store.setType(id:to:)                  // manual type override
store.addTag(id:tag:) / removeTag(...)
store.toggleTask(id:)
store.inboundCount(of:)                // backlink graph count
store.groupedByDay(filter:tag:)        // stream grouped output
```

**Bootstrap recovery:** On launch, `AtomStore.bootstrap()` re-queues any atom where `refinedContent == nil && !isRefining && rawContent.count >= 8`. This recovers atoms whose refinement was interrupted.

---

## Tagging Rules (enforced in `GeminiClient` + `TagNormalizer`)

- **1–4 tags max.** Quality beats quantity.
- **Specific > generic.** "supabase-rls" not "database". "openai-board-dispute" not "artificial-intelligence".
- **Max 2 proper nouns** (people, companies, products) per atom.
- **Blocklisted terms** (stripped by `TagNormalizer` even if Gemini generates them):
  `ai`, `artificial-intelligence`, `technology`, `tech`, `software`, `ideas`, `thoughts`, `notes`, `analysis`, `research`, `knowledge-management`, `productivity`, `workflow`, `process`, `system`, `content`, `data`, `information`, `misc`, `general`, `interesting`, `narrative`, `formatting`, `testing`, `documentation`, `work`, `project`, `personal`, `daily`
- Never restate the atom type as a tag.
- `TagNormalizer.normalize()` also: lowercases, hyphenates spaces, strips non-`[a-z0-9-]`, dedupes, caps at 4.

---

## Supabase Backend

- **Project ref:** `ssibcqwsaycnlzlxzked`
- **URL:** `https://ssibcqwsaycnlzlxzked.supabase.co`
- **Auth:** Supabase Auth (email + magic link). `AuthClient.shared` manages session.
- **Sync:** `SyncDaemon` pushes `NoteEvent`s to `note_events` table, pulls remote events on launch + periodic refresh.
- **Edge Functions:** `supabase/functions/` — deploy with `supabase functions deploy <name> --project-ref ssibcqwsaycnlzlxzked`
- **Active functions:** `get-config` (returns API keys to authenticated clients)
- **Secrets:** `supabase secrets set KEY=value --project-ref ssibcqwsaycnlzlxzked`

---

## Common Pitfalls

| Symptom | Cause | Fix |
|---------|-------|-----|
| Code changes don't appear after clean build | Xcode has the worktree project open, not main | Copy changed files to the active worktree (see Worktree section) |
| `refine HTTP 400 API key expired` | Stale key in Xcode scheme env vars overrides RemoteConfig | Delete `NOUS_GEMINI_API_KEY` from scheme → Edit Scheme → Run → Arguments |
| SourceKit "Cannot find X in scope" on macOS files | False positive — cross-file `#if os(macOS)` scoping | Ignore. Build succeeds. |
| Atom stuck with `isRefining = true` forever | Old bug: catch block wrote empty `.refined` event. Fixed. | Bootstrap recovery re-queues on next launch automatically. |
| Tags are vague/generic after refine | Prompt or blocklist gap | Add term to `TagNormalizer.blocklist` AND the `NEVER use` list in `tagRules` |
| `RemoteConfig` actor isolation error | Accessing `@MainActor` property from non-MainActor context | `RemoteConfig` is `@unchecked Sendable`, not `@MainActor` — use `resolvedKey` pattern |

---

## Checklist Before Every PR

- [ ] Changes to `AtomRow.swift` mirrored in `MacAtomRow` inside `MacAtomList.swift` (and vice versa)
- [ ] All debug output uses `NousLogger`, not `print()`
- [ ] No API keys committed (`Secrets.swift` is gitignored — verify with `git status`)
- [ ] No hardcoded model names — use `AppEnv.geminiRefineModel` / `AppEnv.geminiEmbedModel`
- [ ] New files synced to active worktree if Xcode is open there
- [ ] SourceKit errors checked — distinguish false positives from real ones by attempting a build
