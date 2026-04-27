import SwiftUI
import SwiftData
import Accelerate

struct RootView: View {
    @Binding var pendingAtomID: UUID?

    @Environment(\.modelContext) private var ctx

    @Namespace private var atomMorph

    @State private var store: AtomStore?
    @State private var gemini = GeminiClient()
    @State private var supabase = SupabaseClient()
    @State private var backend = NousBackendClient()
    @State private var sync: SyncDaemon?
    @State private var voice = VoiceRecorder()

    @State private var filter: String = ""
    @State private var tagFilter: String? = nil
    @State private var selectedAtom: AtomSnapshot?
    @State private var sheet: Sheet = .none
    @State private var orbMode: OrbMode = .idle
    @State private var undoManager = DeleteUndoManager()
    @State private var pushbackVM: PushbackVM? = nil
    @State private var showPushback = false
    @State private var activeMeetSession: NousBackendClient.ActiveMeetSession? = nil

    // Scroll-aware orb: minimize while user reads, restore when they look up.
    @State private var scrollOffset: CGFloat = 0
    @State private var orbMinimized = false

    @Environment(\.scenePhase) private var scenePhase

    // Voice gesture state
    @State private var voiceStartTime: Date?
    @State private var voiceFingerOffset: CGSize = .zero

    enum Sheet { case none, text, search, tasks, synthesis }

    var body: some View {
        ZStack(alignment: .bottom) {
            NSColorToken.inkVoid.ignoresSafeArea()

            if let store {
                StreamView(
                    store: store,
                    filter: $filter,
                    tagFilter: $tagFilter,
                    selectedAtom: $selectedAtom,
                    morphNS: atomMorph,
                    sync: sync,
                    onDelete: { atom in
                        if selectedAtom?.id == atom.id {
                            withAnimation(.nDrawer) { selectedAtom = nil }
                        }
                        undoManager.scheduleDelete(atom: atom, store: store)
                    },
                    onScrollOffsetChanged: { offset in
                        guard sheet == .none, selectedAtom == nil else { return }
                        let down = offset < scrollOffset - 12
                        let up   = offset > scrollOffset + 8
                        if down && !orbMinimized {
                            withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                                orbMinimized = true
                            }
                        } else if up && orbMinimized {
                            withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                                orbMinimized = false
                            }
                        }
                        scrollOffset = offset
                    }
                )
                .blur(radius: sheet == .none && selectedAtom == nil ? 0 : 8)
                .opacity(sheet == .search || sheet == .tasks || sheet == .synthesis ? 0.0 : 1.0)

                if let a = selectedAtom {
                    AtomDetailView(
                        atom: store.atoms[a.id] ?? a,
                        related: related(for: a.id, store: store),
                        store: store,
                        morphNS: atomMorph,
                        onClose: { withAnimation(.nDrawer) { selectedAtom = nil } },
                        onDelete: { atom in undoManager.scheduleDelete(atom: atom, store: store) },
                        onPickRelated: { picked in
                            withAnimation(.nDrawer) { selectedAtom = picked }
                        }
                    )
                }

                switch sheet {
                case .none: EmptyView()
                case .text:
                    TextCaptureSheet(
                        store: store,
                        onDismiss: { withAnimation(.nDrawer) { sheet = .none; orbMode = .idle } },
                        onSaved: { pulseOrbSaved() }
                    )
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                case .search:
                    SearchSheet(store: store, gemini: gemini, supabase: supabase,
                                onDismiss: { withAnimation(.nDrawer) { sheet = .none; orbMode = .idle } },
                                onPickAtom: { a in
                                    withAnimation(.nDrawer) {
                                        sheet = .none; orbMode = .idle; selectedAtom = a
                                    }
                                },
                                onDelete: { atom in undoManager.scheduleDelete(atom: atom, store: store) })
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
                case .synthesis:
                    SynthesisSheet(
                        store: store,
                        backend: backend,
                        userID: AppEnv.currentUserIDSync,
                        onDismiss: { withAnimation(.nDrawer) { sheet = .none; orbMode = .idle } },
                        onPickAtom: { a in
                            withAnimation(.nDrawer) { sheet = .none; orbMode = .idle; selectedAtom = a }
                        }
                    )
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }

            // Hide orb while AtomDetail is open — surface owns the screen.
            if selectedAtom == nil {
                let shouldMinimize = orbMinimized && orbMode == .idle && sheet == .none
                VStack(spacing: NSpace.sm) {
                    // Pushback badge floats above orb when AI has nudges waiting.
                    if let pvm = pushbackVM, pvm.hasItems, selectedAtom == nil, sheet == .none {
                        PushbackBadge(count: pvm.visibleItems.count) {
                            withAnimation(.nDrawer) { showPushback = true }
                        }
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                    orb
                }
                .padding(.bottom, NSpace.xl)
                // Collapse toward bottom of screen while user reads content.
                // Only shrinks in idle mode — active states always stay full size.
                .scaleEffect(shouldMinimize ? 0.18 : 1.0, anchor: .bottom)
                .opacity(shouldMinimize ? 0.0 : 1.0)
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }

            // Undo toast — floats above orb, appears for 4 seconds after any delete.
            if undoManager.pendingAtom != nil, let store {
                DeleteUndoToast(manager: undoManager, store: store)
                    .padding(.bottom, NSpace.xl + 100)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .zIndex(10)
            }

            // ProfileChip — top-trailing, always visible when no sheet is open.
            if sheet == .none, selectedAtom == nil {
                VStack {
                    HStack {
                        Spacer()
                        ProfileChip(auth: AuthClient.shared)
                            .padding(.trailing, NSpace.xl)
                            .padding(.top, NSpace.lg)
                    }
                    Spacer()
                }
                .ignoresSafeArea(edges: .bottom)
                .transition(.opacity)
                .zIndex(5)
            }

            // MeetCaptureBar — floats at top when Chrome extension is recording.
            if let session = activeMeetSession, sheet == .none, selectedAtom == nil {
                VStack {
                    MeetCaptureBar(session: session)
                        .padding(.top, NSpace.xxl)
                    Spacer()
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
                .zIndex(5)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.78), value: undoManager.pendingAtom?.id)
        .animation(.nDrawer, value: selectedAtom?.id)
        .animation(.nEaseOutQuint, value: pushbackVM?.hasItems)
        .preferredColorScheme(.dark)
        .task { bootstrap() }
        .task { await pollMeetSessions() }
        .onChange(of: pendingAtomID) { _, id in
            guard let id, let store, let atom = store.atoms[id] else { return }
            withAnimation(.nDrawer) { selectedAtom = atom }
            pendingAtomID = nil
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background, let store { undoManager.flush(store: store) }
        }
        .animation(.nDrawer, value: sheet)
        .sheet(isPresented: $showPushback) {
            if let store, let pvm = pushbackVM {
                PushbackSheet(
                    store: store,
                    vm: pvm,
                    onDismiss: { showPushback = false },
                    onPickAtom: { a in showPushback = false; selectedAtom = a }
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(NSColorToken.inkVoid)
            }
        }
    }

    // MARK: Orb + gestures

    private var orb: some View {
        Orb(mode: orbMode, touchPoint: CGPoint(x: 0.5, y: 0.5))
            .frame(width: 200, height: 60)
            .contentShape(Capsule())
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
                // Swipe up → search; swipe right → tasks; swipe left → synthesis
                DragGesture(minimumDistance: 40, coordinateSpace: .local)
                    .onEnded { g in
                        guard !voice.isRecording, orbMode == .idle else { return }
                        let dx = g.translation.width
                        let dy = g.translation.height
                        if dy < -40 && abs(dy) > abs(dx) { openSearch() }
                        else if dx > 40 && abs(dx) > abs(dy) { openTasks() }
                        else if dx < -40 && abs(dx) > abs(dy) { openSynthesis() }
                    }
            )
    }

    /// Brief orb confirmation: textActive → refining → idle. Visual "atom landed" signal.
    private func pulseOrbSaved() {
        withAnimation(.nEaseOutQuint) { orbMode = .refining }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            withAnimation(.nEaseOutQuint) { orbMode = .idle }
        }
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
    private func openSynthesis() {
        Haptics.shared.softTick()
        orbMode = .synthesis
        withAnimation(.nDrawer) { sheet = .synthesis }
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
        let tooShort = voiceStartTime.map { Date().timeIntervalSince($0) < 1.0 } ?? true
        let store = self.store
        Task {
            if cancel || tooShort {
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
        sync.onRemoteEvent = { [weak store] e in store?.applyRemoteEvent(e) }
        sync.bootstrap()
        self.store = store
        self.sync = sync
        let pvm = PushbackVM(backend: backend, userID: AppEnv.currentUserIDSync)
        pvm.refresh()
        self.pushbackVM = pvm
    }

    // MARK: Meet session poll

    private func pollMeetSessions() async {
        guard backend.isConfiguredSync else { return }
        while !Task.isCancelled {
            let uid = AppEnv.currentUserIDSync
            if let sessions = try? await backend.activeMeetSessions(userID: uid) {
                withAnimation(.nEaseOutQuint) {
                    activeMeetSession = sessions.first
                }
            }
            try? await Task.sleep(for: .seconds(30))
        }
    }

    // MARK: Related — semantic via cached EmbeddingRecord, lexical fallback

    private func related(for id: UUID, store: AtomStore) -> [AtomSnapshot] {
        let desc = FetchDescriptor<EmbeddingRecord>()
        let allEmbs = (try? ctx.fetch(desc)) ?? []
        guard let sourceRec = allEmbs.first(where: { $0.atomID == id }) else {
            return lexicalRelated(for: id, store: store)
        }
        let sourceVec = sourceRec.toFloatArray()
        guard !sourceVec.isEmpty else { return lexicalRelated(for: id, store: store) }

        let results = allEmbs.compactMap { rec -> (AtomSnapshot, Float)? in
            guard rec.atomID != id,
                  let atom = store.atoms[rec.atomID],
                  !atom.isDeleted else { return nil }
            let vec = rec.toFloatArray()
            guard vec.count == sourceVec.count else { return nil }
            let sim = cosineSimilarity(sourceVec, vec)
            return sim >= 0.55 ? (atom, sim) : nil
        }
        .sorted { $0.1 > $1.1 }
        .prefix(4)
        .map(\.0)

        return results.isEmpty ? lexicalRelated(for: id, store: store) : Array(results)
    }

    private func lexicalRelated(for id: UUID, store: AtomStore) -> [AtomSnapshot] {
        guard let a = store.atoms[id] else { return [] }
        let candidates = store.ordered.filter { $0.id != id && !$0.isDeleted }
        let wordsA = Set(a.displayContent.lowercased().split(separator: " ").map(String.init))
        let tagsA = Set(a.tags.map(\.value))
        let scored = candidates.map { c -> (AtomSnapshot, Double) in
            var score = 0.0
            if c.type == a.type { score += 0.3 }
            score += Double(tagsA.intersection(Set(c.tags.map(\.value))).count) * 0.4
            let wordsB = Set(c.displayContent.lowercased().split(separator: " ").map(String.init))
            score += Double(wordsA.intersection(wordsB).count) * 0.05
            let dt = abs(a.createdAt.timeIntervalSince(c.createdAt))
            score += max(0, 1.0 - dt / (60 * 60 * 24 * 30)) * 0.1
            return (c, score)
        }
        return scored.filter { $0.1 >= 0.5 }.sorted { $0.1 > $1.1 }.prefix(4).map(\.0)
    }

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        var dot: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        var normA: Float = 0; vDSP_svesq(a, 1, &normA, vDSP_Length(a.count))
        var normB: Float = 0; vDSP_svesq(b, 1, &normB, vDSP_Length(b.count))
        let denom = sqrtf(normA) * sqrtf(normB)
        return denom == 0 ? 0 : dot / denom
    }
}
