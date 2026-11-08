import SwiftUI
import ARKit

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
                Text("Perception only · no trajectory or driving").foregroundStyle(.orange).font(.subheadline.bold())
                VStack(alignment: .leading, spacing: 10) {
                    Label(model.inspectionMessage, systemImage: model.inspectionConfirmed ? "lock.shield.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(model.inspectionConfirmed ? .green : .orange)
                    if !model.inspectionConfirmed {
                        Toggle("Motor power is physically disconnected", isOn: $motorPowerDisconnected)
                        Text("Without a Pi-confirmed hold, disconnect the motor battery before starting this test.").font(.caption).foregroundStyle(.secondary)
                    }
                }.labCard()
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
