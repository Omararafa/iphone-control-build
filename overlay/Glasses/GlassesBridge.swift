// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Combine
import CryptoKit
import UIKit
import Security
import CoreVideo

@MainActor final class GlassesBridge: ObservableObject {
    static let shared = GlassesBridge()
    @Published var relayURL: String = UserDefaults.standard.string(forKey: "glassesRelayURL") ?? ""
    @Published var claimCode = ""
    @Published private(set) var status = "Stopped" { didSet { recordStatus() } }
    @Published private(set) var running = false
    @Published private(set) var live = false
    @Published private(set) var pairingCode: String?
    @Published private(set) var registrationCode: String?
    @Published private(set) var needsShareApproval = false
    @Published private(set) var frames = 0
    @Published private(set) var controls = 0
    private var loop: Task<Void, Never>?
    private var capture: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var ticker: Task<Void, Never>?
    private var rtc: GlassesRTC?
    private var generation = UUID()
    private var runID = UUID()
    private var origin = ""
    private var relayOpen = false
    private var serverAuthenticated = false
    private var pairTried = false
    private var lastPair = Date.distantPast
    private var ephemeral: P256.KeyAgreement.PrivateKey?
    private var commitment: Data?
    private var pendingPair: GlassesTrust.Result?
    private var sessionKey: Data?
    private var authenticated = false
    private var proofExpected = false
    private var lastHeard = Date()
    private var lastInputWindow = Date()
    private var inputCount = 0
    private var queuedInputs = 0
    private var touchStart: (CGPoint, Date)?
    private let deviceQueue = DispatchQueue(label: "iphoneuse.glasses.device", qos: .userInitiated)
    // Device commands already in this queue must not execute after Stop.
    private let epoch = CommandEpoch()

    private init() {}

    func start() {
        guard !running, !PhoneAgent.shared.isRunning else { status = "Stop the agent run first"; return }
        guard let url = URL(string: relayURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/" else {
            status = "Enter the HTTPS address of your Glasscast server"; return
        }
        origin = url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        relayURL = origin
        UserDefaults.standard.set(origin, forKey: "glassesRelayURL")
        running = true; runID = UUID()
        let id = runID
        status = "Connecting to this iPhone…"
        loop = Task {
            await Connection.shared.connect()
            guard running, runID == id, !Task.isCancelled else { return }
            guard Connection.shared.isReady else { stop(); status = "Reconnect LocalDevVPN in Phone Connection first"; return }
            BackgroundAudioManager.shared.requestStart()
            keepAliveStarted = true
            UIApplication.shared.isIdleTimerDisabled = true
            startTicker()
            await relayLoop(id)
        }
    }
    private var keepAliveStarted = false

    func stop() {
        running = false; runID = UUID()
        loop?.cancel(); loop = nil
        ticker?.cancel(); ticker = nil
        endSession("stopped")
        resetHandshake()
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        registrationCode = nil; relayOpen = false
        if keepAliveStarted {
            BackgroundAudioManager.shared.requestStop()
            keepAliveStarted = false
        }
        UIApplication.shared.isIdleTimerDisabled = false
        status = "Stopped"
    }

    func forgetGlasses() {
        stop()
        let savedOrigin = origin.isEmpty ? relayURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) : origin
        if !savedOrigin.isEmpty { GlassesSecrets.delete("pair:" + savedOrigin) }
        status = "Glasses forgotten; pair again next time"
    }
    func claim() {
        guard serverAuthenticated else { status = "Approve this phone on the server first"; return }
        let code = claimCode.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.range(of: "^[A-Z0-9]{3}-[A-Z0-9]{3}$", options: .regularExpression) != nil else {
            status = "Enter the ABC-DEF connect code shown on the glasses"; return
        }
        send(["type": "claim", "code": code])
    }

    private func relayLoop(_ id: UUID) async {
        var backoff: UInt64 = 1
        while running && runID == id && !Task.isCancelled {
            guard let url = URL(string: origin.replacingOccurrences(of: "https://", with: "wss://") + "/ws/companion") else { return }
            let ws = URLSession.shared.webSocketTask(with: url)
            ws.maximumMessageSize = 131072
            socket = ws
            serverAuthenticated = false
            ws.resume()
            if let token: String = GlassesSecrets.read("token:" + origin, as: String.self) {
                send(["type": "auth", "token": token])
            } else {
                status = "Registering this phone with the server…"
                send(["type": "pair", "name": "iPhone Glasses"])
            }
            do {
                while running && runID == id && !Task.isCancelled {
                    let message = try await ws.receive()
                    guard socket === ws, running, runID == id else { break }
                    let data: Data
                    switch message { case .string(let s): data = Data(s.utf8); case .data(let d): data = d; @unknown default: continue }
                    guard data.count <= 131072,
                          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    await receive(object)
                    backoff = 1
                }
            } catch { /* No tokens, SDP or private addresses in logs. */ }
            guard running, runID == id, !Task.isCancelled else { return }
            if socket === ws { socket = nil }
            relayOpen = false
            if !live { resetHandshake(); status = "Reconnecting to the server…" }
            do { try await Task.sleep(nanoseconds: backoff * 1_000_000_000) } catch { return }
            backoff = min(backoff * 2, 30)
        }
    }

    private func send(_ object: [String: Any]) {
        guard let socket, let data = try? JSONSerialization.data(withJSONObject: object), let text = String(data: data, encoding: .utf8) else { return }
        // URLSession preserves send order; avoid independent async tasks reordering pairing messages.
        socket.send(.string(text)) { _ in }
    }

    private func receive(_ o: [String: Any]) async {
        guard let type = o["type"] as? String else { return }
        switch type {
        case "pairCode":
            registrationCode = o["code"] as? String
            status = "Approve iPhone Glasses in the server's pairing window"
        case "paired" where !relayOpen:
            guard let token = o["token"] as? String, !token.isEmpty, token.count <= 512 else { return }
            do { try GlassesSecrets.save("token:" + origin, token) }
            catch { stop(); status = "Could not save server registration securely"; return }
            registrationCode = nil
            socket?.cancel(with: .normalClosure, reason: nil)
        case "authenticated":
            serverAuthenticated = true
            status = live ? "Sharing with your glasses" : "Ready — choose Phone on the glasses"
        case "pairFailed" where !serverAuthenticated:
            stop(); status = "Server registration was declined or expired; tap Start to retry"
        case "authFailed", "forgotten":
            guard !relayOpen else { resetHandshake(); return }
            GlassesSecrets.delete("token:" + origin)
            stop(); status = "Server registration expired; tap Start to register again"
        case "relayOpen":
            guard rtc == nil else { send(["type": "authFailed"]); return }
            resetHandshake(); relayOpen = true; pairTried = false
        case "relayClosed":
            relayOpen = false
            if live { resetHandshake(keepSession: true) }
            else { endSession("stopped"); resetHandshake(); status = "Ready — choose Phone on the glasses" }
        case "claimed": status = "Glasses found — waiting for pairing"
        case "claimFailed": status = "Connect code not found or expired"
        case "pairStart":
            guard relayOpen, rtc == nil, !pairTried, Date().timeIntervalSince(lastPair) >= 10,
                  let raw = o["commit"] as? String, let bytes = GlassesTrust.decode(raw, count: 32) else { return }
            resetHandshake(); pairTried = true; lastPair = Date()
            commitment = bytes
            let key = P256.KeyAgreement.PrivateKey(); ephemeral = key
            send(["type": "pairKey", "key": GlassesTrust.b64(key.publicKey.x963Representation)])
            setDeadline(seconds: 60)
        case "pairReveal":
            guard relayOpen, pendingPair == nil, let ephemeral, let commitment,
                  let raw = o["key"] as? String, let bytes = GlassesTrust.decode(raw, count: 65),
                  GlassesTrust.same(GlassesTrust.hash(bytes), commitment) else { rejectPair(); return }
            do {
                let publicKey = try P256.KeyAgreement.PublicKey(x963Representation: bytes)
                let secret = try ephemeral.sharedSecretFromKeyAgreement(with: publicKey).withUnsafeBytes { Data($0) }
                let result = GlassesTrust.derive(secret, glasses: bytes, phone: ephemeral.publicKey.x963Representation)
                pendingPair = result; pairingCode = result.code
                self.ephemeral = nil; self.commitment = nil
                status = "Compare the six digits with your glasses, then approve"
            } catch { rejectPair() }
        case "hello":
            guard relayOpen, rtc == nil, !proofExpected, pendingPair == nil,
                  let id = o["id"] as? String, let nonce = o["nonce"] as? String,
                  let glassesNonce = GlassesTrust.decode(nonce, count: 16),
                  let paired = GlassesSecrets.read("pair:" + origin, as: GlassesTrust.Pair.self), paired.id == id else {
                send(["type": "authFailed"]); return
            }
            var bytes = [UInt8](repeating: 0, count: 16)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return }
            let phoneNonce = Data(bytes)
            let sk = GlassesTrust.session(paired.key, glasses: glassesNonce, phone: phoneNonce)
            sessionKey = sk; proofExpected = true
            send(["type": "challenge", "nonce": GlassesTrust.b64(phoneNonce), "mac": GlassesTrust.b64(GlassesTrust.mac(sk, Data("phone".utf8)))])
            setDeadline(seconds: 30)
        case "proof":
            guard relayOpen, proofExpected, let sk = sessionKey, let mac = o["mac"] as? String,
                  GlassesTrust.matches(sk, Data("glasses".utf8), mac) else {
                resetHandshake(); send(["type": "authFailed"]); return
            }
            proofExpected = false; authenticated = true
            needsShareApproval = true; status = "Your paired glasses request screen and touch control"
            send(["type": "sessionState", "state": "asking"])
            setDeadline(seconds: 90)
        case "rtcAnswer":
            guard authenticated, let rtc, let sk = sessionKey,
                  let sdp = o["sdp"] as? String, sdp.utf8.count <= 100000,
                  let mac = o["mac"] as? String, GlassesTrust.matches(sk, GlassesTrust.sdp("answer", sdp), mac) else { return }
            do { try await rtc.answer(sdp) } catch { endSession("capture"); status = "Could not connect video" }
        case "iceCandidate": if authenticated { rtc?.candidate(o) }
        default: break
        }
    }

    func approvePair() {
        guard let result = pendingPair, relayOpen else { return }
        do { try GlassesSecrets.save("pair:" + origin, result.pair) }
        catch { rejectPair(); status = "Could not save glasses pairing securely"; return }
        resetHandshake()
        send(["type": "paired"])
        status = "Glasses paired"
    }
    func rejectPair() { resetHandshake(); send(["type": "pairFailed"]); status = "Pairing cancelled" }

    func approveSharing() {
        guard running, authenticated, needsShareApproval, rtc == nil, let sk = sessionKey else { return }
        deadline?.cancel(); needsShareApproval = false
        let id = UUID(); generation = id; epoch.set(id)
        let connection = GlassesRTC(); rtc = connection
        connection.onCandidate = { [weak self] o in guard self?.generation == id else { return }; self?.send(o) }
        connection.onOpen = { [weak self] in
            guard let self, self.generation == id else { return }
            self.deadline?.cancel(); self.live = true; self.lastHeard = Date()
            self.status = "Sharing with your glasses"
            self.startCapture(id)
        }
        connection.onMessage = { [weak self] bytes in guard self?.generation == id else { return }; self?.input(bytes) }
        connection.onFailure = { [weak self] message in
            guard let self, self.generation == id else { return }
            self.endSession("capture"); self.status = message
        }
        status = "Connecting video…"; frames = 0; controls = 0
        send(["type": "sessionState", "state": "live"])
        setDeadline(seconds: 35)
        Task {
            do {
                let sdp = try await connection.offer()
                guard generation == id, running else { return }
                send(["type": "rtcOffer", "sdp": sdp, "mac": GlassesTrust.b64(GlassesTrust.mac(sk, GlassesTrust.sdp("offer", sdp)))])
            } catch { guard generation == id else { return }; endSession("capture"); status = "Could not start video" }
        }
    }
    func declineSharing() {
        send(["type": "sessionState", "state": "declined"])
        resetHandshake(); status = "Screen sharing declined"
    }
    private func resetHandshake(keepSession: Bool = false) {
        deadline?.cancel(); deadline = nil
        ephemeral = nil; commitment = nil; pendingPair = nil; pairingCode = nil
        proofExpected = false; needsShareApproval = false
        if !keepSession { sessionKey = nil; authenticated = false }
    }
    private func setDeadline(seconds: UInt64) {
        deadline?.cancel()
        deadline = Task {
            do { try await Task.sleep(nanoseconds: seconds * 1_000_000_000) } catch { return }
            if pendingPair != nil || ephemeral != nil { rejectPair() }
            else { endSession("silent"); resetHandshake(); status = "Connection request timed out" }
        }
    }
    private func endSession(_ reason: String) {
        generation = UUID(); epoch.set(generation)
        capture?.cancel(); capture = nil
        rtc?.send(["type": "bye", "reason": reason]); rtc?.close(); rtc = nil
        live = false; touchStart = nil; queuedInputs = 0
        resetHandshake()
    }
    private func startTicker() {
        ticker?.cancel()
        ticker = Task {
            var tick = 0
            while running && !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                tick += 1
                if tick % 5 == 0 { recordStatus() }
                if tick % 15 == 0 && serverAuthenticated { send(["type": "ping", "t": Date().timeIntervalSince1970 * 1000]) }
                if live && Date().timeIntervalSince(lastHeard) > 15 {
                    endSession("silent"); status = "Lost contact with the glasses"
                }
                if live && !UIApplication.shared.isProtectedDataAvailable {
                    endSession("capture"); status = "Phone locked — sharing stopped"
                }
            }
        }
    }
    /// Local diagnostic only: no tokens, pairing codes, SDP, screen images, or text input.
    private func recordStatus() {
        let report: [String: Any] = ["build": "iPhone Glasses 1", "status": status,
            "running": running, "live": live, "frames": frames, "controls": controls,
            "updated": ISO8601DateFormatter().string(from: Date())]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
            try? data.write(to: URL.documentsDirectory.appendingPathComponent("glasses-status.json"), options: .atomic)
        }
    }
    private func startCapture(_ id: UUID) {
        capture = Task {
            var failures = 0
            while live && generation == id && !Task.isCancelled {
                let buffer: CVPixelBuffer? = await withCheckedContinuation { continuation in
                    deviceQueue.async { [epoch] in
                        guard epoch.isCurrent(id) else { continuation.resume(returning: nil); return }
                        let buffer = autoreleasepool {
                            (try? DeviceSession.shared.agentScreenshot()).flatMap(GlassesRTC.pixelBuffer)
                        }
                        continuation.resume(returning: buffer)
                    }
                }
                guard live, generation == id, !Task.isCancelled else { return }
                if let buffer { failures = 0; frames += 1; rtc?.frame(buffer) }
                else { failures += 1 }
                if failures >= 3 { stop(); status = "Screen capture stopped; reconnect Phone Connection, then Start again"; return }
                do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
            }
        }
    }

    private func input(_ data: Data) {
        guard live, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let type = o["type"] as? String else { return }
        if type == "ping", let t = o["t"] as? Double, t.isFinite {
            lastHeard = Date(); rtc?.send(["type": "pong", "t": t]); return
        }
        if type == "end" { endSession("stopped"); status = "Session ended on the glasses"; return }
        if Date().timeIntervalSince(lastInputWindow) >= 1 { lastInputWindow = Date(); inputCount = 0 }
        inputCount += 1
        guard inputCount <= 80, queuedInputs < 8 else { return }
        func point(_ x: String = "x", _ y: String = "y") -> CGPoint? {
            guard let x = o[x] as? Double, let y = o[y] as? Double, x.isFinite, y.isFinite,
                  (0...1).contains(x), (0...1).contains(y) else { return nil }
            return CGPoint(x: x, y: y)
        }
        let operation: () throws -> Void
        var resultType: String?
        switch type {
        case "tap", "doubleTap":
            guard let p = point() else { return }
            operation = {
                try DeviceSession.shared.glassesGesture(from: p, to: p, taps: type == "doubleTap" ? 2 : 1)
            }
        case "touch":
            guard let p = point(), let phase = o["phase"] as? String else { return }
            if phase == "down" { touchStart = (p, Date()); return }
            if phase == "move" { return }
            guard phase == "up", let start = touchStart else { return }
            touchStart = nil
            let ms = UInt64(min(2000, max(0, Date().timeIntervalSince(start.1) * 1000)))
            operation = { try DeviceSession.shared.glassesGesture(from: start.0, to: p, before: ms) }
        case "swipe":
            guard let from = point("x1", "y1"), let to = point("x2", "y2"),
                  let ms = o["ms"] as? Double, ms.isFinite, (50...2000).contains(ms) else { return }
            operation = { try DeviceSession.shared.glassesGesture(from: from, to: to, duration: UInt64(ms)) }
        case "nav":
            guard let action = o["action"] as? String else { return }
            switch action {
            case "home": operation = { try DeviceSession.shared.agentHome() }
            case "back": operation = { try DeviceSession.shared.glassesGesture(from: CGPoint(x: 0.005, y: 0.5), to: CGPoint(x: 0.8, y: 0.5)) }
            case "notifications": operation = { try DeviceSession.shared.glassesGesture(from: CGPoint(x: 0.4, y: 0.005), to: CGPoint(x: 0.4, y: 0.8), duration: 400) }
            case "recents": operation = { try DeviceSession.shared.glassesGesture(from: CGPoint(x: 0.5, y: 0.999), to: CGPoint(x: 0.5, y: 0.5), duration: 350, after: 650) }
            default: return
            }
        case "typeText":
            resultType = type
            guard let text = o["text"] as? String, text.utf8.count <= 1000,
                  text.unicodeScalars.allSatisfy({ (32...126).contains($0.value) }) else {
                rtc?.send(["type": "result", "of": type, "ok": false]); return
            }
            operation = { try DeviceSession.shared.agentType(text) }
        case "key":
            resultType = type
            guard let key = o["key"] as? String, key == "Enter" || key == "Backspace" else {
                rtc?.send(["type": "result", "of": type, "ok": false]); return
            }
            operation = { try DeviceSession.shared.glassesKey(backspace: key == "Backspace") }
        case "switchApp": rtc?.send(["type": "result", "of": type, "ok": false]); return
        case "overviewApps": rtc?.send(["type": "overviewApps", "apps": []]); return
        default: return
        }
        let id = generation, reply = resultType
        queuedInputs += 1
        deviceQueue.async { [weak self, epoch] in
            guard epoch.isCurrent(id) else { return }
            let ok: Bool
            do { try operation(); ok = true } catch { ok = false }
            Task { @MainActor in
                guard let self, self.generation == id else { return }
                self.queuedInputs = max(0, self.queuedInputs - 1)
                if ok { self.controls += 1 }
                if let reply { self.rtc?.send(["type": "result", "of": reply, "ok": ok]) }
            }
        }
    }
}

private final class CommandEpoch: @unchecked Sendable {
    private let lock = NSLock()
    private var value = UUID()
    func set(_ value: UUID) { lock.lock(); self.value = value; lock.unlock() }
    func isCurrent(_ value: UUID) -> Bool { lock.lock(); defer { lock.unlock() }; return self.value == value }
}
