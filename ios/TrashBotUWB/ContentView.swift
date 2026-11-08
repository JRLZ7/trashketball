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
    @AppStorage("driveSpeedV3") private var driveSpeed = 100
    private let token = "12345"
    @State private var selectedTab = 0
    @Environment(\.scenePhase) private var scenePhase
    private let clock = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()
    private let waitingRound = RoundState()
    private var isRobot: Bool { role == "Robot" }
    private var round: RoundState { isRobot ? model.remoteRound ?? waitingRound : game.round }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack { play }.tabItem { Label("Play", systemImage: "basketball.fill") }.tag(0)
            NavigationStack { tracking }.tabItem { Label("Locate", systemImage: "location.north.circle.fill") }.tag(1)
            NavigationStack {
                if isRobot {
                    LidarDebugView(model: model, receiver: receiver)
                } else {
                    ContentUnavailableView("Use the can’s phone", systemImage: "camera.viewfinder", description: Text("Choose On the can in Connect to inspect LiDAR on the mounted phone."))
                }
            }.tabItem { Label("Lab", systemImage: "camera.viewfinder") }.tag(3)
            NavigationStack { setup }.tabItem { Label("Connect", systemImage: "antenna.radiowaves.left.and.right") }.tag(2)
        }
        .tint(orange)
        .onReceive(clock) { _ in if !isRobot { game.tick() } }
        .onChange(of: model.beamStatus) { _, beam in if !isRobot, let beam { game.applyBeam(beam) } }
        .onChange(of: game.round) { _, value in if !isRobot { model.publishRound(value) } }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model.stopMotion() }
            if phase == .background { model.exitInspection(); model.stop() }
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
                        Text("MAKES").font(.caption.weight(.heavy)).tracking(4).foregroundStyle(.secondary)
                        HStack(spacing: 0) {
                            stat("BASKETS", "\(round.baskets)")
                            stat("SCORING", "IR beam")
                            stat("DISTANCE", "\(round.targetMeters)m")
                        }
                        if !isRobot {
                            if active {
                                Label("Make it. We’ll count it.", systemImage: "basketball.fill")
                                    .font(.subheadline).foregroundStyle(.secondary)
                                Button("End round") { game.end() }.font(.subheadline)
                            } else {
                                Button { round.finished ? game.reset() : game.start() } label: {
                                    Label(round.finished ? "Play again" : "Start round", systemImage: "play.fill").frame(maxWidth: .infinity)
                                }.buttonStyle(ActionStyle()).disabled(!round.finished && (!model.beamIsLive(at: context.date) || model.beamStatus?.available != true))
                            }
                        } else {
                            Text(model.connected ? "Player controls the round. Keep this phone mounted and open." : "Connect the player’s phone to show the live round here.")
                                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                    }.padding(22).background(panel, in: RoundedRectangle(cornerRadius: 28))
                }
                TimelineView(.periodic(from: .now, by: 0.25)) { context in
                    let live = model.beamIsLive(at: context.date)
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Automatic scoring", systemImage: "basketball.fill").font(.headline)
                        Text(!live ? "Scoring offline · connect to the Pi" : model.beamStatus?.available != true ? model.beamStatus?.message ?? "Sensor unavailable" : "Ready · each basket counts as one make")
                            .font(.subheadline).foregroundStyle(live && model.beamStatus?.available == true ? .green : .orange)
                    }.card()
                }
                if !isRobot && round.startedAt == nil {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Set your challenge").font(.title3.bold())
                        Picker("Throwing distance", selection: Binding(get: { game.round.targetMeters }, set: { game.configure(target: $0) })) {
                            ForEach(1...3, id: \.self) { Text("\($0)m").tag($0) }
                        }.pickerStyle(.segmented)
                        Picker("Round length", selection: Binding(get: { game.round.durationSeconds }, set: { game.configure(duration: $0) })) {
                            ForEach([30, 60, 90], id: \.self) { Text("\($0)s").tag($0) }
                        }.pickerStyle(.segmented)
                        Text("Make a basket to add one point. Misses do not change your score. Distance only sets the can’s position.")
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
                        if !fresh {
                            ContentUnavailableView(
                                model.connected ? "Position unavailable" : "Other phone not connected",
                                systemImage: "location.slash",
                                description: Text(model.connected ? "Waiting for live distance and bearing. You can keep using the other tabs." : "Open Connect on both phones and connect them to locate each other.")
                            ).frame(minHeight: 220)
                        } else {
                        RadarView(angle: bearing, distance: fresh ? model.distance : nil, isRobot: isRobot)
                            .frame(height: 280)
                        }
                        HStack {
                            stat("DISTANCE", fresh ? model.distance.map { String(format: "%.2f m", $0) } ?? "—" : "—")
                            stat("BEARING", bearing.map { String(format: "%.0f°", $0 * 180 / .pi) } ?? "—")
                        }
                        capsule(!fresh ? "WAITING FOR TRACKING" : bearing == nil ? "DISTANCE ONLY" : "LIVE POSITION", color: bearing == nil ? orange : .green)
                    }.card()
                }
                if isRobot { guidedApproachCard }
                TimelineView(.periodic(from: .now, by: 0.2)) { context in
                    let live = model.driveIsLive(at: context.date)
                    let ready = live && model.driveStatus?.enabled == true && model.canControlPi && !model.remoteInspection && !model.remoteApproach && !model.inspectionActive && model.driveStatus?.state != "inspection" && model.driveStatus?.state != "fault"
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text(isRobot ? "Motor status" : "Move the basket").font(.title3.bold())
                            Spacer()
                            capsule(live ? (model.driveStatus?.state.uppercased() ?? "OFFLINE") : "OFFLINE", color: ready ? .green : .gray)
                        }
                        Text(live ? model.driveStatus?.message ?? "Waiting for Pi" : model.piUnavailable ? "Pi unavailable. Start the server; this screen will reconnect automatically." : "Pi not connected. Tracking between phones can still work without it.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        if !isRobot {
                            Text("Hold an arrow to drive. Release to stop.").font(.footnote).foregroundStyle(.secondary)
                            HStack {
                                Text("Speed").font(.subheadline)
                                Slider(value: Binding(get: { Double(driveSpeed) }, set: { driveSpeed = Int($0) }), in: 20...100, step: 5)
                                    .disabled(model.activeAction != nil)
                                Text("\(driveSpeed)%").font(.subheadline.monospacedDigit()).frame(width: 40)
                            }
                            VStack(spacing: 10) {
                                holdButton("Forward", symbol: "arrow.up", action: "forward", enabled: ready)
                                HStack(spacing: 12) {
                                    holdButton("Left", symbol: "arrow.turn.up.left", action: "left", enabled: ready)
                                    Button { model.stopMotion() } label: {
                                        Image(systemName: "stop.fill").font(.title2.bold()).frame(width: 64, height: 64)
                                    }.buttonStyle(.borderedProminent).tint(.red).disabled(!model.running)
                                    holdButton("Right", symbol: "arrow.turn.up.right", action: "right", enabled: ready)
                                }
                                holdButton("Reverse", symbol: "arrow.down", action: "reverse", enabled: ready)
                            }.frame(maxWidth: .infinity)
                            Divider()
                            Button { model.sendIntent(action: "summon", targetMeters: round.targetMeters, speed: driveSpeed) } label: {
                                Label("Legacy Summon · \(round.targetMeters)m away", systemImage: "location.fill").frame(maxWidth: .infinity)
                            }.buttonStyle(ActionStyle()).disabled(!ready || model.driveStatus?.summonReady != true || !model.connected)
                            Text(model.remoteApproach ? "Can phone is running guided approach. Stop remains available." : "Legacy Summon has no LiDAR obstacle checks. Use Guided approach in Locate on the can phone for the new mode.")
                                .font(.footnote).foregroundStyle(.secondary)
                            if ready && model.driveStatus?.summonReady != true {
                                Text("Manual drive is ready. Summon is disabled in the Pi configuration.").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        if let error = model.driveError {
                            Label(error, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.orange)
                        }
                        Text("Pi stops after 0.3 s without commands. Keep the arena clear and the physical kill switch accessible.").font(.footnote).foregroundStyle(.secondary)
                    }.card()
                }
                VStack(alignment: .leading, spacing: 10) {
                    Label("Tracking guidance", systemImage: "viewfinder").font(.headline)
                    Text(model.convergence).font(.subheadline)
                    Text("If movement is insufficient, gently translate and sweep the phone in a well-lit space. Tracking may need calibration again after reconnecting.")
                        .font(.footnote).foregroundStyle(.secondary)
                }.card()
            }.padding(20)
        }.background(ink).toolbar(.hidden, for: .navigationBar)
            .onDisappear { model.endApproachPreview(); model.stopMotion() }
    }

    private var guidedApproachCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Guided approach").font(.title3.bold())
            Text("Uses Locate bearing and distance with live LiDAR. Compares left/right paths and makes short detours; stops when no observed path is available.")
                .font(.subheadline).foregroundStyle(.secondary)
            Picker("Stop distance", selection: $model.approachTarget) {
                ForEach(1...3, id: \.self) { Text("\($0) m").tag($0) }
            }.pickerStyle(.segmented).disabled(model.approachActive)
            HStack {
                Button(model.approachPreviewing ? "End preview" : "Preview guidance") {
                    if model.approachPreviewing { model.endApproachPreview() }
                    else { model.previewApproach() }
                }.buttonStyle(.bordered).disabled(!model.approachPreviewing && !model.canPreviewApproach)
                Spacer()
                if model.approachPreviewing {
                    Text(model.approachActive ? "DRIVING" : "PREVIEW").font(.caption.bold())
                        .foregroundStyle(model.approachActive ? .green : orange)
                }
            }
            Text(model.approachDecision.message).font(.headline)
            if model.approachPreviewing {
                AvoidanceFanView(scan:model.lidar.snapshot.avoidance,selectedDegrees:model.approachDecision.selectedLaneDegrees)
                    .frame(height:160)
                HStack(alignment:.top) {
                    VStack(alignment:.leading) { Text("LEFT").font(.caption.bold()); Text(avoidanceSummary(right:false)).font(.caption) }
                    Spacer()
                    VStack(alignment:.trailing) { Text("RIGHT").font(.caption.bold()); Text(avoidanceSummary(right:true)).font(.caption) }
                }
                Text("Green: observed open lane · orange: obstacle · gray: unknown · cyan: selected lane")
                    .font(.caption2).foregroundStyle(.secondary)
                if let degrees = model.approachDecision.turnDegrees, abs(degrees) > 0.5 {
                    Text(String(format:"Turn remaining: %.0f° %@",abs(degrees),degrees > 0 ? "right" : "left"))
                        .font(.subheadline.monospacedDigit())
                }
                Text("Floor: \(model.lidar.snapshot.floorStatus)").font(.caption).foregroundStyle(.secondary)
                if let height = model.lidar.snapshot.measuredCameraHeight {
                    Text(String(format: "Measured camera height: %.0f cm", height*100)).font(.caption).foregroundStyle(.secondary)
                }
                if let first = model.lidar.snapshot.corridor.firstObservedFloorDistance {
                    Text(String(format: "First visible floor: %.2f m ahead", first)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(model.approachNote).font(.footnote).foregroundStyle(.secondary)
            if model.approachActive, let drive = model.driveStatus {
                LabeledContent("Pi motor command", value: String(format:"L %.0f%% · R %.0f%%",drive.left,drive.right))
                    .font(.subheadline.monospacedDigit())
            }
            HStack {
                Button { model.beginApproach() } label: {
                    Label("Start guided approach", systemImage: "location.fill").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent)
                    .disabled(!model.approachPreviewing || model.approachActive || model.approachDecision.action == "stop" || !model.canControlPi)
                Button("Stop", role: .destructive) { model.stopMotion() }
                    .buttonStyle(.bordered).disabled(!model.running)
            }
            Text("Preview works without the Pi. Connect both phones with camera assistance on; mount the rear camera forward and tilted down to see nearby floor. The measured camera mount is 25 cm above the floor, with automatic floor confirmation. Driving sends 100% commands for forward, detours and turns, scaled by the Pi driver's PWM maximum. Side/rear blind spots remain; keep space around the can for pivots.")
                .font(.caption).foregroundStyle(.secondary)
        }.card()
    }

    private func avoidanceSummary(right: Bool) -> String {
        let lanes = model.lidar.snapshot.avoidance.lanes.filter { right ? $0.angle > 0 : $0.angle < 0 }
        if let best = lanes.filter(\.isOpen).max(by: { $0.corridor.observedFreeDistance < $1.corridor.observedFreeDistance }) {
            return String(format:"%.0f° · %.2f m observed",abs(best.angle)*180/Float.pi,best.corridor.observedFreeDistance)
        }
        if let nearest = lanes.compactMap({ $0.corridor.nearestObstacle }).min() { return String(format:"Obstacle at %.2f m",nearest) }
        return "Not enough observed floor"
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
            Section("2 · Raspberry Pi connection") {
                TextField("http://192.168.1.20:5001", text: $receiver)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().disabled(model.running)
                LabeledContent("API token", value: token)
                Text("Enter the same Pi URL on both phones. API token 12345 is already configured.").font(.footnote)
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

    private func holdButton(_ title: String, symbol: String, action: String, enabled: Bool) -> some View {
        VStack(spacing: 5) {
            Image(systemName: symbol).font(.title2.bold())
            Text(title).font(.caption.weight(.semibold))
        }
        .frame(width: 76, height: 66)
        .foregroundStyle(enabled ? .white : .gray)
        .background(model.activeAction == action ? orange : panel.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.15)))
        .onLongPressGesture(minimumDuration: 0.01, maximumDistance: 30, pressing: { pressed in
            if pressed && enabled { model.beginMotion(action: action, speed: driveSpeed) }
            else if model.activeAction == action { model.stopMotion() }
        }, perform: {})
        .accessibilityLabel("Hold to drive " + title.lowercased())
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
                ForEach([0.33, 0.66, 1.0], id: \.self) { fraction in
                    Circle().stroke(.white.opacity(0.12), lineWidth: 1)
                        .frame(width: radius * fraction * 2, height: radius * fraction * 2).position(center)
                }
                Path { path in
                    path.move(to: CGPoint(x: center.x, y: center.y-radius))
                    path.addLine(to: CGPoint(x: center.x, y: center.y+radius))
                    path.move(to: CGPoint(x: center.x-radius, y: center.y))
                    path.addLine(to: CGPoint(x: center.x+radius, y: center.y))
                }.stroke(.white.opacity(0.08), style: StrokeStyle(lineWidth: 1, dash: [3, 5]))
                Text("REAR CAMERA / FORWARD").font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(.secondary).position(x: center.x, y: 8)
                Image(systemName: "iphone.gen3").font(.title2).foregroundStyle(.white).position(center)
                if let angle, let distance, angle.isFinite, distance.isFinite {
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


private struct AvoidanceFanView: View {
    let scan: AvoidanceScan
    let selectedDegrees: Float?
    var body: some View {
        Canvas { context, size in
            let origin = CGPoint(x:size.width/2,y:size.height-18)
            let scale = min(size.width/2.8,(size.height-30)/1.4)
            func point(angle: Float, distance: Float) -> CGPoint {
                CGPoint(x:origin.x+CGFloat(sin(angle)*distance)*scale,y:origin.y-CGFloat(cos(angle)*distance)*scale)
            }
            for lane in scan.lanes {
                let degrees = lane.angle*180/Float.pi
                let selected = selectedDegrees.map { abs($0-degrees) < 1 } ?? false
                let blocked = lane.corridor.nearestObstacle.map { $0 < 0.9 } ?? false
                let color: Color = selected ? .cyan : lane.isOpen ? .green : blocked ? .orange : .gray.opacity(0.5)
                var path = Path(); path.move(to:origin); path.addLine(to:point(angle:lane.angle,distance:1.25))
                context.stroke(path,with:.color(color),style:StrokeStyle(lineWidth:selected ? 4 : 2,dash:lane.isOpen || blocked ? [] : [3,4]))
                if let obstacle = lane.corridor.nearestObstacle, obstacle < 1.4 {
                    let p = point(angle:lane.angle,distance:obstacle)
                    context.fill(Path(ellipseIn:CGRect(x:p.x-4,y:p.y-4,width:8,height:8)),with:.color(.orange))
                }
            }
            context.fill(Path(ellipseIn:CGRect(x:origin.x-6,y:origin.y-6,width:12,height:12)),with:.color(.white))
            context.draw(Text("LEFT").font(.caption2).foregroundColor(.secondary),at:CGPoint(x:24,y:size.height-12))
            context.draw(Text("RIGHT").font(.caption2).foregroundColor(.secondary),at:CGPoint(x:size.width-26,y:size.height-12))
            context.draw(Text("0°").font(.caption2).foregroundColor(.secondary),at:CGPoint(x:origin.x,y:10))
        }
        .background(Color.black.opacity(0.35),in:RoundedRectangle(cornerRadius:12))
        .accessibilityLabel("Observed left and right avoidance paths")
    }
}
