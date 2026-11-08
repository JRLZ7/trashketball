import Foundation
import Combine

struct Shot: Codable, Identifiable, Equatable {
    var id = UUID()
    var made: Bool
    var points: Int
}

struct RoundState: Codable, Equatable {
    var id = UUID()
    var startedAt: Date?
    var endsAt: Date?
    var finished = false
    var targetMeters = 2
    var durationSeconds = 30
    var shots: [Shot] = []
    var score: Int { shots.reduce(0) { $0 + $1.points } }
    var baskets: Int { shots.filter(\.made).count }
    func secondsRemaining(at now: Date) -> Int {
        guard let endsAt else { return durationSeconds }
        return max(0, Int(ceil(endsAt.timeIntervalSince(now))))
    }
    func isActive(at now: Date) -> Bool { startedAt != nil && !finished && secondsRemaining(at: now) > 0 }
}

final class GameStore: ObservableObject {
    @Published private(set) var round = RoundState()
    @Published private(set) var best: Int
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        best = defaults.integer(forKey: "trashketball.best")
    }
    func configure(target: Int? = nil, duration: Int? = nil) {
        guard round.startedAt == nil else { return }
        if let target, (1...3).contains(target) { round.targetMeters = target }
        if let duration, [30, 60, 90].contains(duration) { round.durationSeconds = duration }
    }
    func start(now: Date = .now) {
        guard !round.isActive(at: now) else { return }
        round = RoundState(startedAt: now, endsAt: now.addingTimeInterval(Double(round.durationSeconds)),
                           targetMeters: round.targetMeters, durationSeconds: round.durationSeconds)
    }
    func record(made: Bool, now: Date = .now) {
        guard round.isActive(at: now), round.shots.count < 256 else { return }
        round.shots.append(Shot(made: made, points: made ? 1 : 0))
        saveBest()
    }
    func applyBeam(_ status: BeamStatus) {
        guard let start = round.startedAt, let end = round.endsAt else { return }
        var known = Set(round.shots.map(\.id))
        let additions = status.events.filter { event in
            event.roundID == round.id && event.timestamp.isFinite &&
            event.timestamp >= start.timeIntervalSince1970 && event.timestamp < end.timeIntervalSince1970 &&
            event.points == 1 && known.insert(event.id).inserted
        }.prefix(max(0, 256 - round.shots.count))
        guard !additions.isEmpty else { return }
        round.shots.append(contentsOf: additions.map { Shot(id: $0.id, made: true, points: $0.points) })
        saveBest()
    }
    func undo(now: Date = .now) {
        guard round.isActive(at: now), !round.shots.isEmpty else { return }
        round.shots.removeLast()
        // Best is committed at round end, so undo never leaves a phantom record.
    }
    func tick(now: Date = .now) {
        if round.startedAt != nil && !round.finished && round.secondsRemaining(at: now) == 0 { end(now: now) }
    }
    func end(now: Date = .now) {
        guard round.startedAt != nil else { return }
        if let deadline = round.endsAt, now < deadline { round.endsAt = now }
        round.finished = true
        saveBest()
    }
    func reset() {
        if round.startedAt != nil { end() }
        round = RoundState(targetMeters: round.targetMeters, durationSeconds: round.durationSeconds)
    }
    private func saveBest() {
        guard round.finished, round.score > best else { return }
        best = round.score
        defaults.set(best, forKey: "trashketball.best")
    }
}

struct PeerMessage: Codable {
    var kind: String
    var payload: Data
}

struct DriveStatus: Codable {
    var enabled: Bool
    var state: String
    var message: String
    var summonReady: Bool
    var left: Double
    var right: Double
    var commandID: String?
}

struct PiReply: Decodable {
    var drive: DriveStatus?
    var error: String?
    var beam: BeamStatus?
}

struct MotionCommand: Codable, Equatable {
    var id = UUID().uuidString
    var client_id: String
    var sequence: Int
    var sent_at: Double
    var action: String
    var targetMeters: Int
    var speed: Int
}

struct BeamEvent: Codable, Equatable {
    var id: UUID
    var roundID: UUID
    var timestamp: Double
    var points: Int
}

struct BeamStatus: Codable, Equatable {
    var available: Bool
    var pin: Int
    var blocked: Bool?
    var message: String
    var breakCount: Int
    var events: [BeamEvent]
}

// Only intent/status crosses phones. The mounted phone remains the navigation authority.
struct GuidanceRequest: Codable {
    enum Action: String, Codable { case preview, start, endPreview, stop }
    var id = UUID()
    var action: Action
    var target: Int
    var sentAt = Date().timeIntervalSince1970
    func isValid(at now: TimeInterval) -> Bool {
        action == .stop || ((1...3).contains(target) && sentAt.isFinite &&
            now-sentAt >= -2 && now-sentAt < 2)
    }
}

struct GuidanceStatus: Codable {
    var sequence: Int
    var requestID: UUID?
    var previewing: Bool
    var active: Bool
    var paused: Bool
    var target: Int
    var decision: ApproachDecision
    var note: String
    var canPreview: Bool
    var canStart: Bool
    var floor: String
}

// A brief missing measurement stops the motors without immediately disarming navigation.
// Resume requires three distinct, safe depth frames AND distinct UWB updates after the hold.
struct GuidanceSensorHold {
    private(set) var began: TimeInterval?
    private var stableFrames = 0
    private var lastDepth: TimeInterval?
    private var lastUWB: TimeInterval?
    mutating func reset() { self = Self() }
    mutating func pause(at now: TimeInterval) {
        if began == nil { began = now }
        stableFrames = 0; lastDepth = nil; lastUWB = nil
    }
    func expired(at now: TimeInterval) -> Bool { began.map { now-$0 >= 2 } ?? false }
    mutating func ready(depth: TimeInterval, uwb: TimeInterval) -> Bool {
        guard let began, depth > began, uwb > began else { return false }
        guard lastDepth != depth, lastUWB != uwb else { return false }
        lastDepth = depth; lastUWB = uwb; stableFrames += 1
        return stableFrames >= 3
    }
}

// A successful HTTP response alone does not prove the Pi owns this live command.
enum GuidancePiConfirmation {
    static func movement(_ command: MotionCommand, reply: PiReply, httpCode: Int?, failed: Bool,
                         now: TimeInterval) -> Bool {
        let age = now-command.sent_at
        guard age.isFinite, age >= 0, age < 0.25, !failed, httpCode == 200,
              reply.error == nil, let status = reply.drive else { return false }
        return status.enabled && status.state == "manual" && status.commandID == command.id
    }
    static func stopped(reply: PiReply, httpCode: Int?, failed: Bool) -> Bool {
        guard !failed, httpCode == 200, reply.error == nil, let status = reply.drive else { return false }
        return status.enabled && status.state == "stopped" && status.commandID == nil &&
            status.left == 0 && status.right == 0
    }
}
