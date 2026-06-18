#if os(macOS)
import SwiftUI
import SwiftData

// ─── MacRootView ─────────────────────────────────────────────────────────────
//
// Three-column NavigationSplitView: sidebar → list → detail.
// Owns all shared state: store, clients, selection, active panel.
//
// Column widths:
//   Sidebar  : 200 pt (fixed)
//   List     : 280 pt min, 380 max
//   Detail   : flexible remainder
//
// Keyboard contract:
//   ⌘N          → open capture panel
//   ⌘F          → focus search
//   ⌘K          → command palette (future)
//   ⌘⌫          → delete selected atom
//   ↑ / ↓       → navigate list (handled by List natively)
//   Esc         → deselect / close detail

@MainActor
struct MacRootView: View {

    @Environment(\.modelContext) private var ctx
    @Environment(\.scenePhase) private var scenePhase

    // Clients
    @State private var store: AtomStore?
    @State private var gemini    = GeminiClient()
    @State private var supabase  = SupabaseClient()
    @State private var backend   = NousBackendClient()
    @State private var sync: SyncDaemon?

    // Navigation
    @State private var sidebarSelection: MacSidebarItem = .stream
    @State private var selectedAtomID: UUID?
    @State private var relatedAtoms: [AtomSnapshot] = []

    // Search
    @State private var searchText: String = ""

    // Capture panel
    @State private var showCapture = false

    // Compose sheet
    @State private var showCompose = false

    // Meet session (Chrome extension — polled from backend)
    @State private var activeMeetSession: NousBackendClient.ActiveMeetSession?

    // In-app meeting recorder (Granola-style) + Chrome extension bridge
    @State private var meetBridge      = MeetBridgeServer()
    @State private var meetRecorder    = MacMeetingRecorder()
    /// Maps meeting session ID → atom UUID so reconnections update the same atom.
    @State private var meetingAtomIDs: [String: UUID] = [:]
    @State private var calendarService = CalendarService()
    @State private var detector        = MeetingDetector()
    @State private var showMeetSetup   = false
    @State private var meetAttendees   = ""   // pre-filled from calendar or typed manually
    // Detection banner
    @State private var showDetectionBanner     = false
    @State private var dismissedDetectionTitle = ""  // suppress re-showing same meeting
    @State private var showRecordingError      = false

    // Undo
    @State private var undoManager = DeleteUndoManager()

    var body: some View {
        Group {
            if let store {
                splitViewWithSheets(store: store)
                    .meetingOverlays(
                        recorder:      meetRecorder,
                        bridge:        meetBridge,
                        detector:      detector,
                        calendar:      calendarService,
                        showBanner:    $showDetectionBanner,
                        dismissedTitle: $dismissedDetectionTitle,
                        meetAttendees: $meetAttendees,
                        showSetup:     $showMeetSetup,
                        showError:     $showRecordingError,
                        onStop:        { stopMeetingRecording(store: store) },
                        onCancel:      { meetRecorder.cancel() }
                    )
                    .overlay(alignment: .bottom) {
                        VStack(spacing: NSpace.sm) {
                            if let session = activeMeetSession {
                                MeetCaptureBar(session: session)
                                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                            }
                            if undoManager.pendingAtom != nil {
                                DeleteUndoToast(manager: undoManager, store: store)
                                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                            }
                        }
                        .padding(.bottom, NSpace.xl)
                    }
                    .onDeleteCommand {
                        guard let id = selectedAtomID,
                              let atom = store.atoms[id] else { return }
                        undoManager.scheduleDelete(atom: atom, store: store)
                        selectedAtomID = nil
                    }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(NSColorToken.inkVoid)
            }
        }
        .animation(.nDrawer, value: undoManager.pendingAtom?.id)
        .animation(.nDrawer, value: activeMeetSession?.id)
        .animation(.nDrawer, value: meetRecorder.isRecording)
        .animation(.nDrawer, value: showDetectionBanner)
        .preferredColorScheme(.dark)
        .task { bootstrap() }
        // Compute related atoms off the MainActor whenever the selected atom
        // changes. Runs on appear, so MacAtomDetail gets a valid array on open.
        .task(id: selectedAtomID) {
            if let id = selectedAtomID, let store {
                relatedAtoms = await RelatedFinder.related(for: id, store: store, context: ctx)
            } else {
                relatedAtoms = []
            }
        }
        // Commit any pending delete before the app suspends or quits, so a delete
        // staged within the undo window isn't silently abandoned. Mirrors iOS RootView.
        // macOS quit reliably hits .inactive before .background, so flush on both.
        .onChange(of: scenePhase) { _, phase in
            if phase == .background || phase == .inactive, let store {
                undoManager.flush(store: store)
            }
        }
        // Auto-trigger: show banner when a meeting window appears (window detector)
        .onChange(of: detector.detected) { _, newMeeting in
            guard let mtg = newMeeting,
                  !meetRecorder.isRecording,
                  mtg.title != dismissedDetectionTitle else { return }
            showDetectionBanner = true
        }
        // Clear banner when meeting disappears
        .onChange(of: detector.detected) { _, newMeeting in
            if newMeeting == nil && meetBridge.participants.isEmpty {
                showDetectionBanner = false
            }
        }
        // Auto-start recording when Chrome extension reports participants.
        // Primary path for Google Meet — no banner interaction needed.
        // User can cancel via the live panel if they don't want to record.
        .onChange(of: meetBridge.participants) { _, names in
            guard !names.isEmpty, !meetRecorder.isRecording else { return }
            let attendees = names.joined(separator: ", ")
            Task { await meetRecorder.start(attendees: attendees) }
        }
        // Stop recording when meeting ends (all participants gone)
        .onChange(of: meetBridge.participants) { _, names in
            guard names.isEmpty, meetRecorder.isRecording else { return }
            Task {
                guard let store else { return }
                stopMeetingRecording(store: store)
            }
        }
        // Global ⌘N capture
        .keyboardShortcut("n", modifiers: .command)
        .onReceive(NotificationCenter.default.publisher(for: .nousOpenCapture)) { _ in
            showCapture = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .nousOpenCompose)) { _ in
            showCompose = true
        }
        // Pull immediately when the Mac app gains focus so data from other devices
        // appears without waiting for the 30s periodic poll.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            sync?.pullNow()
        }
        .task(id: store?.ordered.count) {
            await pollMeetSessions()
        }
    }

    // MARK: – Meeting recording

    private func stopMeetingRecording(store: AtomStore) {
        Task { @MainActor in
            await _stopMeetingRecording(store: store)
        }
    }

    private func _stopMeetingRecording(store: AtomStore) async {
        let sessionID  = meetRecorder.meetingSessionID
        let transcript = await meetRecorder.stop()
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // Surface to the user — a silent no-op here leaves them with no feedback.
            meetRecorder.lastError = "No speech detected — transcript was empty. Check Deepgram API key or microphone permissions."
            NousLogger.warning("meet", "empty transcript — no atom created")
            return
        }

        // If we already have an atom for this session (reconnect), update it.
        if !sessionID.isEmpty, let existingID = meetingAtomIDs[sessionID] {
            store.updateRaw(id: existingID, newContent: transcript)
            withAnimation(.nDrawer) { selectedAtomID = existingID }
            NousLogger.info("meet", "meeting atom updated (reconnect)",
                            ["id": existingID.uuidString, "sessionID": sessionID])
            return
        }

        // New session — capture() auto-refines via Gemini into structured notes.
        let atom = store.capture(raw: transcript, type: .meeting)
        if let atom {
            if !sessionID.isEmpty { meetingAtomIDs[sessionID] = atom.id }
            withAnimation(.nDrawer) { selectedAtomID = atom.id }
        }
        NousLogger.info("meet", "meeting atom created",
                        ["id": atom?.id.uuidString ?? "nil", "sessionID": sessionID])
    }

    // MARK: – Meet polling

    private func pollMeetSessions() async {
        guard let userID = AuthClient.shared.session?.userID else { return }
        while !Task.isCancelled {
            if let sessions = try? await backend.activeMeetSessions(userID: userID) {
                withAnimation(.nDrawer) { activeMeetSession = sessions.first }
            }
            try? await Task.sleep(for: .seconds(15))
        }
    }

    // MARK: – Content column

    @ViewBuilder
    private func contentColumn(store: AtomStore) -> some View {
        switch sidebarSelection {
        case .stream, .type:
            MacAtomList(
                store: store,
                filter: sidebarFilter,
                searchText: $searchText,
                selectedAtomID: $selectedAtomID,
                onDelete: { atom in undoManager.scheduleDelete(atom: atom, store: store) }
            )
        case .search:
            MacSearchView(store: store, backend: backend, gemini: gemini, supabase: supabase) { atom in
                sidebarSelection = .stream
                selectedAtomID = atom.id
            }
        case .tasks:
            MacAtomList(
                store: store,
                filter: .taskOnly,
                searchText: $searchText,
                selectedAtomID: $selectedAtomID,
                onDelete: { atom in undoManager.scheduleDelete(atom: atom, store: store) }
            )
        case .synthesis:
            // Synthesis lives in detail — show placeholder here
            ContentUnavailableView(
                "// synthesize",
                systemImage: "sparkles",
                description: Text("Ask a question in the detail panel →")
            )
            .foregroundStyle(NSColorToken.textGhost)
        }
    }

    // MARK: – Detail column

    @ViewBuilder
    private func detailColumn(store: AtomStore) -> some View {
        if sidebarSelection == .synthesis {
            MacSynthesisView(store: store, backend: backend, gemini: gemini)
        } else if let id = selectedAtomID, let atom = store.atoms[id] {
            MacAtomDetail(
                atom: atom,
                related: relatedAtoms,
                store: store,
                onClose: { withAnimation(.nDrawer) { selectedAtomID = nil } },
                onDelete: { a in
                    undoManager.scheduleDelete(atom: a, store: store)
                    selectedAtomID = nil
                },
                onPickRelated: { a in selectedAtomID = a.id }
            )
        } else {
            MacEmptyDetail()
        }
    }

    // MARK: – Toolbar

    @ToolbarContentBuilder
    private func macToolbar(store: AtomStore) -> some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                showCapture = true
            } label: {
                Label("New capture", systemImage: "plus")
            }
            .keyboardShortcut("n", modifiers: .command)
            .help("New capture (⌘N)")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                sidebarSelection = .synthesis
            } label: {
                Label("Synthesize", systemImage: "sparkles")
            }
            .help("Open synthesis (⌘⌥S)")
            .keyboardShortcut("s", modifiers: [.command, .option])
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                showCompose = true
            } label: {
                Label("Compose", systemImage: "pencil.and.scribble")
            }
            .help("Compose from atoms (⌘⌥C)")
            .keyboardShortcut("c", modifiers: [.command, .option])
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                if meetRecorder.isRecording {
                    Task { stopMeetingRecording(store: store) }
                } else {
                    showMeetSetup = true
                }
            } label: {
                Label(
                    meetRecorder.isRecording ? "Stop Meeting" : "Record Meeting",
                    systemImage: meetRecorder.isRecording ? "stop.circle.fill" : "mic.circle"
                )
                .foregroundStyle(meetRecorder.isRecording ? Color.orange : Color.primary)
            }
            .help(meetRecorder.isRecording
                  ? "Stop meeting recording (⌘⌥M)"
                  : "Record meeting — captures mic + call audio (⌘⌥M)")
            .keyboardShortcut("m", modifiers: [.command, .option])
        }
    }

    // MARK: – Sidebar filter

    private var sidebarFilter: MacAtomListFilter {
        switch sidebarSelection {
        case .stream:         return .all
        case .tasks:          return .taskOnly
        case .type(let t):    return .type(t)
        default:              return .all
        }
    }

    // MARK: – Bootstrap

    private func bootstrap() {
        guard store == nil else { return }
        Task { await RemoteConfig.shared.fetch() }
        let sync = SyncDaemon(context: ctx, supabase: supabase, gemini: gemini)
        let store = AtomStore(context: ctx, sync: sync, gemini: gemini, backend: backend)
        store.bootstrap()
        sync.onRemoteEvent = { [weak store] e in store?.applyRemoteEvent(e) }
        sync.bootstrap()
        self.store = store
        self.sync  = sync
        NousLogger.info("mac", "bootstrap complete")
        // Calendar access — request early so permission prompt isn't at recording time
        Task { await calendarService.activate() }
        // Meeting detector — start polling window titles for Meet/Zoom/Teams
        detector.start()
        // Chrome extension bridge — localhost:9988 WebSocket server
        meetBridge.start()
        // Wire bridge → recorder so it can auto-populate attendee names
        meetRecorder.bridge = meetBridge
    }
}

// MARK: – Split-view + sheets helper

extension MacRootView {
    @ViewBuilder
    func splitViewWithSheets(store: AtomStore) -> some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            MacSidebar(selection: $sidebarSelection, store: store)
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } content: {
            contentColumn(store: store)
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 420)
        } detail: {
            detailColumn(store: store)
        }
        .navigationTitle("")
        .toolbar { macToolbar(store: store) }
        .sheet(isPresented: $showCapture) {
            MacCapturePanel(store: store) { showCapture = false }
        }
        .sheet(isPresented: $showCompose) {
            let userID = AuthClient.shared.session?.userID ?? AppEnv.localUserID
            ComposeSheet(
                store: store, backend: backend, userID: userID,
                onDismiss: { showCompose = false },
                onPickAtom: { a in selectedAtomID = a.id; showCompose = false }
            )
        }
        .sheet(isPresented: $showMeetSetup) {
            MeetingSetupSheet(attendees: $meetAttendees, calendar: calendarService) {
                showMeetSetup = false
                Task { await meetRecorder.start(attendees: meetAttendees) }
            } onCancel: {
                showMeetSetup = false
            }
        }
    }
}

// MARK: – Meeting overlays (extracted to keep body type-checkable)

private struct MeetingOverlaysModifier: ViewModifier {
    let recorder:       MacMeetingRecorder
    let bridge:         MeetBridgeServer
    let detector:       MeetingDetector
    let calendar:       CalendarService
    @Binding var showBanner:      Bool
    @Binding var dismissedTitle:  String
    @Binding var meetAttendees:   String
    @Binding var showSetup:       Bool
    @Binding var showError:       Bool
    let onStop:   () -> Void
    let onCancel: () -> Void

    // Resolves a meeting to display in the banner.
    // Prefers what the window detector found; falls back to a synthetic
    // Google Meet entry when the Chrome extension reports participants but
    // the window title scanner missed the tab (common for Chrome SPAs).
    private var bannerMeeting: MeetingDetector.DetectedMeeting? {
        if let m = detector.detected { return m }
        if !bridge.participants.isEmpty {
            return MeetingDetector.DetectedMeeting(
                platform: .googleMeet,
                title:    "Google Meet",
                appName:  "Google Chrome"
            )
        }
        return nil
    }

    func body(content: Content) -> some View {
        content
            // Detection banner — top-right
            .overlay(alignment: .topTrailing) {
                if showBanner, let mtg = bannerMeeting, !recorder.isRecording {
                    MeetDetectionBanner(meeting: mtg) {
                        if let cal = calendar.currentMeeting, !cal.attendeesString.isEmpty {
                            meetAttendees = cal.attendeesString
                        } else if !bridge.participants.isEmpty {
                            meetAttendees = bridge.participants.joined(separator: ", ")
                        }
                        showBanner = false
                        Task { await recorder.start(attendees: meetAttendees) }
                    } onSetup: {
                        showBanner = false
                        showSetup  = true
                    } onDismiss: {
                        dismissedTitle = mtg.title
                        showBanner = false
                    }
                    .padding(.top, 48)
                    .padding(.trailing, NSpace.lg)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .zIndex(10)
                }
            }
            // Error alert
            .alert("Recording Failed", isPresented: $showError) {
                Button("OK") { }
            } message: {
                Text(recorder.lastError ?? "")
            }
            .onChange(of: recorder.lastError) { _, err in
                if err != nil { showError = true }
            }
            // Live panel — bottom-right
            .overlay(alignment: .bottomTrailing) {
                if recorder.isRecording {
                    MacLiveRecordPanel(recorder: recorder, detected: detector.detected,
                                       bridge: bridge, onStop: onStop, onCancel: onCancel)
                        .padding(.bottom, NSpace.xl)
                        .padding(.trailing, NSpace.lg)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                        .zIndex(9)
                }
            }
    }
}

private extension View {
    func meetingOverlays(
        recorder:       MacMeetingRecorder,
        bridge:         MeetBridgeServer,
        detector:       MeetingDetector,
        calendar:       CalendarService,
        showBanner:     Binding<Bool>,
        dismissedTitle: Binding<String>,
        meetAttendees:  Binding<String>,
        showSetup:      Binding<Bool>,
        showError:      Binding<Bool>,
        onStop:  @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) -> some View {
        modifier(MeetingOverlaysModifier(
            recorder:      recorder,
            bridge:        bridge,
            detector:      detector,
            calendar:      calendar,
            showBanner:    showBanner,
            dismissedTitle: dismissedTitle,
            meetAttendees: meetAttendees,
            showSetup:     showSetup,
            showError:     showError,
            onStop:        onStop,
            onCancel:      onCancel
        ))
    }
}

// MARK: – Empty detail placeholder

private struct MacEmptyDetail: View {
    var body: some View {
        VStack(spacing: NSpace.md) {
            Text("// select an atom")
                .font(NFont.mono(13))
                .foregroundStyle(NSColorToken.textGhost)
            Text("or press ⌘N to capture a new thought")
                .font(NFont.mono(11))
                .foregroundStyle(NSColorToken.textGhost.opacity(0.55))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NSColorToken.inkVoid)
    }
}

// MARK: – Notification name

extension Notification.Name {
    static let nousOpenCapture = Notification.Name("nous.openCapture")
}

// MARK: – MeetingSetupSheet

/// Shown before recording starts.
///
/// Calendar auto-detection:
///   If the user has granted calendar access and there is a current or imminent
///   event, its title and attendee names are pre-filled automatically — zero
///   typing required. The user can edit the names before starting.
///
/// Manual override:
///   If no event is detected (or calendar access is denied), the user types
///   attendee names manually (comma-separated).
///
/// If the attendees field is left empty, Gemini falls back to generic
/// "Speaker 1:", "Speaker 2:" labels which can be renamed post-meeting via
/// SpeakerRelabelPanel in the atom detail view.
private struct MeetingSetupSheet: View {
    @Binding var attendees: String
    let calendar:  CalendarService
    let onStart:   () -> Void
    let onCancel:  () -> Void

    @State private var detectedTitle: String?
    @State private var calendarLoaded = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Header ────────────────────────────────────────────────────────
            VStack(alignment: .leading, spacing: NSpace.xs) {
                Text("// record meeting")
                    .font(NFont.mono(10))
                    .tracking(2)
                    .foregroundStyle(NSColorToken.textGhost)
                Text("Who's in this meeting?")
                    .font(NFont.body(17))
                    .foregroundStyle(NSColorToken.textPrimary)
            }
            .padding(NSpace.xl)

            // ── Detected event banner ─────────────────────────────────────────
            if let title = detectedTitle {
                HStack(spacing: NSpace.sm) {
                    Circle()
                        .fill(NSColorToken.Phos.cyan)
                        .frame(width: 5, height: 5)
                    Text("// detected: \(title)")
                        .font(NFont.mono(10))
                        .foregroundStyle(NSColorToken.Phos.cyan.opacity(0.8))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    if let mtg = calendar.currentMeeting {
                        Text(mtg.isInProgress ? "// in progress" : "// in \(mtg.minutesUntilStart)m")
                            .font(NFont.mono(9))
                            .foregroundStyle(NSColorToken.textGhost.opacity(0.6))
                    }
                }
                .padding(.horizontal, NSpace.xl)
                .padding(.bottom, NSpace.sm)
            } else if calendarLoaded && calendar.authState == .denied {
                HStack(spacing: NSpace.sm) {
                    Image(systemName: "calendar.badge.exclamationmark")
                        .font(.system(size: 10))
                        .foregroundStyle(NSColorToken.textGhost.opacity(0.5))
                    Text("// calendar access denied — enter names manually")
                        .font(NFont.mono(9))
                        .foregroundStyle(NSColorToken.textGhost.opacity(0.5))
                }
                .padding(.horizontal, NSpace.xl)
                .padding(.bottom, NSpace.sm)
            } else if calendarLoaded && calendar.currentMeeting == nil {
                HStack(spacing: NSpace.sm) {
                    Image(systemName: "calendar")
                        .font(.system(size: 10))
                        .foregroundStyle(NSColorToken.textGhost.opacity(0.4))
                    Text("// no event found — enter names manually or leave blank")
                        .font(NFont.mono(9))
                        .foregroundStyle(NSColorToken.textGhost.opacity(0.4))
                }
                .padding(.horizontal, NSpace.xl)
                .padding(.bottom, NSpace.sm)
            }

            Divider().overlay(NSColorToken.textGhost.opacity(0.10))

            // ── Attendees field ───────────────────────────────────────────────
            VStack(alignment: .leading, spacing: NSpace.sm) {
                HStack {
                    Text("// attendees")
                        .font(NFont.mono(10))
                        .foregroundStyle(NSColorToken.textGhost)
                    Spacer()
                    if detectedTitle != nil {
                        Text("auto-filled from calendar")
                            .font(NFont.mono(9))
                            .foregroundStyle(NSColorToken.Phos.cyan.opacity(0.6))
                    }
                }
                TextField("Sarah, John, Alex…", text: $attendees)
                    .font(NFont.body(14))
                    .foregroundStyle(NSColorToken.textPrimary)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { onStart() }
                    .padding(NSpace.md)
                    .background(NSColorToken.inkRaised)
                    .overlay(
                        Rectangle()
                            .stroke(NSColorToken.textGhost.opacity(0.20), lineWidth: 0.5)
                    )
                Text("Comma-separated. Leave blank → generic Speaker 1/2/3 labels (renameable after).")
                    .font(NFont.mono(9))
                    .foregroundStyle(NSColorToken.textGhost.opacity(0.45))
            }
            .padding(NSpace.xl)

            // ── How it works ──────────────────────────────────────────────────
            VStack(alignment: .leading, spacing: NSpace.sm) {
                infoRow(icon: "mic.fill",
                        text: "Captures your microphone + the call's system audio via ScreenCaptureKit")
                infoRow(icon: "waveform.badge.magnifyingglass",
                        text: "Gemini 3.1 Flash Live identifies distinct voices in real-time")
                infoRow(icon: "person.badge.key.fill",
                        text: "Maps voices to names via introductions, address patterns, speaker order")
                infoRow(icon: "doc.text.fill",
                        text: "After the meeting, structures notes: decisions, action items, open questions")
            }
            .padding(.horizontal, NSpace.xl)
            .padding(.bottom, NSpace.xl)

            Divider().overlay(NSColorToken.textGhost.opacity(0.10))

            // ── Actions ───────────────────────────────────────────────────────
            HStack {
                Button("// cancel") { onCancel() }
                    .font(NFont.mono(11))
                    .foregroundStyle(NSColorToken.textGhost)
                    .buttonStyle(.plain)
                Spacer()
                Button("// start recording") { onStart() }
                    .font(NFont.mono(11))
                    .foregroundStyle(NSColorToken.Phos.amber)
                    .buttonStyle(.plain)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(NSpace.xl)
        }
        .frame(width: 420)
        .background(NSColorToken.inkPaper)
        .onAppear {
            // Refresh calendar data each time the sheet opens
            calendar.refresh()
            calendarLoaded = false
            Task {
                // Brief yield so the sheet renders before we do work
                try? await Task.sleep(for: .milliseconds(80))
                applyCalendarData()
                calendarLoaded = true
                focused = true
            }
        }
    }

    private func applyCalendarData() {
        guard let mtg = calendar.currentMeeting else { return }
        detectedTitle = mtg.title
        // Only auto-fill if user hasn't already typed something
        if attendees.trimmingCharacters(in: .whitespaces).isEmpty, !mtg.attendeesString.isEmpty {
            attendees = mtg.attendeesString
        }
    }

    private func infoRow(icon: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: NSpace.sm) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(NSColorToken.Phos.amber.opacity(0.65))
                .frame(width: 16, alignment: .center)
            Text(text)
                .font(NFont.mono(10))
                .foregroundStyle(NSColorToken.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: – MeetDetectionBanner

/// Toast shown in the top-right when a meeting window is detected.
private struct MeetDetectionBanner: View {
    let meeting:   MeetingDetector.DetectedMeeting
    let onStart:   () -> Void   // start immediately (calendar auto-fill)
    let onSetup:   () -> Void   // open setup sheet first
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: NSpace.md) {
            Circle()
                .fill(NSColorToken.Phos.cyan)
                .frame(width: 6, height: 6)

            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.platformLabel + " detected")
                    .font(NFont.mono(11))
                    .foregroundStyle(NSColorToken.textPrimary)
                Text("in \(meeting.appName)")
                    .font(NFont.mono(9))
                    .foregroundStyle(NSColorToken.textGhost)
            }

            Spacer(minLength: NSpace.sm)

            Button("// setup") { onSetup() }
                .font(NFont.mono(9))
                .foregroundStyle(NSColorToken.textGhost)
                .buttonStyle(.plain)

            Button("// start") { onStart() }
                .font(NFont.mono(10))
                .foregroundStyle(NSColorToken.Phos.amber)
                .buttonStyle(.plain)

            Button { onDismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(NSColorToken.textGhost.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, NSpace.lg)
        .padding(.vertical, NSpace.md)
        .frame(width: 300)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(NSColorToken.Phos.cyan.opacity(0.25), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.35), radius: 14, x: 0, y: 4)
    }
}

// MARK: – MacLiveRecordPanel

/// Floating card (bottom-right) shown during active in-app meeting recording.
/// Shows pulsing status, source, amplitude waveform, and live scrolling transcript.
private struct MacLiveRecordPanel: View {
    let recorder: MacMeetingRecorder
    let detected: MeetingDetector.DetectedMeeting?
    let bridge:   MeetBridgeServer
    let onStop:   () -> Void
    let onCancel: () -> Void

    @State private var pulsing = false

    private var transcriptLines: [String] {
        recorder.partialTranscript
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerRow
            if let spk = bridge.activeSpeaker {
                activeSpeakerRow(spk)
            }
            Divider().overlay(NSColorToken.textGhost.opacity(0.10))
            transcriptArea
            Divider().overlay(NSColorToken.textGhost.opacity(0.10))
            footerRow
        }
        .frame(width: 370)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(NSColorToken.Phos.amber.opacity(0.22), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.45), radius: 20, x: 0, y: 6)
    }

    // ── Active speaker row ────────────────────────────────────────────────────

    @ViewBuilder
    private func activeSpeakerRow(_ name: String) -> some View {
        HStack(spacing: NSpace.sm) {
            Circle()
                .fill(NSColorToken.Phos.green)
                .frame(width: 5, height: 5)
                .opacity(pulsing ? 1.0 : 0.5)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulsing)

            Text("// speaking:")
                .font(NFont.mono(9))
                .foregroundStyle(NSColorToken.textGhost)
            Text(name)
                .font(NFont.mono(10))
                .foregroundStyle(NSColorToken.Phos.green)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, NSpace.lg)
        .padding(.vertical, 5)
        .background(NSColorToken.Phos.green.opacity(0.05))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // ── Header ────────────────────────────────────────────────────────────────

    private var headerRow: some View {
        HStack(spacing: NSpace.sm) {
            // Pulsing recording dot
            Circle()
                .fill(NSColorToken.Phos.orange)
                .frame(width: 7, height: 7)
                .opacity(pulsing ? 1.0 : 0.35)
                .animation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true),
                           value: pulsing)
                .onAppear { pulsing = true }

            // Duration
            Text(formatDuration(recorder.duration))
                .font(NFont.mono(12))
                .foregroundStyle(NSColorToken.textPrimary)
                .monospacedDigit()

            // Source badge
            if let mtg = detected {
                HStack(spacing: 3) {
                    Image(systemName: "video.fill")
                        .font(.system(size: 8))
                    Text(mtg.platformLabel)
                        .font(NFont.mono(9))
                }
                .foregroundStyle(NSColorToken.Phos.cyan.opacity(0.75))
            } else if recorder.systemAudioActive {
                Text("// mic + system audio")
                    .font(NFont.mono(9))
                    .foregroundStyle(NSColorToken.Phos.amber.opacity(0.7))
            } else {
                Text("// mic only")
                    .font(NFont.mono(9))
                    .foregroundStyle(NSColorToken.textGhost.opacity(0.5))
            }

            Spacer(minLength: 0)

            // Waveform
            MeetAmplitudeBars(amp: recorder.micAmp)
                .frame(width: 32, height: 14)
        }
        .padding(.horizontal, NSpace.lg)
        .padding(.vertical, NSpace.md)
    }

    // ── Transcript ────────────────────────────────────────────────────────────

    private var transcriptArea: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if transcriptLines.isEmpty {
                        Text("// listening for voices…")
                            .font(NFont.mono(10))
                            .foregroundStyle(NSColorToken.textGhost.opacity(0.38))
                            .padding(.horizontal, NSpace.lg)
                            .padding(.vertical, NSpace.sm)
                    } else {
                        ForEach(Array(transcriptLines.enumerated()), id: \.offset) { idx, line in
                            TranscriptLineView(text: line)
                                .padding(.horizontal, NSpace.lg)
                                .id(idx)
                        }
                        // Scroll anchor
                        Color.clear.frame(height: 1).id("__bottom__")
                    }
                }
                .padding(.vertical, NSpace.sm)
            }
            .frame(maxHeight: 170)
            .onChange(of: transcriptLines.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("__bottom__", anchor: .bottom)
                }
            }
        }
    }

    // ── Footer ────────────────────────────────────────────────────────────────

    private var footerRow: some View {
        HStack {
            Button("// cancel") { onCancel() }
                .font(NFont.mono(10))
                .foregroundStyle(NSColorToken.textGhost)
                .buttonStyle(.plain)
            Spacer()
            Button("// save & refine") { onStop() }
                .font(NFont.mono(11))
                .foregroundStyle(NSColorToken.Phos.amber)
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, NSpace.lg)
        .padding(.vertical, NSpace.md)
    }

    private func formatDuration(_ t: TimeInterval) -> String {
        String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }
}

// MARK: – TranscriptLineView

/// One line of diarized transcript. Parses "Speaker: text" and colours labels.
private struct TranscriptLineView: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: NSpace.sm) {
            if let (label, content) = parsed {
                Text(label + ":")
                    .font(NFont.mono(9))
                    .foregroundStyle(labelColor(for: label))
                    .frame(width: 56, alignment: .trailing)
                    .lineLimit(1)
                Text(content)
                    .font(NFont.mono(10))
                    .foregroundStyle(NSColorToken.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(text)
                    .font(NFont.mono(10))
                    .foregroundStyle(NSColorToken.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 56 + NSpace.sm)
            }
        }
    }

    // "You: hello" → ("You", "hello")
    private var parsed: (String, String)? {
        let pattern = /^([A-Za-z][A-Za-z 0-9]*?):\s+(.+)/
        guard let m = try? pattern.firstMatch(in: text) else { return nil }
        return (String(m.1), String(m.2))
    }

    private func labelColor(for label: String) -> Color {
        switch label.lowercased() {
        case "you":  return NSColorToken.Phos.cyan
        default:
            // Deterministic colour from name hash
            let hash = label.unicodeScalars.reduce(0) { $0 &+ $1.value }
            let palette: [Color] = [
                NSColorToken.Phos.green,
                NSColorToken.Phos.amber,
                NSColorToken.Phos.violet,
                NSColorToken.Phos.blue,
                NSColorToken.Phos.orange
            ]
            return palette[Int(hash) % palette.count]
        }
    }
}

// MARK: – MeetAmplitudeBars

private struct MeetAmplitudeBars: View {
    let amp: Double

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<6, id: \.self) { i in
                Capsule()
                    .fill(NSColorToken.Phos.amber.opacity(0.75))
                    .frame(width: 2.5, height: barHeight(i))
                    .animation(.easeOut(duration: 0.07), value: amp)
            }
        }
    }

    private func barHeight(_ i: Int) -> CGFloat {
        let wave = abs(sin(Double(i) * 1.1 + 0.3)) * 0.65 + 0.35
        return 2 + CGFloat(amp * wave) * 12
    }
}

#endif
