import WidgetKit
import SwiftUI

// ─── NOUS home-screen widget ──────────────────────────────────────────────────
// Reads the App-Group snapshot the app publishes (WidgetBridge.publish) and shows
// recent atoms + open-task count. Tapping deep-links into the app via nous://atom/<id>.

struct NousEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct NousProvider: TimelineProvider {
    func placeholder(in context: Context) -> NousEntry {
        NousEntry(date: Date(), snapshot: nil)
    }
    func getSnapshot(in context: Context, completion: @escaping (NousEntry) -> Void) {
        completion(NousEntry(date: Date(), snapshot: WidgetData.load()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<NousEntry>) -> Void) {
        let entry = NousEntry(date: Date(), snapshot: WidgetData.load())
        // Refresh roughly every 15 min; the app also pushes reloads on change.
        let next = Date().addingTimeInterval(15 * 60)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

private let inkVoid  = Color(red: 0.04, green: 0.05, blue: 0.06)
private let textPrim = Color(white: 0.95)
private let textDim  = Color(white: 0.55)

struct NousWidgetView: View {
    var entry: NousEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        content
            .containerBackground(inkVoid, for: .widget)
    }

    @ViewBuilder private var content: some View {
        if let snap = entry.snapshot, !snap.recent.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                header(taskCount: snap.openTaskCount)
                ForEach(Array(snap.recent.prefix(family == .systemSmall ? 2 : 4).enumerated()), id: \.offset) { _, item in
                    Link(destination: URL(string: "nous://atom/\(item.id)") ?? URL(string: "nous://")!) {
                        HStack(spacing: 6) {
                            Circle().fill(item.accent).frame(width: 6, height: 6)
                            Text(item.line)
                                .font(.system(size: 12, weight: .regular))
                                .foregroundStyle(textPrim)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
        } else {
            VStack(spacing: 4) {
                Text("nous").font(.system(size: 22, weight: .light, design: .serif)).foregroundStyle(textPrim)
                Text("// tap to capture").font(.system(size: 10, design: .monospaced)).foregroundStyle(textDim)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .widgetURL(URL(string: "nous://"))
        }
    }

    private func header(taskCount: Int) -> some View {
        HStack {
            Text("// recent").font(.system(size: 10, design: .monospaced)).foregroundStyle(textDim)
            Spacer()
            if taskCount > 0 {
                Text("\(taskCount) open").font(.system(size: 10, design: .monospaced)).foregroundStyle(textDim)
            }
        }
    }
}

@main
struct NousWidgets: WidgetBundle {
    var body: some Widget { NousRecentWidget() }
}

struct NousRecentWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NousRecent", provider: NousProvider()) { entry in
            NousWidgetView(entry: entry)
        }
        .configurationDisplayName("NOUS")
        .description("Recent atoms and open tasks.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
