import SwiftUI
import NearbyInteraction
import MultipeerConnectivity

// Keep all NI/MPC state on the main queue. Delegate callbacks hop to it below.
final class RangingModel: NSObject, ObservableObject, NISessionDelegate, MCSessionDelegate, MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate {
    let lidar = LidarModel()
    @Published private(set) var inspectionActive = false
    @Published private(set) var inspectionConfirmed = false
    @Published private(set) var inspectionMessage = "Motor hold not requested"
    @Published private(set) var remoteInspection = false
    private var inspectionTimer: Timer?
    private var inspectionRequest: URLSessionDataTask?
    private var inspectionURL: URL?
    private var inspectionGeneration = UUID()
    private var sharedARAttached = false

    func enterInspection(receiver: String) {
        stopMotion()
        inspectionActive = true
        inspectionConfirmed = false
        inspectionMessage = "Confirming motor hold…"
        if connected { sendMessage(kind: "inspection", value: true) }
        let address = receiver.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: address), ["http", "https"].contains(url.scheme ?? ""), url.host != nil {
            inspectionURL = url.appendingPathComponent("inspection")
        } else { inspectionURL = nil }
        inspectionTimer?.invalidate()
        pushInspection(true)
        inspectionTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.pushInspection(true) }
    }
    func exitInspection() {
        guard inspectionActive else { return }
        lidar.stopPreview()
        inspectionActive = false
        inspectionTimer?.invalidate(); inspectionTimer = nil
        if connected { sendMessage(kind: "inspection", value: false) }
        pushInspection(false, force: true)
    }
    private func pushInspection(_ enabled: Bool, force: Bool = false) {
        guard let inspectionURL else {
            inspectionMessage = "Pi hold unconfirmed · disconnect motor power for this test"
            return
        }
        guard force || inspectionRequest == nil else { return }
        if force { inspectionRequest?.cancel(); inspectionRequest = nil }
        inspectionGeneration = UUID()
        let current = inspectionGeneration
        var req = URLRequest(url: inspectionURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer 12345", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["enabled": enabled])
        inspectionRequest = http.dataTask(with: req) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self, self.inspectionGeneration == current else { return }
                self.inspectionRequest = nil
                let reply = data.flatMap { try? JSONDecoder().decode(PiReply.self, from: $0) }
                let accepted = error == nil && (response as? HTTPURLResponse)?.statusCode == 200 && reply?.drive?.state == (enabled ? "inspection" : "stopped")
                self.inspectionConfirmed = enabled && accepted
                self.inspectionMessage = accepted ? (enabled ? "Pi confirmed · motors held stopped" : "Motor hold released") : "Pi hold unconfirmed · disconnect motor power for this test"
            }
        }
        inspectionRequest?.resume()
    }
    @Published var running = false
    @Published var connected = false
    @Published var remoteRound: RoundState?
    private var localRound: RoundState?
    var isRobot: Bool { role == "Robot" }
    func isFresh(at date: Date) -> Bool { updated.map { date.timeIntervalSince($0) >= 0 && date.timeIntervalSince($0) < 1 } ?? false }
    func bearing(at date: Date) -> Float? {
        guard isFresh(at: date) else { return nil }
        if let horizontalAngle, horizontalAngle.isFinite { return horizontalAngle }
        if let direction, direction.x.isFinite, direction.z.isFinite { return atan2(direction.x, -direction.z) }
        return nil
    }
    func publishRound(_ round: RoundState) {
        localRound = round
        if connected && !isRobot { sendMessage(kind: "round", value: round) }
    }
    @Published var beamStatus: BeamStatus?
    @Published var beamUpdated: Date?
    func beamIsLive(at date: Date) -> Bool {
        beamUpdated.map { date.timeIntervalSince($0) < 1 && date.timeIntervalSince($0) >= 0 } ?? false
    }
    @Published var driveStatus: DriveStatus?
    @Published var driveUpdated: Date?
    @Published var activeAction: String?
    @Published var driveError: String?
    private var motion: MotionCommand?
    private var controlRequest: URLSessionDataTask?
    private var controlTimer: Timer?
    private var controlSequence = 0
    private var trackingSession = UUID().uuidString
    var canControlPi: Bool { running && endpoint != nil }
    func driveIsLive(at now: Date) -> Bool {
        driveUpdated.map { now.timeIntervalSince($0) < 1 } ?? false
    }
    func sendIntent(action: String, targetMeters: Int, speed: Int = 80) {
        if action == "stop" { stopMotion(); return }
        beginMotion(action: action, targetMeters: targetMeters, speed: speed)
    }
    func beginMotion(action: String, targetMeters: Int = 2, speed: Int = 80) {
        guard !inspectionActive, !remoteInspection else { driveError = "Close LiDAR Lab on the can phone before driving."; return }
        guard !isRobot, running, endpoint != nil else { driveError = "Enter the Pi URL and token, then connect."; return }
        guard driveIsLive(at: .now), driveStatus?.enabled == true else { driveError = "Pi motor bridge is not ready."; return }
        if action == "summon" && (!connected || driveStatus?.summonReady != true) {
            driveError = "Connect both phones and calibrate the mounted bearing on the Pi."; return
        }
        guard activeAction != action else { return }
        driveError = nil
        motion = MotionCommand(client_id: deviceID, sequence: 0, sent_at: 0,
                               action: action, targetMeters: targetMeters, speed: speed)
        activeAction = action
        sendControl(force: true)
    }
    func stopMotion() {
        guard endpoint != nil, running else { motion = nil; activeAction = nil; return }
        motion = MotionCommand(client_id: deviceID, sequence: 0, sent_at: 0,
                               action: "stop", targetMeters: 2, speed: 25)
        activeAction = nil
        sendControl(force: true)
    }
    private func applyBeamReply(_ beam: BeamStatus?) {
        guard let beam else { return }
        if beamStatus != beam { beamStatus = beam }
        beamUpdated = .now
    }
    private func applyDrive(_ status: DriveStatus) {
        driveStatus = status; driveUpdated = .now
        if isRobot && connected { sendMessage(kind: "drive", value: status) }
    }
    private func sendControl(force: Bool = false) {
        guard let endpoint, var command = motion, force || controlRequest == nil else { return }
        if force { controlRequest?.cancel(); controlRequest = nil }
        controlSequence += 1
        command.sequence = controlSequence
        command.sent_at = Date().timeIntervalSince1970
        motion = command
        var req = URLRequest(url: endpoint.deletingLastPathComponent().appendingPathComponent("control"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONEncoder().encode(command)
        let current = generation
        controlRequest = http.dataTask(with: req) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self, self.generation == current, self.motion?.id == command.id else { return }
                self.controlRequest = nil
                if let data, let reply = try? JSONDecoder().decode(PiReply.self, from: data) {
                    self.applyBeamReply(reply.beam)
                    if let status = reply.drive {
                        self.applyDrive(status)
                        if status.commandID != command.id { self.motion = nil; self.activeAction = nil }
                    }
                    if let error = reply.error { self.driveError = error; self.motion = nil; self.activeAction = nil }
                }
                if let error {
                    self.driveError = "Pi connection lost: " + error.localizedDescription
                    self.motion = nil; self.activeAction = nil
                } else if let response = response as? HTTPURLResponse, response.statusCode != 200 {
                    self.driveError = self.driveError ?? "Pi rejected command (HTTP \(response.statusCode))"
                    self.motion = nil; self.activeAction = nil
                }
                if command.action == "stop" { self.motion = nil; self.activeAction = nil }
            }
        }
        controlRequest?.resume()
    }
    @discardableResult private func sendMessage<T: Encodable>(kind: String, value: T) -> Bool {
        guard let session = mpc, !session.connectedPeers.isEmpty else { return false }
        do {
            let data = try JSONEncoder().encode(PeerMessage(kind: kind, payload: JSONEncoder().encode(value)))
            enqueuePeerData(data, session: session)
            return true
        } catch { status = "Could not encode peer message"; return false }
    }
    private func enqueuePeerData(_ data: Data, session: MCSession) {
        let current = generation
        peerSendQueue.async { [weak self] in
            do {
                let peers = session.connectedPeers
                guard !peers.isEmpty else { return }
                try session.send(data, toPeers: peers, with: .reliable)
            } catch {
                DispatchQueue.main.async {
                    guard let self, self.generation == current else { return }
                    self.status = "Peer connection unavailable"
                }
            }
        }
    }

    @Published var status = "Stopped"
    @Published var peerName = "None"
    @Published var distance: Float?
    @Published var direction: SIMD3<Float>?
    @Published var horizontalAngle: Float?
    @Published var convergence = "Not started"
    @Published var updated: Date?
    @Published var delivery = "Not configured"
    @Published var cameraAssistance = true
    var capabilities: String {
        let c = NISession.deviceCapabilities
        return "Distance: \(c.supportsPreciseDistanceMeasurement) · Direction: \(c.supportsDirectionMeasurement) · Camera assistance: \(c.supportsCameraAssistance) · Extended distance: \(c.supportsExtendedDistanceMeasurement)"
    }
    private let service = "trashbot-uwb"
    private var ni: NISession?
    private var mpc: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var peerToken: NIDiscoveryToken?
    private var role = "Robot"
    private var endpoint: URL?
    private var apiToken = ""
    private var timer: Timer?
    private var request: URLSessionDataTask?
    private var generation = UUID()
    private let deviceID = UUID().uuidString
    private let peerSendQueue = DispatchQueue(label: "trashketball.peer-send")
    private var nextUploadAt = Date.distantPast
    private var uploadBackoff: TimeInterval = 0.25
    @Published private(set) var piUnavailable = false

    override init() {
        super.init()
        #if DEBUG
        // Regression harness: exercise real failed requests without requiring UWB hardware.
        if ProcessInfo.processInfo.arguments.contains("--ui-test-offline-pi") {
            role = "Robot"
            running = true
            endpoint = URL(string: "http://127.0.0.1:9/measurements")!
            apiToken = "offline-ui-test-only"
            timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.upload() }
        }
        #endif
    }
    private lazy var http: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 3
        return URLSession(configuration: config)
    }()

    func start(role: String, receiver: String, token: String) {
        stop()
        guard NISession.deviceCapabilities.supportsPreciseDistanceMeasurement else {
            status = "This phone does not support UWB ranging"; return
        }
        let address = receiver.trimmingCharacters(in: .whitespacesAndNewlines)
        if !address.isEmpty {
            guard let url = URL(string: address), ["http", "https"].contains(url.scheme ?? ""), url.host != nil else {
                status = "Enter a complete Pi URL starting with http://"; return
            }
            guard !token.isEmpty else { status = "Enter the Pi API token"; return }
            endpoint = url.appendingPathComponent("measurements")
        } else { endpoint = nil }
        self.role = role
        apiToken = token
        trackingSession = UUID().uuidString
        running = true
        UIApplication.shared.isIdleTimerDisabled = true
        piUnavailable = false; nextUploadAt = .distantPast; uploadBackoff = 0.25
        delivery = endpoint == nil ? "Phone-only test" : "Connecting to Pi…"
        let ranging = NISession()
        ranging.delegate = self
        ranging.delegateQueue = .main
        ni = ranging
        sharedARAttached = false
        let localPeer = MCPeerID(displayName: "\(role)-\(UUID().uuidString.prefix(6))")
        let session = MCSession(peer: localPeer, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        mpc = session
        // Only User browses and Robot advertises, avoiding simultaneous invitations.
        if role == "Robot" {
            let ad = MCNearbyServiceAdvertiser(peer: localPeer, discoveryInfo: nil, serviceType: service)
            ad.delegate = self; advertiser = ad; ad.startAdvertisingPeer()
        } else {
            let search = MCNearbyServiceBrowser(peer: localPeer, serviceType: service)
            search.delegate = self; browser = search; search.startBrowsingForPeers()
        }
        status = "Looking for the other phone"
        controlTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.sendControl() }
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.upload() }
    }

    func stop() {
        stopMotion()
        controlTimer?.invalidate(); controlTimer = nil
        motion = nil; activeAction = nil
        // Pi watchdog stops output if this final request cannot arrive.
        generation = UUID()
        timer?.invalidate(); timer = nil
        request?.cancel(); request = nil
        controlRequest = nil
        driveStatus = nil; driveUpdated = nil; driveError = nil
        beamStatus = nil; beamUpdated = nil
        piUnavailable = false; nextUploadAt = .distantPast; uploadBackoff = 0.25
        advertiser?.stopAdvertisingPeer(); advertiser = nil
        browser?.stopBrowsingForPeers(); browser = nil
        mpc?.delegate = nil; mpc?.disconnect(); mpc = nil
        ni?.delegate = nil; ni?.invalidate(); ni = nil
        sharedARAttached = false
        lidar.releaseUWB()
        remoteInspection = false
        peerToken = nil
        clear()
        connected = false; remoteRound = nil
        delivery = "Disconnected"
        convergence = "Not started"
        running = false; status = "Stopped"; peerName = "None"
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func clear() { distance = nil; direction = nil; horizontalAngle = nil; updated = nil }
    private func sendToken() {
        guard let session = mpc, !session.connectedPeers.isEmpty, let token = ni?.discoveryToken else { return }
        do {
            let data = try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
            let envelope = try JSONEncoder().encode(PeerMessage(kind: "token", payload: data))
            enqueuePeerData(envelope, session: session)
        } catch { status = "Token send failed: \(error.localizedDescription)" }
    }
    private func range() {
        guard let token = peerToken, let ni else { return }
        let config = NINearbyPeerConfiguration(peerToken: token)
        config.isCameraAssistanceEnabled = cameraAssistance && NISession.deviceCapabilities.supportsCameraAssistance
        config.isExtendedDistanceMeasurementEnabled = NISession.deviceCapabilities.supportsExtendedDistanceMeasurement && token.deviceCapabilities.supportsExtendedDistanceMeasurement
        convergence = config.isCameraAssistanceEnabled ? "Waiting for camera-assisted calibration" : "Camera assistance off"
        if isRobot && config.isCameraAssistanceEnabled && !sharedARAttached {
            lidar.acquireForUWB()
            ni.setARSession(lidar.session)
            sharedARAttached = true
        }
        ni.run(config)
        status = "Ranging · keep phones oriented toward each other"
    }

    private func upload() {
        guard running, let endpoint, request == nil, Date() >= nextUploadAt else { return }
        let age = updated.map { Date().timeIntervalSince($0) }
        let fresh = age.map { $0 >= 0 && $0 < 0.25 } ?? false
        var body: [String: Any] = ["device_id": deviceID, "tracking_session_id": trackingSession, "peer_connected": connected, "role": role.lowercased(), "fresh": fresh,
            "distance_m": NSNull(), "direction": NSNull(), "horizontal_angle_rad": NSNull(), "age_s": age.map { $0 as Any } ?? NSNull()]
        if fresh {
            if let distance { body["distance_m"] = distance }
            if let horizontalAngle { body["horizontal_angle_rad"] = horizontalAngle }
            if let direction { body["direction"] = ["x": direction.x, "y": direction.y, "z": direction.z] }
        }
        if let game = (isRobot ? remoteRound : localRound),
           let data = try? JSONEncoder().encode(game),
           let value = try? JSONSerialization.jsonObject(with: data) { body["game"] = value }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let current = generation
        request = http.dataTask(with: req) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self, self.generation == current else { return }
                self.request = nil
                let httpCode = (response as? HTTPURLResponse)?.statusCode
                if error == nil, httpCode == 200,
                   let data, let reply = try? JSONDecoder().decode(PiReply.self, from: data), let status = reply.drive {
                    self.applyBeamReply(reply.beam)
                    self.piUnavailable = false
                    self.uploadBackoff = 0.25
                    self.nextUploadAt = .distantPast
                    self.applyDrive(status)
                    if self.delivery != "Connected to Pi" { self.delivery = "Connected to Pi" }
                } else {
                    self.piUnavailable = true
                    self.driveStatus = nil; self.driveUpdated = nil
                    // Slow connection attempts without changing the independent control watchdog.
                    self.nextUploadAt = Date().addingTimeInterval(self.uploadBackoff)
                    self.uploadBackoff = min(4, self.uploadBackoff * 2)
                    let message = httpCode == 401 ? "Pi token rejected. Check Connect settings." : "Pi unavailable · retrying automatically"
                    if self.delivery != message { self.delivery = message }
                }
            }
        }
        request?.resume()
    }

    func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
        guard session === ni, let object = nearbyObjects.first(where: { $0.discoveryToken == peerToken }) else { return }
        distance = object.distance; direction = object.direction; horizontalAngle = object.horizontalAngle
        updated = (distance != nil || direction != nil || horizontalAngle != nil) ? Date() : nil
        status = "Ranging"
    }
    func session(_ session: NISession, didRemove nearbyObjects: [NINearbyObject], reason: NINearbyObject.RemovalReason) {
        guard session === ni else { return }
        clear()
        if reason == .timeout { range() }
        else { stop(); status = "Peer session ended. Start both phones again." }
    }
    func session(_ session: NISession, didUpdateAlgorithmConvergence value: NIAlgorithmConvergence, for object: NINearbyObject?) {
        guard session === ni else { return }
        switch value.status {
        case .converged: convergence = "Ready"
        case .notConverged(let reasons): convergence = "Move phone to calibrate · " + reasons.map { String(describing: $0) }.joined(separator: ", ")
        default: convergence = "Finding visual detail"
        }
    }
    func sessionWasSuspended(_ session: NISession) {
        guard session === ni else { return }; clear(); status = "Ranging suspended"
    }
    func sessionSuspensionEnded(_ session: NISession) {
        guard session === ni else { return }; range()
    }
    func session(_ session: NISession, didInvalidateWith error: Error) {
        guard session === ni else { return }; stop(); status = "UWB: \(error.localizedDescription). Restart both phones."
    }
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async { [weak self] in
            guard let self, session === self.mpc else { return }
            if state == .connected {
                self.connected = true
                self.advertiser?.stopAdvertisingPeer(); self.browser?.stopBrowsingForPeers()
                self.peerName = peerID.displayName; self.sendToken()
                if self.inspectionActive { self.sendMessage(kind: "inspection", value: true) }
                if !self.isRobot, let round = self.localRound { self.publishRound(round) }
            }
            else if state == .notConnected { self.stop(); self.status = "Disconnected. Start both phones again." }
            else { self.status = "Connecting" }
        }
    }
    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        DispatchQueue.main.async { [weak self] in
            guard let self, session === self.mpc else { return }
            do {
                let message = try JSONDecoder().decode(PeerMessage.self, from: data)
                switch message.kind {
                case "token":
                    guard let token = try NSKeyedUnarchiver.unarchivedObject(ofClass: NIDiscoveryToken.self, from: message.payload) else { return }
                    self.peerToken = token; self.range()
                case "round" where self.isRobot:
                    self.remoteRound = try JSONDecoder().decode(RoundState.self, from: message.payload)
                case "inspection" where !self.isRobot:
                    self.remoteInspection = try JSONDecoder().decode(Bool.self, from: message.payload)
                    if self.remoteInspection { self.stopMotion() }
                case "drive" where !self.isRobot:
                    self.driveStatus = try JSONDecoder().decode(DriveStatus.self, from: message.payload)
                    self.driveUpdated = .now
                default: break
                }
            } catch { self.status = "Could not read peer message. Install the same app on both phones." }
        }
    }
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self, advertiser === self.advertiser, let session = self.mpc, session.connectedPeers.isEmpty else { invitationHandler(false, nil); return }
            invitationHandler(true, session)
        }
    }
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, browser === self.browser, let session = self.mpc, session.connectedPeers.isEmpty else { return }
            browser.invitePeer(peerID, to: session, withContext: nil, timeout: 15)
        }
    }
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        DispatchQueue.main.async { [weak self] in self?.stop(); self?.status = "Discovery: \(error.localizedDescription)" }
    }
    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        DispatchQueue.main.async { [weak self] in self?.stop(); self?.status = "Discovery: \(error.localizedDescription)" }
    }
    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}
