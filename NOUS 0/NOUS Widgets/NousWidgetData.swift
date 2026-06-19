import Foundation

// Mirrors the app's `WidgetBridge.Snapshot` contract. The widget extension is a
// separate target and can't import the app module, so this tiny Codable shape +
// the App-Group key are duplicated here. Keep in sync with WidgetBridge.swift.
struct WidgetSnapshot: Codable {
    struct Item: Codable {
        let id: String
        let line: String
        let type: String
        let due: Date?
    }
    let recent: [Item]
    let openTaskCount: Int
    let updatedAt: Date
}

enum WidgetData {
    static let appGroupID = "group.com.nous-core.NOUS-0"
    static let snapshotKey = "nous.widget.snapshot"

    static func load() -> WidgetSnapshot? {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let data = defaults.data(forKey: snapshotKey) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }
}

/// Phosphor accent per atom type — approximates the app's Tokens.Phos (the widget
/// target can't import the app's design system).
import SwiftUI
extension WidgetSnapshot.Item {
    var accent: Color {
        switch type {
        case "thought":   return Color(red: 0.45, green: 0.80, blue: 0.92) // cyan
        case "task":      return Color(red: 0.55, green: 0.90, blue: 0.55) // green
        case "meeting":   return Color(red: 0.95, green: 0.78, blue: 0.40) // amber
        case "decision":  return Color(red: 0.50, green: 0.62, blue: 0.95) // blue
        case "question":  return Color(red: 0.95, green: 0.58, blue: 0.35) // orange
        case "reference": return Color(red: 0.72, green: 0.55, blue: 0.95) // violet
        default:          return Color(red: 0.45, green: 0.80, blue: 0.92)
        }
    }
}
