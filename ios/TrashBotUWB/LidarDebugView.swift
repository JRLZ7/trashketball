import SwiftUI
import ARKit
import simd

struct LidarDebugView: View {
    @ObservedObject var model: RangingModel
    @ObservedObject private var lidar: LidarModel
    let receiver: String
    @State private var showDepth = true
    @State private var motorPowerDisconnected = false
    @State private var visible = false
    @Environment(\.scenePhase) private var phase

    init(model: RangingModel, receiver: String) {
        self.model = model
        self.receiver = receiver
        _lidar = ObservedObject(wrappedValue: model.lidar)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("LiDAR Lab").font(.largeTitle.weight(.black))
                Text("Player + obstacle map · no driving").foregroundStyle(.orange).font(.subheadline.bold())
                VStack(alignment: .leading, spacing: 10) {
                    Label(model.inspectionMessage, systemImage: model.inspectionConfirmed ? "lock.shield.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(model.inspectionConfirmed ? .green : .orange)
                    if !model.inspectionConfirmed {
                        Toggle("Motor power is physically disconnected", isOn: $motorPowerDisconnected)
                        Text("Without a Pi-confirmed hold, disconnect the motor battery before starting this test.").font(.caption).foregroundStyle(.secondary)
                    }
                }.labCard()
                LocalMapView(lidar: lidar, model: model)
                GeometryReader { proxy in
                    ZStack {
                        if lidar.previewRunning {
                            LidarCameraView(session: lidar.session)
                            if showDepth {
                                Canvas { context, size in
                                    for dot in lidar.snapshot.dots {
                                        let point = CGPoint(x: dot.point.x*size.width, y: dot.point.y*size.height)
                                        let color: Color = dot.floor ? .green.opacity(0.5) : dot.depth < 1 ? .red.opacity(0.75) : dot.depth < 2 ? .orange.opacity(0.65) : .cyan.opacity(0.45)
                                        context.fill(Path(ellipseIn: CGRect(x: point.x-3, y: point.y-3, width: 6, height: 6)), with: .color(color))
                                    }
                                    if lidar.snapshot.polygon.count == 4 {
                                        var path = Path()
                                        path.addLines(lidar.snapshot.polygon); path.closeSubpath()
                                        context.stroke(path, with: .color(.yellow), lineWidth: 2)
                                    }
                                }.allowsHitTesting(false)
                            }
                        } else {
                            ContentUnavailableView(lidar.supportsDepth ? "Camera is stopped" : "LiDAR unavailable",
                                                   systemImage: "camera.viewfinder",
                                                   description: Text(lidar.supportsDepth ? "Start the preview to inspect the floor and obstacles." : "Use the physical LiDAR-equipped can phone. Simulator has no depth sensor."))
                        }
                    }
                    .onAppear { lidar.updateViewport(proxy.size) }
                    .onChange(of: proxy.size) { _, value in lidar.updateViewport(value) }
                }.frame(height: 420).background(.black).clipShape(RoundedRectangle(cornerRadius: 20))
                HStack {
                    Button(lidar.previewRunning ? "Stop camera" : "Start LiDAR", systemImage: lidar.previewRunning ? "stop.fill" : "camera.fill") {
                        if lidar.previewRunning { lidar.stopPreview() }
                        else {
                            if !model.inspectionActive { model.enterInspection(receiver: receiver) }
                            lidar.startPreview()
                        }
                    }.buttonStyle(.borderedProminent)
                        .disabled(!lidar.previewRunning && (!lidar.supportsDepth || (!model.inspectionConfirmed && !motorPowerDisconnected)))
                    Spacer()
                    Toggle("Depth overlay", isOn: $showDepth).labelsHidden()
                    Text("Depth").font(.caption)
                }
                TimelineView(.periodic(from: .now, by: 0.25)) { context in
                    let live = lidar.previewRunning && context.date.timeIntervalSince(lidar.snapshot.timestamp) < 0.75
                    VStack(alignment: .leading, spacing: 12) {
                        Text(live ? lidar.snapshot.corridor.message : "Unknown · no recent depth").font(.title3.bold())
                        LabeledContent("Nearest forward obstacle", value: nearestValue(live: live))
                        LabeledContent("Observed clear floor", value: live && lidar.snapshot.calibrated && lidar.snapshot.corridor.observedFreeDistance > 0 ? String(format: "%.2f m", lidar.snapshot.corridor.observedFreeDistance) : "Unknown")
                        LabeledContent("Tracking", value: live ? lidar.snapshot.tracking : "Not live")
                        LabeledContent("Usable depth", value: live ? String(format: "%.0f%%", lidar.snapshot.depthCoverage*100) : "—")
                        LabeledContent("Corridor floor coverage", value: live ? String(format: "%.0f%%", lidar.snapshot.corridor.floorCoverage*100) : "—")
                        LabeledContent("AR heading", value: live ? lidar.snapshot.yawDegrees.map { String(format: "%.0f°", $0) } ?? "Unknown" : "—")
                        Text("Heading is relative to this AR session. Unseen floor is unknown, not free space.").font(.caption).foregroundStyle(.secondary)
                    }.labCard()
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("Assumed bucket setup").font(.headline)
                    LabeledContent("Bucket width", value: "30 cm")
                    LabeledContent("Bucket height", value: "44 cm")
                    LabeledContent("Assumed camera height", value: "44 cm")
                    Text("The floor estimate initializes automatically when tracking is Normal, including after a session reset. No calibration tap is needed. Camera height temporarily assumes the lens is at bucket height.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Mount the rear camera forward and slightly down. The yellow corridor is 46 cm wide including clearance, with a 3 m lookahead.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Green dots: assumed floor. Other dots: red near, orange middle, cyan far. Colors alone are not obstacle classifications.").font(.caption).foregroundStyle(.secondary)
                    if let error = lidar.error { Text(error).font(.footnote).foregroundStyle(.orange) }
                }.labCard()
                Text("Box test: place a box in front, move it outside the yellow corridor, then remove it. Check distances against a tape measure. This experiment does not steer or avoid obstacles.").font(.footnote).foregroundStyle(.secondary)
            }.padding(20)
        }.navigationTitle("Perception").navigationBarTitleDisplayMode(.inline)
        .background(Color(red: 0.045, green: 0.055, blue: 0.07))
        .onAppear { visible = true; motorPowerDisconnected = false; model.enterInspection(receiver: receiver) }
        .onDisappear { visible = false; model.exitInspection() }
        .onChange(of: phase) { _, value in
            if value != .active { model.exitInspection() }
            else if visible { motorPowerDisconnected = false; model.enterInspection(receiver: receiver) }
        }
    }
    private func nearestValue(live: Bool) -> String {
        guard live, lidar.snapshot.calibrated else { return "Unknown" }
        if let distance = lidar.snapshot.corridor.nearestObstacle { return String(format: "%.2f m", distance) }
        return lidar.snapshot.corridor.observedFreeDistance >= 0.65 ? "None in observed area" : "Unknown"
    }
}

private struct LidarCameraView: UIViewRepresentable {
    let session: ARSession
    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session = session
        view.automaticallyUpdatesLighting = false
        view.preferredFramesPerSecond = 30
        view.isPlaying = true
        return view
    }
    func updateUIView(_ view: ARSCNView, context: Context) {}
    static func dismantleUIView(_ view: ARSCNView, coordinator: ()) { view.isPlaying = false }
}
private extension View {
    func labCard() -> some View { padding(18).frame(maxWidth: .infinity, alignment: .leading).background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 20)) }
}

private struct LocalMapView: View {
    @ObservedObject var lidar: LidarModel
    @ObservedObject var model: RangingModel
    @State private var span: Float = 8

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { tick in
            let s = lidar.snapshot
            let live = lidar.previewRunning && tick.date.timeIntervalSince(s.timestamp) < 0.75 && s.calibrated
            let target = live && model.connected && model.isFresh(at: tick.date)
                ? s.playerTarget.flatMap {  $0.isFresh(at: tick.date.timeIntervalSince1970) ? $0 : nil } : nil
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Local map").font(.headline)
                    Spacer()
                    Button("Clear map") { lidar.clearMap() }.font(.caption)
                }
                Picker("Map width", selection: $span) {
                    Text("4 m").tag(Float(4)); Text("8 m").tag(Float(8)); Text("12 m").tag(Float(12))
                }.pickerStyle(.segmented)
                Canvas { context, size in
                    let scale = min(size.width,size.height)/CGFloat(span)
                    let center = CGPoint(x: size.width/2,y: size.height/2)
                    let robot = s.robotPosition ?? .zero
                    func project(_ p: SIMD2<Float>) -> CGPoint {
                        CGPoint(x: center.x+CGFloat(p.x-robot.x)*scale, y: center.y+CGFloat(p.y-robot.y)*scale)
                    }
                    // AR-world axes stay fixed. The map pans with the robot, but never rotates with it.
                    for offset in -Int(span)...Int(span) {
                        let x = CGFloat(offset)-CGFloat(robot.x.truncatingRemainder(dividingBy: 1))
                        let z = CGFloat(offset)-CGFloat(robot.y.truncatingRemainder(dividingBy: 1))
                        var grid = Path()
                        grid.move(to: CGPoint(x:center.x+x*scale,y:0)); grid.addLine(to: CGPoint(x:center.x+x*scale,y:size.height))
                        grid.move(to: CGPoint(x:0,y:center.y+z*scale)); grid.addLine(to: CGPoint(x:size.width,y:center.y+z*scale))
                        context.stroke(grid,with:.color(.white.opacity(0.08)),lineWidth:1)
                    }
                    guard live, s.robotPosition != nil else { return }
                    for cell in s.mapCells {
                        let age = tick.date.timeIntervalSince1970-cell.timestamp
                        guard age >= 0, age <= LocalDepthMap.lifetime else { continue }
                        let p = project(cell.center), width = CGFloat(LocalDepthMap.cellSize)*scale
                        let opacity = max(0.2,1-age/LocalDepthMap.lifetime)
                        let rect = CGRect(x:p.x-width/2,y:p.y-width/2,width:width,height:width)
                        context.fill(Path(rect),with:.color((cell.obstacle ? Color.orange : Color.green.opacity(0.45)).opacity(opacity)))
                    }
                    if let heading = s.robotForward {
                        let right = SIMD2(-heading.y,heading.x)
                        var lane = Path()
                        lane.addLines([robot+heading*0.15-right*0.23,robot+heading*3-right*0.23,
                                       robot+heading*3+right*0.23,robot+heading*0.15+right*0.23].map(project))
                        lane.closeSubpath()
                        context.stroke(lane,with:.color(.yellow.opacity(0.8)),lineWidth:1.5)
                        var arrow = Path()
                        arrow.move(to:project(robot+heading*0.45))
                        arrow.addLine(to:project(robot-heading*0.15+right*0.15))
                        arrow.addLine(to:project(robot-heading*0.15-right*0.15)); arrow.closeSubpath()
                        context.fill(arrow,with:.color(.white))
                    }
                    let bucketWidth = CGFloat(AssumedRobotDimensions.width)*scale
                    context.stroke(Path(ellipseIn:CGRect(x:center.x-bucketWidth/2,y:center.y-bucketWidth/2,width:bucketWidth,height:bucketWidth)),with:.color(.white),lineWidth:2)
                    if let target {
                        let p = project(target.position)
                        var line = Path(); line.move(to:center); line.addLine(to:p)
                        context.stroke(line,with:.color(.cyan.opacity(0.55)),style:StrokeStyle(lineWidth:1,dash:[4,4]))
                        let ring = CGRect(x:p.x-scale,y:p.y-scale,width:2*scale,height:2*scale)
                        context.stroke(Path(ellipseIn:ring),with:.color(.cyan.opacity(0.5)),style:StrokeStyle(lineWidth:1,dash:[5,4]))
                        context.fill(Path(ellipseIn:CGRect(x:p.x-6,y:p.y-6,width:12,height:12)),with:.color(.cyan))
                    }
                    context.draw(Text("1 m grid").font(.caption2).foregroundColor(.gray),at:CGPoint(x:40,y:size.height-12))
                }
                .frame(height: 300).clipped()
                .background(Color.black.opacity(0.6),in:RoundedRectangle(cornerRadius:12))
                .accessibilityLabel("Top-down player and obstacle map")
                Text(status(live: live, target: target, snapshot: s)).font(.subheadline.bold()).foregroundStyle(target == nil ? .orange : .cyan)
                Text("White: can + heading · orange: obstacles · green: observed floor · dark: unknown. Cyan: player; dashed ring: proposed 1 m stopping distance. Dashed line is a bearing, not a planned route.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Map stays aligned to this AR session, not north. Observations fade after 4 s. Keep the player still for the first test; carry the can phone to check alignment.")
                    .font(.caption).foregroundStyle(.secondary)
                if let target, target.approximate {
                    Text("Approximate target: using UWB slant distance as ground distance. Different phone heights can shift the marker.").font(.caption).foregroundStyle(.orange)
                }
            }.labCard()
        }
    }
    private func status(live: Bool, target: MapPlayerTarget?, snapshot: LidarSnapshot) -> String {
        guard live else { return "Map waiting for live depth and Normal tracking" }
        guard model.connected else { return "Obstacles live · connect the player phone for a target" }
        guard let target, let robot = snapshot.robotPosition else { return "Obstacles live · waiting for fresh UWB distance + direction" }
        let distance = simd_distance(target.position,robot)
        let offscreen = abs(target.position.x-robot.x)>span/2 || abs(target.position.y-robot.y)>span/2
        return String(format:"Player %@%.2f m on map%@",target.approximate ? "≈ " : "",distance,offscreen ? " · outside view; zoom out" : "")
    }
}
