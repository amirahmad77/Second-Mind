import SwiftUI
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

struct RootView: View {
    @Binding var pendingAtomID: UUID?

    @Environment(\.modelContext) private var ctx

    @Namespace private var atomMorph

    @AppStorage("nous.hasSeenOnboarding") private var hasSeenOnboarding = false
    @State private var store: AtomStore?
    @State private var gemini = GeminiClient()
    @State private var supabase = SupabaseClient()
    @State private var backend = NousBackendClient()
    @State private var sync: SyncDaemon?
    @State private var voice = VoiceRecorder()

    @State private var filter: String = ""
    @State private var tagFilter: String? = nil
    @State private var selectedAtom: AtomSnapshot?
    @State private var relatedAtoms: [AtomSnapshot] = []
    @State private var sheet: Sheet = .none
    @State private var orbMode: OrbMode = .idle
    @State private var undoManager = DeleteUndoManager()
    @State private var pushbackVM: PushbackVM? = nil
    @State private var showPushback = false
    @State private var showCompose = false
    @State private var activeMeetSession: NousBackendClient.ActiveMeetSession? = nil

    // Scroll-aware orb: minimize while user reads, restore when they look up.
    @State private var scrollOffset: CGFloat = 0
    @State private var orbMinimized = false

    @Environment(\.scenePhase) private var scenePhase

    // Voice gesture state
    @State private var voiceStartTime: Date?
    @State private var voiceFingerOffset: CGSize = .zero

    // Capture-landed bloom: brief type-colored flash when a capture lands.
    @State private var captureBloom = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                        related: relatedAtoms,
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
                        onSaved: { pulseOrbSaved() },
                        onOpenAtom: { a in
                            withAnimation(.nDrawer) { sheet = .none; orbMode = .idle; selectedAtom = a }
                        }
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
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
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
                        gemini: gemini,
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
                        ProfileChip(auth: AuthClient.shared, store: store)
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
        .overlay {
            if !hasSeenOnboarding {
                OnboardingOverlay { hasSeenOnboarding = true }
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .top) {
            if let sync {
                SyncTroubleBadge(count: sync.quarantinedCount) { sync.retryQuarantined() }
                    .padding(.top, NSpace.sm)
                    .animation(.nEaseOutQuint, value: sync.quarantinedCount)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.78), value: undoManager.pendingAtom?.id)
        .animation(.nDrawer, value: selectedAtom?.id)
        .animation(.nEaseOutQuint, value: pushbackVM?.hasItems)
        .preferredColorScheme(.dark)
        .task { bootstrap() }
        .task { await pollMeetSessions() }
        // Compute related atoms off the MainActor whenever the open atom changes.
        // Runs on appear, so AtomDetailView gets a valid array shortly after open.
        .task(id: selectedAtom?.id) {
            if let a = selectedAtom, let store {
                relatedAtoms = await RelatedFinder.related(for: a.id, store: store, context: ctx)
            } else {
                relatedAtoms = []
            }
        }
        .onChange(of: pendingAtomID) { _, id in
            guard let id, let store, let atom = store.atoms[id] else { return }
            withAnimation(.nDrawer) { selectedAtom = atom }
            pendingAtomID = nil
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background, let store { undoManager.flush(store: store) }
            // Pull immediately when the app returns to foreground so data from
            // other devices appears without waiting for the 30s periodic poll.
            if phase == .active { sync?.pullNow() }
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
        // Compose-from-atoms. AccountSheet posts .nousOpenCompose; macOS handled it
        // but iOS never listened, leaving the "compose" button dead. Now wired.
        .onReceive(NotificationCenter.default.publisher(for: .nousOpenCompose)) { _ in
            showCompose = true
        }
        .sheet(isPresented: $showCompose) {
            if let store {
                let composeUserID = AuthClient.shared.session?.userID ?? AppEnv.localUserID
                ComposeSheet(
                    store: store,
                    backend: backend,
                    userID: composeUserID,
                    onDismiss: { showCompose = false },
                    onPickAtom: { a in
                        showCompose = false
                        withAnimation(.nDrawer) { selectedAtom = a }
                    }
                )
                .presentationBackground(NSColorToken.inkVoid)
            }
        }
    }

    // MARK: Orb + gestures

    /// True when ≥1 live atom is refining in the background. Drives the orb's
    /// ambient heartbeat so the signature object doubles as a status readout.
    private var isRefiningAny: Bool {
        guard let store else { return false }
        return store.atoms.values.contains { $0.isRefining && !$0.isDeleted }
    }

    private var orb: some View {
        Orb(mode: orbMode,
            touchPoint: CGPoint(x: 0.5, y: 0.5),
            ambientRefining: isRefiningAny)
            .frame(width: 200, height: 60)
            // Capture-landed bloom: a quick phosphor flash behind the pill when
            // a note lands. Cyan = .thought (capture's default type). Subtle,
            // additive, fully transparent at rest. Skipped under reduce-motion.
            .background(captureBloomOverlay)
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
            .accessibilityLabel(orbAccessibilityLabel)
            .accessibilityHint("Double-tap to write. Touch and hold to record voice.")
            .accessibilityAction(named: "Write note") { openText() }
            .accessibilityAction(named: "Search") { openSearch() }
            .accessibilityAction(named: "Tasks") { openTasks() }
            .accessibilityAction(named: "Synthesis") { openSynthesis() }
            // Voice via long-press-drag is unusable for VoiceOver / Switch Control.
            // Provide a gesture-free toggle: activate to record, activate again to
            // stop and save.
            .accessibilityAction(named: voice.isRecording ? "Stop and save voice note" : "Record voice note") {
                accessibleVoiceToggle()
            }
    }

    /// Gesture-free voice capture for assistive tech. Mirrors the gesture path's
    /// stop→capture behavior without requiring long-press-and-drag.
    private func accessibleVoiceToggle() {
        if voice.isRecording {
            Task {
                let transcript = await voice.stop()
                await MainActor.run {
                    let t = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty {
                        _ = store?.capture(raw: t, type: .thought)
                        Haptics.shared.saveConfirm()
                    }
                    orbMode = .idle
                    announce(t.isEmpty ? "Discarded empty recording" : "Voice note saved")
                }
            }
        } else {
            Task {
                await voice.start()
                await MainActor.run {
                    orbMode = .voice(amp: 0)
                    announce("Recording. Activate the orb again to stop and save.")
                }
            }
        }
    }

    /// Post a VoiceOver announcement (iOS only).
    private func announce(_ message: String) {
        #if os(iOS)
        UIAccessibility.post(notification: .announcement, argument: message)
        #endif
    }

    private var orbAccessibilityLabel: String {
        switch orbMode {
        case .idle:              return "NOUS orb"
        case .voice(_):          return "Recording voice"
        case .voiceCancelZone:   return "Release to cancel recording"
        case .textActive:        return "Writing note"
        case .refining:          return "Saving"
        case .search:            return "Searching"
        case .synthesis:         return "Synthesis"
        }
    }

    /// Phosphor bloom that flashes behind the orb the instant a capture lands,
    /// then fades. Cyan matches `.thought`, capture's default type. Sits at rest
    /// fully transparent so it never affects layout or the idle look.
    @ViewBuilder
    private var captureBloomOverlay: some View {
        Capsule()
            .fill(NSColorToken.Phos.cyan.opacity(captureBloom ? 0.35 : 0.0))
            .blur(radius: 18)
            .scaleEffect(captureBloom ? 1.12 : 0.96)
            .allowsHitTesting(false)
    }

    /// Brief orb confirmation: textActive → refining → idle. Visual "atom landed" signal.
    /// Adds a quick type-colored bloom so the capture visibly "lands" before the
    /// refining state takes over — on the existing 1.1s timing.
    private func pulseOrbSaved() {
        withAnimation(.nEaseOutQuint) { orbMode = .refining }
        // Bloom in fast, then ease back out — a single flash, not a pulse.
        // Reduce-motion: skip the animated bloom entirely (refining state alone
        // carries the confirmation).
        if !reduceMotion {
            withAnimation(.nPress) { captureBloom = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                withAnimation(.nEaseOutQuint) { captureBloom = false }
            }
        }
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
        // Fetch API keys from the Supabase edge function post-auth. macOS does this
        // in MacRootView.bootstrap(); iOS was missing it, so production keys
        // (which live in RemoteConfig, not the compile-time fallback) never loaded.
        Task { await RemoteConfig.shared.fetch() }
        let sync = SyncDaemon(context: ctx, supabase: supabase, gemini: gemini)
        let store = AtomStore(context: ctx, sync: sync, gemini: gemini, backend: backend)
        store.bootstrap()
        sync.onRemoteEvent = { [weak store] e in store?.applyRemoteEvent(e) }
        sync.bootstrap()
        self.store = store
        self.sync = sync
        let pvm = PushbackVM(backend: backend, userID: AppEnv.currentUserIDSync)
        pvm.refresh()
        self.pushbackVM = pvm

        // Consume a pending "Capture to NOUS" App Intent (iOS surfacing path).
        // The intent stashed the text; NOUS_0App.drain() moved it here. Capture
        // it directly — a capture shortcut should save, not just open a sheet.
        if let pending = NousIntentInbox.lastPendingCapture?.trimmingCharacters(in: .whitespacesAndNewlines),
           !pending.isEmpty {
            _ = store.capture(raw: pending, type: .thought)
            NousIntentInbox.lastPendingCapture = nil
        }
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
}
