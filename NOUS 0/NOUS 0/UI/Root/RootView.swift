import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(\.modelContext) private var ctx

    @Namespace private var atomMorph

    @State private var store: AtomStore?
    @State private var gemini = GeminiClient()
    @State private var supabase = SupabaseClient()
    @State private var sync: SyncDaemon?
    @State private var voice = VoiceRecorder()

    @State private var filter: String = ""
    @State private var selectedAtom: AtomSnapshot?
    @State private var sheet: Sheet = .none
    @State private var orbMode: OrbMode = .idle

    // Voice gesture state
    @State private var voiceStartTime: Date?
    @State private var voiceFingerOffset: CGSize = .zero

    enum Sheet { case none, text, search, tasks }

    var body: some View {
        ZStack(alignment: .bottom) {
            NSColorToken.inkVoid.ignoresSafeArea()

            if let store {
                StreamView(store: store, filter: $filter, selectedAtom: $selectedAtom, morphNS: atomMorph)
                    .blur(radius: sheet == .none && selectedAtom == nil ? 0 : 8)
                    .opacity(sheet == .search || sheet == .tasks ? 0.0 : 1.0)

                if let a = selectedAtom {
                    AtomDetailView(
                        atom: store.atoms[a.id] ?? a,
                        related: related(for: a.id, store: store),
                        store: store,
                        morphNS: atomMorph,
                        onClose: { withAnimation(.nDrawer) { selectedAtom = nil } }
                    )
                }

                switch sheet {
                case .none: EmptyView()
                case .text:
                    TextCaptureSheet(store: store) { withAnimation(.nDrawer) { sheet = .none; orbMode = .idle } }
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                case .search:
                    SearchSheet(store: store, gemini: gemini, supabase: supabase,
                                onDismiss: { withAnimation(.nDrawer) { sheet = .none; orbMode = .idle } },
                                onPickAtom: { a in
                                    withAnimation(.nDrawer) {
                                        sheet = .none; orbMode = .idle; selectedAtom = a
                                    }
                                })
                        .transition(.opacity)
                case .tasks:
                    TasksSheet(store: store,
                               onDismiss: { withAnimation(.nDrawer) { sheet = .none; orbMode = .idle } },
                               onPickAtom: { a in
                                   withAnimation(.nDrawer) {
                                       sheet = .none; orbMode = .idle; selectedAtom = a
                                   }
                               })
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }

            // Hide orb while AtomDetail is open — surface owns the screen.
            if selectedAtom == nil {
                orb
                    .padding(.bottom, NSpace.xl)
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
        .animation(.nDrawer, value: selectedAtom?.id)
        .preferredColorScheme(.dark)
        .task { bootstrap() }
        .animation(.nDrawer, value: sheet)
    }

    // MARK: Orb + gestures

    private var orb: some View {
        Orb(mode: orbMode, touchPoint: CGPoint(x: 0.5, y: 0.5))
            .frame(width: 120, height: 120)
            .contentShape(Circle())
            .gesture(
                // Long press → voice
                LongPressGesture(minimumDuration: 0.22)
                    .sequenced(before: DragGesture(minimumDistance: 0))
                    .onChanged { val in
                        if case .second(true, let drag?) = val {
                            handleVoiceChanged(drag)
                        }
                    }
                    .onEnded { val in
                        if case .second(true, let drag?) = val {
                            handleVoiceEnded(drag)
                        }
                    }
            )
            .simultaneousGesture(
                TapGesture().onEnded { openText() }
            )
            .simultaneousGesture(
                // Swipe up → search; swipe L/R → tasks
                DragGesture(minimumDistance: 40, coordinateSpace: .local)
                    .onEnded { g in
                        guard voice.isRecording == false, orbMode == .idle else { return }
                        let dx = g.translation.width
                        let dy = g.translation.height
                        if dy < -40 && abs(dy) > abs(dx) { openSearch() }
                        else if abs(dx) > 40 && abs(dx) > abs(dy) { openTasks() }
                    }
            )
    }

    private func openText() {
        guard sheet == .none, !voice.isRecording else { return }
        Haptics.shared.tap()
        orbMode = .textActive
        withAnimation(.nDrawer) { sheet = .text }
    }
    private func openSearch() {
        Haptics.shared.softTick()
        orbMode = .search
        withAnimation(.nDrawer) { sheet = .search }
    }
    private func openTasks() {
        Haptics.shared.softTick()
        withAnimation(.nDrawer) { sheet = .tasks }
    }

    // MARK: Voice gesture

    private func handleVoiceChanged(_ drag: DragGesture.Value) {
        if !voice.isRecording {
            Task { await voice.start() }
            voiceStartTime = Date()
            Haptics.shared.heavyThud()
            Haptics.shared.startContinuous()
            orbMode = .voice(amp: 0)
        }
        voiceFingerOffset = drag.translation
        // Drag up off orb → cancel zone
        if drag.translation.height < -80 {
            orbMode = .voiceCancelZone
        } else {
            orbMode = .voice(amp: voice.amp)
            Haptics.shared.updateContinuous(amp: voice.amp)
        }
    }

    private func handleVoiceEnded(_ drag: DragGesture.Value) {
        Haptics.shared.stopContinuous()
        let cancel = drag.translation.height < -80
        let store = self.store
        Task {
            if cancel {
                voice.cancel()
                await MainActor.run {
                    Haptics.shared.cancelCrash()
                    orbMode = .idle
                }
            } else {
                let transcript = await voice.stop()
                await MainActor.run {
                    let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        _ = store?.capture(raw: trimmed, type: .thought)
                        Haptics.shared.saveConfirm()
                    }
                    orbMode = .idle
                }
            }
        }
    }

    // MARK: Bootstrap

    private func bootstrap() {
        guard store == nil else { return }
        let sync = SyncDaemon(context: ctx, supabase: supabase, gemini: gemini)
        let store = AtomStore(context: ctx, sync: sync, gemini: gemini)
        store.bootstrap()
        sync.bootstrap()
        self.store = store
        self.sync = sync
    }

    // MARK: Related (v1 naive — share any tag OR same type + recent)
    private func related(for id: UUID, store: AtomStore) -> [AtomSnapshot] {
        guard let a = store.atoms[id] else { return [] }
        let candidates = store.ordered.filter { $0.id != id && !$0.isDeleted }
        let scored = candidates.map { c -> (AtomSnapshot, Double) in
            var score = 0.0
            if c.type == a.type { score += 0.3 }
            let tagsA = Set(a.tags.map(\.value)); let tagsB = Set(c.tags.map(\.value))
            score += Double(tagsA.intersection(tagsB).count) * 0.4
            // Lexical overlap
            let wordsA = Set(a.displayContent.lowercased().split(separator: " ").map(String.init))
            let wordsB = Set(c.displayContent.lowercased().split(separator: " ").map(String.init))
            score += Double(wordsA.intersection(wordsB).count) * 0.05
            // Recency boost
            let dt = abs(a.createdAt.timeIntervalSince(c.createdAt))
            score += max(0, 1.0 - dt / (60*60*24*30)) * 0.1
            return (c, score)
        }
        return scored.filter { $0.1 > 0.2 }.sorted { $0.1 > $1.1 }.prefix(6).map(\.0)
    }
}
