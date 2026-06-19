#if os(macOS)
import Foundation
import Network
import Observation

// ─── MeetBridgeServer ─────────────────────────────────────────────────────────
//
// Lightweight WebSocket server on localhost:9988.
// The NOUS Chrome extension connects here and forwards:
//   • { type: "participants", names: [...] }  — roster update
//   • { type: "speaker",      name:  "..."  }  — active speaker changed
//   • { type: "meetEnded"                    }  — call ended
//
// The app can also push { type: "recording", active: true/false } to the
// extension so the popup badge reflects the current recording state.
//
// Uses NWListener with .tcp (raw TCP) + manual WebSocket handshake / framing
// because NWListener doesn't expose a WebSocket protocol directly in Swift.
// The implementation is intentionally minimal: one client at a time (the
// extension), frames under 126 bytes for control messages.

@MainActor
@Observable
final class MeetBridgeServer {

    // ── Published state ────────────────────────────────────────────────────
    private(set) var participants:   [String] = []
    private(set) var activeSpeaker:  String?  = nil
    private(set) var clientConnected: Bool    = false
    /// Google Meet room code, e.g. "abc-defg-hij". Stable per meeting URL.
    private(set) var meetingRoomID:  String?  = nil

    var onParticipantsChange: @MainActor ([String]) -> Void = { _ in }
    var onSpeakerChange:      @MainActor (String?)  -> Void = { _ in }

    // ── Private ────────────────────────────────────────────────────────────
    private var listener:   NWListener?
    private var connection: NWConnection?
    private var receiveBuffer = Data()

    // ── Pairing token ──────────────────────────────────────────────────────
    // Random per-launch shared secret. The Chrome extension must present this
    // on the WebSocket upgrade (header `X-Nous-Token:` or query `?token=`).
    // Without it, any local process (or a DNS-rebinding / CSRF-style web page)
    // could connect to the bridge. Exposed read-only so the pairing flow can
    // hand it to the extension.
    private let authToken = MeetBridgeServer.loadOrCreateToken()
    /// Read-only accessor for the pairing flow to deliver to the extension.
    var pairingToken: String { authToken }

    private static let tokenDefaultsKey = "nous.bridge.pairingToken"
    /// Stable per-install bridge token, persisted in UserDefaults so the
    /// extension pairs ONCE rather than re-pairing on every app launch.
    /// Generated lazily on first read.
    static func loadOrCreateToken() -> String {
        let d = UserDefaults.standard
        if let existing = d.string(forKey: tokenDefaultsKey), !existing.isEmpty { return existing }
        let token = UUID().uuidString
        d.set(token, forKey: tokenDefaultsKey)
        return token
    }
    /// Token for the pairing UI without needing the running server instance.
    static var persistedPairingToken: String { loadOrCreateToken() }

    // ── Start / Stop ───────────────────────────────────────────────────────

    func start() {
        guard listener == nil else { return }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Loopback-only bind: pin the listener to 127.0.0.1 so LAN hosts and
        // DNS-rebinding can't reach the bridge. (requiredInterfaceType=.loopback
        // on a listener still binds *all* interfaces — verified via lsof showing
        // *:9988 — so we set the local endpoint host explicitly, which is the
        // reliable way to restrict the bind address. lsof then shows 127.0.0.1:9988.)
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: 9988)

        guard let l = try? NWListener(using: params) else {
            NousLogger.error("bridge", "Failed to create NWListener on 127.0.0.1:9988")
            return
        }
        listener = l

        l.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                switch state {
                case .ready:
                    NousLogger.info("bridge", "MeetBridgeServer listening on :9988")
                case .failed(let err):
                    NousLogger.error("bridge", "Listener failed", ["err": err.localizedDescription])
                    self?.listener = nil
                default: break
                }
            }
        }

        l.newConnectionHandler = { [weak self] conn in
            Task { @MainActor [weak self] in
                self?.acceptConnection(conn)
            }
        }

        l.start(queue: .global(qos: .utility))
    }

    func stop() {
        listener?.cancel();   listener = nil
        connection?.cancel(); connection = nil
        clientConnected = false
    }

    // ── Send recording state to extension ─────────────────────────────────

    func sendRecordingState(_ active: Bool) {
        // Include the room so the merged extension only suppresses its own cloud
        // Meet capture for the meeting the desktop app is actually recording —
        // avoids double-capturing (local recorder + cloud) the same call.
        sendJSON(["type": "recording", "active": active, "meetingRoom": meetingRoomID ?? ""])
    }

    // ── Accept new TCP connection ──────────────────────────────────────────

    private func acceptConnection(_ conn: NWConnection) {
        // Drop old connection if any
        connection?.cancel()
        connection = conn
        receiveBuffer.removeAll()

        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                switch state {
                case .ready:
                    NousLogger.info("bridge", "Extension TCP connected")
                case .failed, .cancelled:
                    NousLogger.info("bridge", "Extension disconnected")
                    self?.clientConnected = false
                    self?.connection = nil
                default: break
                }
            }
        }

        conn.start(queue: .global(qos: .utility))
        // Begin HTTP upgrade read
        receiveHTTPUpgrade(conn)
    }

    // ── WebSocket HTTP upgrade ─────────────────────────────────────────────

    private func receiveHTTPUpgrade(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, err in
            guard let self, let data, err == nil else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.receiveBuffer.append(data)
                if let header = String(data: self.receiveBuffer, encoding: .utf8),
                   header.contains("\r\n\r\n") {
                    self.handleHTTPUpgrade(conn, request: header)
                } else {
                    self.receiveHTTPUpgrade(conn)
                }
            }
        }
    }

    private func handleHTTPUpgrade(_ conn: NWConnection, request: String) {
        // Require the pairing token before completing the WebSocket handshake.
        // Accept it via the `X-Nous-Token:` header or a `?token=` query param on
        // the request line. Reject (close) on absent or mismatched token.
        // TODO(pairing): the extension does not yet receive `pairingToken`.
        //   Wire a pairing handoff (e.g. show the token in the macOS UI / deep
        //   link) so the extension can present it here, then flip `enforceToken`
        //   to true to hard-reject unauthenticated clients.
        // Until then we run in SOFT mode: loopback binding (see start()) already
        // restricts connections to local processes, which is the primary control;
        // a missing/invalid token is logged but allowed so the current extension
        // keeps working. Flip this flag once pairing ships.
        let enforceToken = false
        if !tokenMatches(in: request) {
            NousLogger.warning("bridge", "WebSocket upgrade without valid pairing token (soft mode)")
            if enforceToken { conn.cancel(); return }
        }

        // Extract Sec-WebSocket-Key
        guard let keyLine = request.components(separatedBy: "\r\n")
                .first(where: { $0.hasPrefix("Sec-WebSocket-Key:") }),
              let key = keyLine.components(separatedBy: ": ").last?.trimmingCharacters(in: .whitespaces)
        else {
            conn.cancel()
            return
        }

        let accept = wsAcceptValue(for: key)
        let response = "HTTP/1.1 101 Switching Protocols\r\n" +
                       "Upgrade: websocket\r\n" +
                       "Connection: Upgrade\r\n" +
                       "Sec-WebSocket-Accept: \(accept)\r\n\r\n"

        conn.send(content: response.data(using: .utf8)!, completion: .contentProcessed { [weak self] err in
            guard err == nil else { return }
            Task { @MainActor [weak self] in
                self?.receiveBuffer.removeAll()
                self?.clientConnected = true
                self?.receiveFrames(conn)
            }
        })
    }

    // ── Pairing token validation ───────────────────────────────────────────

    /// True only if the request presents the expected pairing token via the
    /// `X-Nous-Token` header or a `?token=` query parameter on the request line.
    private func tokenMatches(in request: String) -> Bool {
        let lines = request.components(separatedBy: "\r\n")

        // 1. Custom header: `X-Nous-Token: <token>` (case-insensitive header name)
        if let headerLine = lines.first(where: {
            $0.lowercased().hasPrefix("x-nous-token:")
        }) {
            let value = headerLine.components(separatedBy: ":")
                .dropFirst()
                .joined(separator: ":")
                .trimmingCharacters(in: .whitespaces)
            if value == authToken { return true }
        }

        // 2. Query param on the request line: `GET /path?token=<token> HTTP/1.1`
        if let requestLine = lines.first,
           let pathStart = requestLine.firstIndex(of: " "),
           let queryStart = requestLine[pathStart...].firstIndex(of: "?") {
            // Slice the target up to the trailing " HTTP/..." token.
            let afterQuery = requestLine[requestLine.index(after: queryStart)...]
            let target = afterQuery.prefix(while: { $0 != " " })
            for pair in target.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2, kv[0] == "token", String(kv[1]) == authToken {
                    return true
                }
            }
        }

        return false
    }

    // ── WebSocket GUID for accept hash ─────────────────────────────────────

    private func wsAcceptValue(for key: String) -> String {
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let input = (key + magic).data(using: .utf8)!
        var digest = [UInt8](repeating: 0, count: 20)
        input.withUnsafeBytes { ptr in
            var ctx = CC_SHA1_CTX()
            CC_SHA1_Init(&ctx)
            CC_SHA1_Update(&ctx, ptr.baseAddress, CC_LONG(input.count))
            CC_SHA1_Final(&digest, &ctx)
        }
        return Data(digest).base64EncodedString()
    }

    // ── WebSocket frame receive loop ───────────────────────────────────────

    private func receiveFrames(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 2, maximumLength: 65536) { [weak self] data, _, isComplete, err in
            guard let self else { return }
            guard let data, !data.isEmpty, err == nil else {
                if isComplete { Task { @MainActor [weak self] in self?.clientConnected = false } }
                return
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.receiveBuffer.append(data)
                self.processFrames(conn)
                self.receiveFrames(conn)
            }
        }
    }

    private func processFrames(_ conn: NWConnection) {
        // Always work from index 0. Data.removeFirst() can leave a slice whose
        // startIndex != 0, making receiveBuffer[0] trap. Compact after each frame.
        while receiveBuffer.count >= 2 {
            let b0 = receiveBuffer[receiveBuffer.startIndex]
            let b1 = receiveBuffer[receiveBuffer.startIndex + 1]
            let opcode = b0 & 0x0F
            let masked  = (b1 & 0x80) != 0
            var payloadLen = Int(b1 & 0x7F)
            var headerLen  = 2 + (masked ? 4 : 0)

            if payloadLen == 126 {
                guard receiveBuffer.count >= 4 else { return }
                let s = receiveBuffer.startIndex
                payloadLen = Int(receiveBuffer[s + 2]) << 8 | Int(receiveBuffer[s + 3])
                headerLen += 2
            } else if payloadLen == 127 {
                guard receiveBuffer.count >= 10 else { return }
                let s = receiveBuffer.startIndex
                payloadLen = 0
                for i in 2..<10 { payloadLen = payloadLen << 8 | Int(receiveBuffer[s + i]) }
                headerLen += 8
            }

            guard receiveBuffer.count >= headerLen + payloadLen else { return }

            let s = receiveBuffer.startIndex
            var payload = receiveBuffer.subdata(in: (s + headerLen)..<(s + headerLen + payloadLen))

            if masked {
                let maskStart = s + headerLen - 4
                let mask = receiveBuffer[maskStart..<(maskStart + 4)]
                for i in 0..<payload.count {
                    payload[i] ^= mask[mask.startIndex + (i % 4)]
                }
            }

            // Compact after removal so startIndex resets to 0 for the next iteration.
            receiveBuffer.removeFirst(headerLen + payloadLen)
            if receiveBuffer.startIndex != 0 { receiveBuffer = Data(receiveBuffer) }

            // opcode 0x8 = close, 0x9 = ping, 0x1 = text
            switch opcode {
            case 0x8:
                connection?.cancel()
                clientConnected = false
            case 0x9:
                sendPong(conn)
            case 0x1:
                if let text = String(data: payload, encoding: .utf8) {
                    handleMessage(text)
                }
            default: break
            }
        }
    }

    private func sendPong(_ conn: NWConnection) {
        let frame = Data([0x8A, 0x00]) // FIN + pong opcode, zero length
        conn.send(content: frame, completion: .idempotent)
    }

    // ── Message handling ───────────────────────────────────────────────────

    /// Max characters kept for a participant/speaker name before truncation.
    private static let maxNameLength = 80

    /// Trim, strip control/non-printable characters, and cap length. Applied to
    /// untrusted names from the extension before they are stored or fed into an
    /// AI prompt.
    private static func sanitizeName(_ raw: String) -> String {
        let cleaned = raw.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
        let trimmed = String(String.UnicodeScalarView(cleaned))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(maxNameLength))
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String
        else { return }

        switch type {
        case "participants":
            // Names come from an untrusted Chrome extension and are later
            // interpolated into a Gemini prompt; sanitizing here trims, caps
            // length, and strips control characters to reduce prompt-injection
            // surface.
            let names = (json["names"] as? [String] ?? [])
                .map { Self.sanitizeName($0) }
                .filter { !$0.isEmpty }
            participants = names
            onParticipantsChange(names)
            NousLogger.info("bridge", "participants updated", ["count": names.count])

        case "speaker":
            // Sanitized for the same prompt-injection reason as participants.
            let name = (json["name"] as? String).map { Self.sanitizeName($0) }
            let resolved = (name?.isEmpty ?? true) ? nil : name
            activeSpeaker = resolved
            onSpeakerChange(resolved)

        case "meetingRoom":
            let roomID = (json["roomID"] as? String)?.trimmingCharacters(in: .whitespaces)
            if let roomID, !roomID.isEmpty {
                meetingRoomID = roomID
                NousLogger.info("bridge", "meeting room ID received", ["roomID": roomID])
            }

        case "meetEnded":
            participants  = []
            activeSpeaker = nil
            meetingRoomID = nil
            onParticipantsChange([])
            onSpeakerChange(nil)
            NousLogger.info("bridge", "Meet ended")

        default: break
        }
    }

    // ── Send helpers ───────────────────────────────────────────────────────

    private func sendJSON(_ obj: [String: Any]) {
        guard clientConnected,
              let conn = connection,
              let data = try? JSONSerialization.data(withJSONObject: obj)
        else { return }
        sendTextFrame(data, on: conn)
    }

    private func sendTextFrame(_ payload: Data, on conn: NWConnection) {
        var header = Data()
        header.append(0x81) // FIN + text opcode
        let len = payload.count
        if len < 126 {
            header.append(UInt8(len))
        } else if len < 65536 {
            header.append(126)
            header.append(UInt8((len >> 8) & 0xFF))
            header.append(UInt8(len & 0xFF))
        } else {
            header.append(127)
            for i in stride(from: 56, through: 0, by: -8) {
                header.append(UInt8((len >> i) & 0xFF))
            }
        }
        conn.send(content: header + payload, completion: .idempotent)
    }
}

// Import CommonCrypto for SHA-1 (WebSocket handshake)
import CommonCrypto

#endif
