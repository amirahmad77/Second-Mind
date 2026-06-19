import SwiftUI

// ─── SettingsView ─────────────────────────────────────────────────────────────
//
// Cross-platform settings surface. On macOS this is hosted in the `Settings`
// scene (⌘, opens it). On iOS the lead wires an entry point (e.g. a row in
// AccountSheet / ProfileChip) that presents this view.
//
// All toggles use `@AppStorage` with the EXACT keys defined in
// `AppEnv.SettingsKey`. A sibling enforcement path reads the same keys, so the
// string literals here are a shared contract — keep them in sync with AppEnv.

struct SettingsView: View {
    @AppStorage("nous.settings.autoRefine")    private var autoRefine = true
    @AppStorage("nous.settings.syncPaused")    private var syncPaused = false
    @AppStorage("nous.settings.notifications") private var notifications = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NSpace.xxl) {
                header

                section(title: "AI") {
                    SettingsToggle(
                        title: "Auto-refine captures",
                        subtitle: "Send new captures to Gemini for cleanup, "
                            + "typing, and tagging as you write.",
                        isOn: $autoRefine
                    )

                    Divider().overlay(NSColorToken.inkMembrane)

                    readonlyRow(label: "REFINE MODEL", value: AppEnv.geminiRefineModel)
                    readonlyRow(label: "SYNTHESIS MODEL", value: AppEnv.geminiSynthesisModel)
                }

                section(title: "Sync") {
                    SettingsToggle(
                        title: "Pause sync",
                        subtitle: "Stop pushing and pulling atoms to the cloud. "
                            + "Captures stay on this device until you resume.",
                        isOn: $syncPaused
                    )
                }

                section(title: "Notifications") {
                    SettingsToggle(
                        title: "Reminders & proactive notifications",
                        subtitle: "Surface due tasks and resurfaced atoms when "
                            + "they matter.",
                        isOn: $notifications
                    )
                }

                section(title: "About") {
                    about
                }
            }
            .padding(NSpace.xxl)
            .frame(maxWidth: 560, alignment: .leading)
        }
        .frame(minWidth: 420, minHeight: 480)
        .background(NSColorToken.inkVoid.ignoresSafeArea())
        .onChange(of: autoRefine) { _, value in
            NousLogger.info("settings", "autoRefine changed", ["value": "\(value)"])
        }
        .onChange(of: syncPaused) { _, value in
            NousLogger.info("settings", "syncPaused changed", ["value": "\(value)"])
        }
        .onChange(of: notifications) { _, value in
            NousLogger.info("settings", "notifications changed", ["value": "\(value)"])
        }
    }

    // MARK: – Header

    private var header: some View {
        VStack(alignment: .leading, spacing: NSpace.xs) {
            Text("SETTINGS")
                .font(NFont.mono(11))
                .tracking(2)
                .foregroundStyle(NSColorToken.textTertiary)
            Text("nous")
                .font(NFont.wordmark(40))
                .foregroundStyle(NSColorToken.textPrimary)
        }
    }

    // MARK: – About block

    private var about: some View {
        VStack(alignment: .leading, spacing: NSpace.sm) {
            HStack {
                Text("nous")
                    .font(NFont.wordmark(28))
                    .foregroundStyle(NSColorToken.textSecondary)
                Spacer()
                Text(versionString)
                    .font(NFont.mono(11))
                    .foregroundStyle(NSColorToken.textGhost)
            }
            Text("Event-sourced thought capture.")
                .font(NFont.body(13))
                .foregroundStyle(NSColorToken.textTertiary)
        }
    }

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "v\(short) (\(build))"
    }

    // MARK: – Section container

    @ViewBuilder
    private func section<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: NSpace.md) {
            Text(title.uppercased())
                .font(NFont.monoSmall(10))
                .tracking(1.5)
                .foregroundStyle(NSColorToken.textGhost)

            VStack(alignment: .leading, spacing: NSpace.lg) {
                content()
            }
            .padding(NSpace.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(NSColorToken.inkPaper)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(NSColorToken.inkMembrane, lineWidth: 1)
            )
        }
    }

    // MARK: – Read-only model row

    private func readonlyRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(NFont.monoSmall(10))
                .tracking(1)
                .foregroundStyle(NSColorToken.textGhost)
            Spacer()
            Text(value)
                .font(NFont.mono(11))
                .foregroundStyle(NSColorToken.textSecondary)
                .textSelection(.enabled)
        }
    }
}

// ─── SettingsToggle ─────────────────────────────────────────────────────────────
//
// A title + explanatory subtitle paired with a tinted toggle. Extracted so each
// section reads cleanly and the toggle styling stays consistent.

private struct SettingsToggle: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: NSpace.lg) {
            VStack(alignment: .leading, spacing: NSpace.xs) {
                Text(title)
                    .font(NFont.body(14))
                    .foregroundStyle(NSColorToken.textPrimary)
                Text(subtitle)
                    .font(NFont.body(12))
                    .foregroundStyle(NSColorToken.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: NSpace.md)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(NSColorToken.Phos.cyan)
        }
    }
}

#Preview {
    SettingsView()
}
