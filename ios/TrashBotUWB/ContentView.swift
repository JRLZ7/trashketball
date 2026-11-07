import SwiftUI
import Combine
import NearbyInteraction

private let orange = Color(red: 1, green: 0.37, blue: 0.12)
private let ink = Color(red: 0.045, green: 0.055, blue: 0.07)
private let panel = Color(red: 0.09, green: 0.105, blue: 0.125)

struct ContentView: View {
    @StateObject private var model = RangingModel()
    @StateObject private var game = GameStore()
    @AppStorage("role") private var role = "User"
    @AppStorage("receiver") private var receiver = ""
    @State private var token = ""
    @State private var selectedTab = 0
    @Environment(\.scenePhase) private var scenePhase
    private let clock = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()
    private var isRobot: Bool { role == "Robot" }
    private var round: RoundState { isRobot ? model.remoteRound ?? RoundState() : game.round }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack { play }.tabItem { Label("Play", systemImage: "basketball.fill") }.tag(0)
            NavigationStack { tracking }.tabItem { Label("Locate", systemImage: "location.north.circle.fill") }.tag(1)
            NavigationStack { setup }.tabItem { Label("Connect", systemImage: "antenna.radiowaves.left.and.right") }.tag(2)
        }
        .tint(orange)
        .onReceive(clock) { _ in if !isRobot { game.tick() } }
        .onChange(of: game.round) { _, value in if !isRobot { model.publishRound(value) } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.stop() }
        }
    }

    private var play: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("PAPER. AIM. GLORY.").font(.caption.weight(.heavy)).tracking(2).foregroundStyle(orange)
                        Text("Trashketball").font(.system(size: 36, weight: .black, design: .rounded))
                    }
                    Spacer()
                    Image(systemName: "trash.circle.fill").font(.system(size: 44)).foregroundStyle(orange)
                }
                connectionBanner
                TimelineView(.periodic(from: .now, by: 0.25)) { context in
                    let active = round.isActive(at: context.date)
                    VStack(spacing: 20) {
                        HStack {
                            capsule(round.finished ? "ROUND COMPLETE" : active ? "ROUND LIVE" : "READY TO PLAY", color: active ? .green : orange)
                            Spacer()
                            Label("\(round.secondsRemaining(at: context.date))s", systemImage: "timer")
                                .font(.title3.monospacedDigit().weight(.bold))
                        }
                        Text("\(round.score)").font(.system(size: 112, weight: .black, design: .rounded)).monospacedDigit()
                            .contentTransition(.numericText())
                        Text("POINTS").font(.caption.weight(.heavy)).tracking(4).foregroundStyle(.secondary)
                        HStack(spacing: 0) {
                            stat("BASKETS", "\(round.baskets)")
                            stat("ATTEMPTS", "\(round.shots.count)")
                            stat("DISTANCE", "\(round.targetMeters)m")
                        }
                        if !isRobot {
                            if active {
                                HStack {
                                    Button { game.record(made: true) } label: {
                                        Label("Made it +\(round.targetMeters)", systemImage: "checkmark.circle.fill").frame(maxWidth: .infinity)
                                    }.buttonStyle(ActionStyle())
                                    Button { game.record(made: false) } label: { Text("Miss").frame(minHeight: 30) }
                                        .buttonStyle(.bordered).tint(.gray)
                                }
                                HStack {
                                    Button("Undo last shot", systemImage: "arrow.uturn.backward") { game.undo() }
                                        .disabled(round.shots.isEmpty)
                                    Spacer()
                                    Button("End round") { game.end() }.foregroundStyle(.secondary)
                                }.font(.subheadline)
                            } else {
                                Button { round.finished ? game.reset() : game.start() } label: {
                                    Label(round.finished ? "Play again" : "Start round", systemImage: "play.fill").frame(maxWidth: .infinity)
                                }.buttonStyle(ActionStyle())
                            }
                        } else {
                            Text(model.connected ? "Player controls the round. Keep this phone mounted and open." : "Connect the player’s phone to show the live round here.")
                                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                    }.padding(22).background(panel, in: RoundedRectangle(cornerRadius: 28))
                }
                if !isRobot && round.startedAt == nil {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Set your challenge").font(.title3.bold())
                        Picker("Throwing distance", selection: Binding(get: { game.round.targetMeters }, set: { game.configure(target: $0) })) {
                            ForEach(1...3, id: \.self) { Text("\($0)m · \($0) pt").tag($0) }
                        }.pickerStyle(.segmented)
                        Picker("Round length", selection: Binding(get: { game.round.durationSeconds }, set: { game.configure(duration: $0) })) {
                            ForEach([30, 60, 90], id: \.self) { Text("\($0)s").tag($0) }
                        }.pickerStyle(.segmented)
                        Text("Points follow your selected throwing distance. Tap Made it or Miss after each throw.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }.card()
                }
                if !isRobot {
                    HStack { Label("Personal best", systemImage: "trophy.fill").foregroundStyle(orange); Spacer(); Text("\(game.best) pts").bold().monospacedDigit() }.card()
                }
            }.padding(20)
        }.background(ink).toolbar(.hidden, for: .navigationBar)
    }

    private var connectionBanner: some View {
        Button { selectedTab = 2 } label: {
            HStack(spacing: 10) {
                Circle().fill(model.connected ? Color.green : orange).frame(width: 8, height: 8)
                Text(model.connected ? (isRobot ? "Player connected" : "Can connected") : model.running ? "Finding your teammate…" : "Connect your phones")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Image(systemName: "chevron.right").font(.caption.bold())
            }.foregroundStyle(.white).padding(15).background(panel, in: RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain)
    }

    private var tracking: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(isRobot ? "Find the player" : "Find your can").font(.largeTitle.weight(.black))
                Text("A live view relative to this phone. Point its rear camera toward the other phone.")
                    .font(.subheadline).foregroundStyle(.secondary)
                TimelineView(.periodic(from: .now, by: 0.2)) { context in
                    let fresh = model.isFresh(at: context.date)
                    let bearing = model.bearing(at: context.date)
                    VStack(spacing: 16) {
                        RadarView(angle: bearing, distance: fresh ? model.distance : nil, isRobot: isRobot)
                            .frame(height: 280)
                        HStack {
                            stat("DISTANCE", fresh ? model.distance.map { String(format: "%.2f m", $0) } ?? "—" : "—")
                            stat("BEARING", bearing.map { String(format: "%.0f°", $0 * 180 / .pi) } ?? "—")
                        }
                        capsule(!fresh ? "WAITING FOR TRACKING" : bearing == nil ? "DISTANCE ONLY" : "LIVE POSITION", color: bearing == nil ? orange : .green)
                    }.card()
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Text("Bring the basket to you").font(.title3.bold()); Spacer(); capsule("DRIVE OFFLINE", color: .gray) }
                    if !isRobot {
                        Button { model.sendIntent(action: "summon", targetMeters: round.targetMeters) } label: {
                            Label("Summon · stop \(round.targetMeters)m away", systemImage: "location.fill").frame(maxWidth: .infinity)
                        }.buttonStyle(ActionStyle()).disabled(!model.connected)
                        Button { model.sendIntent(action: "stop", targetMeters: round.targetMeters) } label: {
                            Label("Request stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
                        }.buttonStyle(.bordered).tint(.red).disabled(!model.connected)
                    }
                    Text(model.intentStatus).font(.footnote).foregroundStyle(.secondary)
                    Text("Requests reach the can’s phone. Motor control is awaiting integration; this is not a physical emergency stop.")
                        .font(.footnote).foregroundStyle(.secondary)
                }.card()
                VStack(alignment: .leading, spacing: 10) {
                    Label("Tracking guidance", systemImage: "viewfinder").font(.headline)
                    Text(model.convergence).font(.subheadline)
                    Text("If movement is insufficient, gently translate and sweep the phone in a well-lit space. Tracking may need calibration again after reconnecting.")
                        .font(.footnote).foregroundStyle(.secondary)
                }.card()
            }.padding(20)
        }.background(ink).toolbar(.hidden, for: .navigationBar)
    }

    private var setup: some View {
        Form {
            Section {
                Text("Two phones. One moving basket.").font(.title2.weight(.black))
                Text("Use the same app on both phones. Pick a role, connect, then calibrate tracking.").foregroundStyle(.secondary)
            }
            Section("1 · Choose this phone’s role") {
                Picker("Role", selection: $role) { Text("Player").tag("User"); Text("On the can").tag("Robot") }
                    .pickerStyle(.segmented).disabled(model.running)
                Toggle("Camera-assisted bearing", isOn: $model.cameraAssistance)
                    .disabled(model.running || !NISession.deviceCapabilities.supportsCameraAssistance)
            }
            Section("2 · Raspberry Pi · optional") {
                TextField("http://192.168.1.20:5001", text: $receiver)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().disabled(model.running)
                SecureField("API token", text: $token).disabled(model.running)
                Text("Leave the URL empty for phone-only play. Tokens stay in memory; enter again after relaunch.").font(.footnote)
            }
            Section("3 · Connect both phones") {
                Button(model.running ? "Disconnect" : "Connect phones", systemImage: model.running ? "xmark.circle" : "antenna.radiowaves.left.and.right") {
                    if model.running { model.stop() }
                    else { model.publishRound(game.round); model.start(role: role, receiver: receiver, token: token) }
                }
                LabeledContent("Session", value: model.status)
                LabeledContent("Other phone", value: model.peerName)
                LabeledContent("Pi telemetry", value: model.delivery)
            }
            Section("Diagnostics") {
                Text(model.capabilities).font(.footnote)
                Text("Instantaneous 3D direction can be unsupported while camera-assisted horizontal bearing works. Keep both apps open.").font(.footnote)
                LabeledContent("Calibration", value: model.convergence)
                TimelineView(.periodic(from: .now, by: 0.25)) { context in
                    LabeledContent("Direction x/y/z", value: model.isFresh(at: context.date) ? model.direction.map { String(format: "%.2f / %.2f / %.2f", $0.x, $0.y, $0.z) } ?? "Unavailable" : "—")
                }
            }
        }.scrollContentBackground(.hidden).background(ink).navigationTitle("Get connected")
    }

    private func capsule(_ text: String, color: Color) -> some View {
        Text(text).font(.system(size: 10, weight: .heavy)).tracking(1).foregroundStyle(color)
            .padding(.horizontal, 10).padding(.vertical, 7).background(color.opacity(0.12), in: Capsule())
    }
    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 6) { Text(value).font(.title2.weight(.bold)).monospacedDigit(); Text(label).font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(.secondary) }.frame(maxWidth: .infinity)
    }
}

private struct RadarView: View {
    let angle: Float?
    let distance: Float?
    let isRobot: Bool
    var body: some View {
        GeometryReader { proxy in
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            let radius = min(proxy.size.width, proxy.size.height) * 0.39
            ZStack {
                Canvas { context, size in
                    for fraction in [0.33, 0.66, 1.0] {
                        let r = radius * fraction
                        context.stroke(Path(ellipseIn: CGRect(x: center.x-r, y: center.y-r, width: r*2, height: r*2)), with: .color(.white.opacity(0.12)), lineWidth: 1)
                    }
                    var cross = Path(); cross.move(to: CGPoint(x: center.x, y: center.y-radius)); cross.addLine(to: CGPoint(x: center.x, y: center.y+radius)); cross.move(to: CGPoint(x: center.x-radius, y: center.y)); cross.addLine(to: CGPoint(x: center.x+radius, y: center.y))
                    context.stroke(cross, with: .color(.white.opacity(0.08)), style: StrokeStyle(lineWidth: 1, dash: [3, 5]))
                }
                Text("REAR CAMERA / FORWARD").font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(.secondary).position(x: center.x, y: 8)
                Image(systemName: "iphone.gen3").font(.title2).foregroundStyle(.white).position(center)
                if let angle, let distance {
                    let r = radius * min(max(Double(distance) / 6, 0.12), 1)
                    let target = CGPoint(x: center.x + sin(Double(angle)) * r, y: center.y - cos(Double(angle)) * r)
                    Image(systemName: isRobot ? "person.fill" : "trash.fill").font(.title3.bold()).foregroundStyle(.black)
                        .frame(width: 42, height: 42).background(orange, in: Circle()).shadow(color: orange.opacity(0.35), radius: 14).position(target)
                } else {
                    Text(distance == nil ? "Connect to locate" : "Move phone to find bearing").font(.caption).foregroundStyle(.secondary).position(x: center.x, y: center.y + 40)
                }
                Text("6 m display radius · relative view").font(.caption2).foregroundStyle(.secondary).position(x: center.x, y: proxy.size.height-8)
            }
        }.accessibilityElement(children: .ignore).accessibilityLabel(angle == nil ? "Bearing unavailable" : "Relative target bearing available")
    }
}

private struct ActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.headline).foregroundStyle(.black).padding(.vertical, 16).padding(.horizontal, 14)
            .background(orange.opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.3), in: RoundedRectangle(cornerRadius: 16))
    }
}
private extension View {
    func card() -> some View { padding(20).background(panel, in: RoundedRectangle(cornerRadius: 24)) }
}
