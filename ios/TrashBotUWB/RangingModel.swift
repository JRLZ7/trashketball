import SwiftUI
import NearbyInteraction
import MultipeerConnectivity

// Keep all NI/MPC state on the main queue. Delegate callbacks hop to it below.
final class RangingModel: NSObject, ObservableObject, NISessionDelegate, MCSessionDelegate, MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate {
    @Published var running = false
    @Published var connected = false
    @Published var remoteRound: RoundState?
    @Published var latestIntent: RobotIntent?
    @Published var intentStatus = "No request sent"
    private var localRound: RoundState?
    var isRobot: Bool { role == "Robot" }
    func isFresh(at date: Date) -> Bool { updated.map { date.timeIntervalSince($0) >= 0 && date.timeIntervalSince($0) < 1 } ?? false }
    func bearing(at date: Date) -> Float? {
        guard isFresh(at: date) else { return nil }
        if let horizontalAngle { return horizontalAngle }
        if let direction { return atan2(direction.x, -direction.z) }
        return nil
    }
    func publishRound(_ round: RoundState) {
        localRound = round
        if connected && !isRobot { sendMessage(kind: "round", value: round) }
    }
    func sendIntent(action: String, targetMeters: Int) {
        guard connected, !isRobot, ["summon", "stop"].contains(action) else { intentStatus = "Connect to the can first"; return }
        if action == "summon" && (!isFresh(at: .now) || distance == nil || bearing(at: .now) == nil) {
            intentStatus = "Wait for live distance and bearing"; return
        }
        let intent = RobotIntent(action: action, targetMeters: targetMeters)
        if sendMessage(kind: "intent", value: intent) {
            latestIntent = intent
            intentStatus = action == "stop" ? "Stop sent · awaiting can receipt" : "Summon sent · awaiting can receipt"
        }
    }
    @discardableResult private func sendMessage<T: Encodable>(kind: String, value: T) -> Bool {
        guard let mpc, !mpc.connectedPeers.isEmpty else { return false }
        do {
            let message = PeerMessage(kind: kind, payload: try JSONEncoder().encode(value))
            try mpc.send(JSONEncoder().encode(message), toPeers: mpc.connectedPeers, with: .reliable)
            return true
        } catch { status = "Peer send failed: \(error.localizedDescription)"; return false }
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
        running = true
        UIApplication.shared.isIdleTimerDisabled = true
        delivery = endpoint == nil ? "Phone-only test" : "Waiting to send"
        let ranging = NISession()
        ranging.delegate = self
        ranging.delegateQueue = .main
        ni = ranging
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
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.upload() }
    }

    func stop() {
        generation = UUID()
        timer?.invalidate(); timer = nil
        request?.cancel(); request = nil
        advertiser?.stopAdvertisingPeer(); advertiser = nil
        browser?.stopBrowsingForPeers(); browser = nil
        mpc?.delegate = nil; mpc?.disconnect(); mpc = nil
        ni?.delegate = nil; ni?.invalidate(); ni = nil
        peerToken = nil
        clear()
        connected = false; remoteRound = nil; latestIntent = nil; intentStatus = "No request sent"
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
            try session.send(envelope, toPeers: session.connectedPeers, with: .reliable)
        } catch { status = "Token send failed: \(error.localizedDescription)" }
    }
    private func range() {
        guard let token = peerToken, let ni else { return }
        let config = NINearbyPeerConfiguration(peerToken: token)
        config.isCameraAssistanceEnabled = cameraAssistance && NISession.deviceCapabilities.supportsCameraAssistance
        config.isExtendedDistanceMeasurementEnabled = NISession.deviceCapabilities.supportsExtendedDistanceMeasurement && token.deviceCapabilities.supportsExtendedDistanceMeasurement
        convergence = config.isCameraAssistanceEnabled ? "Waiting for camera-assisted calibration" : "Camera assistance off"
        ni.run(config)
        status = "Ranging · keep phones oriented toward each other"
    }

    private func upload() {
        guard running, let endpoint, request == nil else { return }
        let age = updated.map { Date().timeIntervalSince($0) }
        let fresh = age.map { $0 < 1 } ?? false
        var body: [String: Any] = ["device_id": deviceID, "role": role.lowercased(), "fresh": fresh,
            "distance_m": NSNull(), "direction": NSNull(), "horizontal_angle_rad": NSNull(), "age_s": age.map { $0 as Any } ?? NSNull()]
        if fresh {
            if let distance { body["distance_m"] = distance }
            if let horizontalAngle { body["horizontal_angle_rad"] = horizontalAngle }
            if let direction { body["direction"] = ["x": direction.x, "y": direction.y, "z": direction.z] }
        }
        if let game = (isRobot ? remoteRound : localRound),
           let data = try? JSONEncoder().encode(game),
           let value = try? JSONSerialization.jsonObject(with: data) { body["game"] = value }
        if let intent = latestIntent,
           let data = try? JSONEncoder().encode(intent),
           let value = try? JSONSerialization.jsonObject(with: data) { body["intent"] = value }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let current = generation
        request = http.dataTask(with: req) { [weak self] _, response, error in
            DispatchQueue.main.async {
                guard let self, self.generation == current else { return }
                self.request = nil
                if let error { self.delivery = error.localizedDescription }
                else if let response = response as? HTTPURLResponse { self.delivery = response.statusCode == 200 ? "Receiving on Pi" : "Pi HTTP \(response.statusCode)" }
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
                case "intent" where self.isRobot:
                    let intent = try JSONDecoder().decode(RobotIntent.self, from: message.payload)
                    guard ["summon", "stop"].contains(intent.action), (1...3).contains(intent.targetMeters) else { return }
                    self.latestIntent = intent
                    self.intentStatus = intent.action == "stop" ? "Stop received · driver not connected" : "Summon received · driver not connected"
                    self.sendMessage(kind: "receipt", value: intent)
                case "receipt" where !self.isRobot:
                    let receipt = try JSONDecoder().decode(RobotIntent.self, from: message.payload)
                    if receipt.id == self.latestIntent?.id {
                        self.intentStatus = "Can received request · driver not connected"
                    }
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
