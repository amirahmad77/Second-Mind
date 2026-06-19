# NOUS Widget — setup (one-time, ~5 min in Xcode)

The widget **code is done** (`NOUS Widgets/`) and the app already publishes data to
the App Group (`WidgetBridge` → `AtomStore.publishWidgetSnapshot`). What remains is
adding the Widget Extension *target* and registering the App Group — steps that need
Xcode + your Apple Developer account (they can't be done headlessly / from CI).

## 1. Register the App Group (also unblocks macOS signing)
The app now declares `com.apple.security.application-groups = [group.com.nous-core.NOUS-0]`.
- In Xcode: select the **NOUS 0** target → Signing & Capabilities → **+ Capability → App Groups** → check/add `group.com.nous-core.NOUS-0`. Xcode registers it with team `95Z83CMC8G` and regenerates the provisioning profile.
- This also fixes the current macOS "no profiles … App Groups" signing error.

## 2. Add the Widget Extension target
- File → New → Target → **Widget Extension** (name it `NOUS Widgets`). Uncheck "Include Configuration Intent" (this is a `StaticConfiguration` widget). Embed in **NOUS 0**.
- **Delete** the template `.swift`/`Assets` Xcode created for it.
- Add the existing files in this folder to the new target:
  - `NousWidget.swift`, `NousWidgetData.swift` → target membership: **NOUS Widgets** only.
  - Set the target's **Info.plist** to this folder's `Info.plist` (or merge the `NSExtension` dict).
  - Set **Code Signing Entitlements** to `NOUS Widgets/NOUS_Widgets.entitlements`.
- On the widget target: Signing & Capabilities → **+ App Groups** → `group.com.nous-core.NOUS-0`.
- Deployment targets: iOS 17+ (matches the app). Bundle id e.g. `com.nous-core.NOUS-0.widgets`.

## 3. Build & run
- Run the app once so it writes a snapshot (any capture triggers `WidgetBridge.publish`).
- Add the **NOUS** widget to the Home Screen. Tapping a row deep-links via `nous://atom/<id>` (already handled in `NOUS_0App.onOpenURL`).

## Data flow (already implemented)
`AtomStore.rebuildOrdered()` → `publishWidgetSnapshot()` → `WidgetBridge.publish()` writes
`WidgetSnapshot` JSON to `UserDefaults(suiteName: group.com.nous-core.NOUS-0)` key
`nous.widget.snapshot` + `WidgetCenter.reloadAllTimelines()`. The widget's `NousProvider`
reads that key. Keep `WidgetSnapshot` in `NousWidgetData.swift` in sync with
`WidgetBridge.Snapshot` in the app.

## Notes
- The store moved to the App-Group container (`NousStore.shared`). Existing on-device
  data created before this change lives in the old per-app container; it's not migrated
  (fresh shared store). Add a one-time migration if preserving dev data matters.
- macOS widgets work too (same target can support macOS), but verify on a signed build.
