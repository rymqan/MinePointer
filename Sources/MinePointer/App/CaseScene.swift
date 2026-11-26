import AppKit
import ImageIO
import SceneKit
import UniformTypeIdentifiers

// Draws the case motions of CaseMotion.swift: a SceneKit model of the closed case, seen over the player's left shoulder (the front of the case shows) with the
// screen ahead. The app plays the clips live in CaseDemoView; `--render-gestures <folder>` renders the same scene to the README GIFs.

/// The scene: the case, a faint copy of it at rest (shown while the case is away from it), the clip's cue, the screen ahead with
/// the crosshair, a table for the pause, lights and a camera.
final class CaseStage {
    let scene = SCNScene()
    let camera = SCNNode()
    private let model: SCNNode, hinge: SCNNode
    private let ghost: SCNNode = {          // the rest pose: one rounded block, so nothing inside shows through
        let box = SCNBox(width: 0.021, height: 0.046, length: 0.050, chamferRadius: 0.0095)
        box.chamferSegmentCount = 10
        box.firstMaterial?.diffuse.contents = NSColor(white: 0.97, alpha: 1)
        let node = SCNNode(geometry: box)
        node.opacity = 0.22
        return node
    }()
    private let cue = SCNNode()
    private let crosshair = SCNNode()
    private let table = SCNNode(geometry: SCNBox(width: 0.3, height: 0.008, length: 0.3, chamferRadius: 0.002))
    private var aims = false
    private let aimRest = SCNVector3(-0.1, 0.03, 0.0045)      // on the part of the screen the case does not hide

    init() {
        (model, hinge) = Self.caseNode()
        ghost.isHidden = true
        let screen = SCNNode(geometry: SCNBox(width: 0.34, height: 0.19, length: 0.008, chamferRadius: 0.008))
        screen.geometry?.firstMaterial?.diffuse.contents = HomePalette.screen
        screen.position = SCNVector3(0.2, -0.1, -0.6)
        for (w, h) in [(0.016, 0.0024), (0.0024, 0.016)] {
            let bar = SCNNode(geometry: SCNPlane(width: w, height: h))
            bar.geometry?.firstMaterial = Self.paint
            crosshair.addChildNode(bar)
        }
        screen.addChildNode(crosshair)
        crosshair.position = aimRest
        table.geometry?.firstMaterial?.diffuse.contents = NSColor(white: 0.36, alpha: 1)
        let key = SCNNode(), fill = SCNNode()
        key.light = SCNLight(); key.light?.type = .directional; key.light?.intensity = 900
        key.eulerAngles = SCNVector3(-0.9, -0.5, 0)
        fill.light = SCNLight(); fill.light?.type = .ambient; fill.light?.intensity = 450
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 27
        camera.camera?.zNear = 0.01
        camera.position = SCNVector3(-0.15, 0.06, 0.24)
        camera.look(at: SCNVector3(-0.006, -0.002, -0.02))
        for node in [model, ghost, cue, table, screen, key, fill, camera] { scene.rootNode.addChildNode(node) }
        load(nil)
    }

    /// Sets up the clip's cue, crosshair and table; nil shows the case alone.
    func load(_ clip: CaseClip?) {
        cue.childNodes.forEach { $0.removeFromParentNode() }
        switch clip?.cue {
        case .move(let d, let both)?:       // beside the case, on the side toward the camera
            let d = normalize(d), at = SIMD3<Double>(-0.03, 0, 0)
            cue.addChildNode(Self.arrow([at - d * 0.017, at + d * 0.017], both: both))
        case .turn(let axis, let both)?:    // an arc around the case, over the top (left of it for a vertical axis)
            let a = normalize(axis)
            let mid: SIMD3<Double> = abs(a.y) > 0.9 ? [-1, 0, 0] : [0, 1, 0]
            let points = stride(from: -50.0, through: 50, by: 5).map { simd_quatd(angle: $0 * .pi / 180, axis: a).act(mid) * 0.042 }
            cue.addChildNode(Self.arrow(points, both: both))
        case nil: break
        }
        aims = clip?.aims ?? false
        crosshair.position = aimRest
        table.isHidden = clip?.table == nil
        if let top = clip?.table { table.position = SCNVector3(0, top - 0.004, 0) }
        show(CasePose())
    }

    func show(_ pose: CasePose) {
        place(pose.position, pose.rotation)
        hinge.eulerAngles.z = CGFloat(-pose.lid * 105 * .pi / 180)        // the lid swings up and over toward the palm
        if aims { crosshair.position = SCNVector3(aimRest.x + pose.yaw * 0.0025, aimRest.y + pose.pitch * 0.0025, aimRest.z) }
    }

    /// The case at a position (m) and rotation (case → world); the ghost shows once it is away from rest.
    func place(_ position: SIMD3<Double>, _ q: simd_quatd) {
        model.simdPosition = SIMD3<Float>(position)
        model.simdOrientation = simd_quatf(ix: Float(q.imag.x), iy: Float(q.imag.y), iz: Float(q.imag.z), r: Float(q.real))
        ghost.isHidden = length(position) < 0.004 && q.angle * 180 / .pi < 4
    }

    private static let paint: SCNMaterial = {
        let m = SCNMaterial()
        m.diffuse.contents = NSColor(white: 0.78, alpha: 1)
        m.lightingModel = .constant
        m.isDoubleSided = true
        return m
    }()

    /// A light arrow along `points`: a tube with a head at the end (and at the start with `both`).
    private static func arrow(_ points: [SIMD3<Double>], both: Bool) -> SCNNode {
        let node = SCNNode()
        func segment(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ geometry: SCNGeometry) {
            let part = SCNNode(geometry: geometry)
            part.geometry?.firstMaterial = paint
            part.simdPosition = SIMD3<Float>((a + b) / 2)
            part.simdOrientation = simd_quatf(from: [0, 1, 0], to: SIMD3<Float>(normalize(b - a)))
            node.addChildNode(part)
        }
        func head(_ tip: SIMD3<Double>, from: SIMD3<Double>) {
            segment(tip - normalize(tip - from) * 0.011, tip, SCNCone(topRadius: 0, bottomRadius: 0.0045, height: 0.011))
        }
        var path = points
        let n = path.count
        path[n - 1] -= normalize(path[n - 1] - path[n - 2]) * 0.009                      // the shaft stops inside the head
        if both { path[0] -= normalize(path[0] - path[1]) * 0.009 }
        for i in 1..<n { segment(path[i - 1], path[i], SCNCylinder(radius: 0.0016, height: length(path[i] - path[i - 1]))) }
        head(points[n - 1], from: points[n - 2])
        if both { head(points[0], from: points[1]) }
        return node
    }

    /// AirPods 4 case, 50 × 46 × 21 mm, as held in the right hand: lid on top, the back in the palm (right), the front with the
    /// status light to the left, a narrow side toward the screen. The lid (the returned hinge, turned by `CasePose.lid`) opens on
    /// a hinge along the back over the two earbuds.
    /// A quarter circle: SCNShape's chamfer as a round edge instead of a bevel.
    private static let roundProfile: NSBezierPath = {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: 0, y: 1))
        p.appendArc(withCenter: NSPoint(x: 0, y: 0), radius: 1, startAngle: 90, endAngle: 0, clockwise: true)
        return p
    }()

    private static func caseNode() -> (SCNNode, hinge: SCNNode) {
        let shell = SCNMaterial()
        shell.diffuse.contents = NSColor(white: 0.97, alpha: 1)
        shell.specular.contents = NSColor(white: 0.55, alpha: 1)
        shell.shininess = 0.35
        // The outline seen from above (21 × 50 mm, corners rounded 9.5 mm), drawn in millimetres and extruded upward; only the
        // outer end is rounded, so body and lid meet flush at the seam.
        func part(height: CGFloat, roundTop: Bool) -> SCNNode {
            let path = NSBezierPath(roundedRect: NSRect(x: -10.5, y: -25, width: 21, height: 50), xRadius: 9.5, yRadius: 9.5)
            path.flatness = 0.05
            let shape = SCNShape(path: path, extrusionDepth: height)
            shape.chamferRadius = 8
            shape.chamferMode = roundTop ? .front : .back
            shape.chamferProfile = Self.roundProfile
            shape.materials = [shell]
            let solid = SCNNode(geometry: shape)
            solid.eulerAngles.x = -.pi / 2          // the extrusion (z) points up
            let node = SCNNode()
            node.scale = SCNVector3(0.001, 0.001, 0.001)
            node.addChildNode(solid)
            return node
        }
        let node = SCNNode()
        let body = part(height: 30.5, roundTop: false)  // from the bottom (-23 mm) to the seam (+7.5 mm)
        body.position.y = -0.00775
        let hinge = SCNNode()                           // at the top of the back side
        hinge.position = SCNVector3(0.0105, 0.0075, 0)
        let lid = part(height: 15.4, roundTop: true)
        lid.position = SCNVector3(-0.0105, 0.0078, 0)
        hinge.addChildNode(lid)
        for z in [-0.012, 0.012] {                      // the earbuds' stems stand a little above the seam
            let bud = SCNNode(geometry: SCNCapsule(capRadius: 0.0045, height: 0.018))
            bud.geometry?.firstMaterial?.diffuse.contents = NSColor(white: 0.9, alpha: 1)
            bud.position = SCNVector3(0, 0.003, z)
            node.addChildNode(bud)
        }
        let light = SCNNode(geometry: SCNCylinder(radius: 0.0011, height: 0.0004))
        light.geometry?.firstMaterial?.diffuse.contents = NSColor(white: 0.25, alpha: 1)
        light.eulerAngles.z = .pi / 2
        light.position = SCNVector3(-0.0106, -0.004, 0)
        for child in [body, hinge, light] { node.addChildNode(child) }
        return (node, hinge)
    }
}

/// A clip playing in a loop; with `clip = nil` the case stays where `follow` put it last (the sandbox), at rest at first.
final class CaseDemoView: SCNView, SCNSceneRendererDelegate {
    // The stage changes only on SceneKit's render thread (renderer(_:updateAtTime:)); the main thread hands over what to show
    // through `next`, under the lock.
    private let stage = CaseStage()
    private let lock = NSLock()
    private var next: (clip: CaseClip?, started: Double, live: [Double]?) = (nil, 0, nil)
    private var loaded: String?                 // render thread: the id of the clip the stage is set up for
    private let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    /// A ring around the case filling with the calibration step's progress (0-1), like AirPointer's hold ring; nil hides it.
    var ring: Double? { didSet { if ring != oldValue { ringView.needsDisplay = true } } }
    private lazy var ringView = RingView(owner: self)

    var clip: CaseClip? {
        get { lock.withLock { next.clip } }
        set { lock.withLock { if newValue?.id != next.clip?.id { next = (newValue, 0, nil) } } }
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 200), options: nil)
        scene = stage.scene
        pointOfView = stage.camera
        backgroundColor = HomePalette.stage
        wantsLayer = true
        layer?.cornerRadius = 12
        antialiasingMode = .multisampling4X
        delegate = self
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        rkPin(ringView, in: self)
    }

    private final class RingView: NSView {
        unowned let owner: CaseDemoView
        init(owner: CaseDemoView) { self.owner = owner; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }      // clicks go to the demo (replay)
        override func draw(_ dirtyRect: NSRect) {
            guard let progress = owner.ring else { return }
            let c = owner.projectPoint(SCNVector3(0, 0, 0))                // the case's rest position on screen
            rkDrawRing(center: NSPoint(x: c.x, y: c.y), radius: bounds.height * 0.36, progress: CGFloat(progress),
                       track: NSColor.white.withAlphaComponent(0.18), arc: .systemGreen)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        rendersContinuously = window != nil     // no render loop for a page that is not on screen
    }

    /// The live case pose of an `@pose` line.
    func follow(_ values: [Double]) {
        guard values.count == 7 else { return }
        lock.withLock { if next.clip == nil { next.live = values } }
    }

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        let now = lock.withLock {
            if next.clip != nil, next.started == 0 { next.started = time }
            return next
        }
        if now.clip?.id != loaded { stage.load(now.clip); loaded = now.clip?.id }
        guard let clip = now.clip else {
            if let v = now.live { stage.place(SIMD3(v[0], v[1], v[2]), simd_quatd(ix: v[3], iy: v[4], iz: v[5], r: v[6])) }
            return
        }
        let elapsed = time - now.started
        // With Reduce Motion the clip plays once and rests; a click plays it again.
        if reduceMotion, elapsed > clip.duration { stage.show(clip.pose(at: clip.duration)); return }
        stage.show(clip.pose(at: elapsed.truncatingRemainder(dividingBy: clip.duration)))
    }

    override func mouseDown(with event: NSEvent) { lock.withLock { next.started = 0 } }
}

/// `--render-gestures <folder>`: every gesture clip and the connection as `<id>.gif`, 30 frames a second at real speed, looping.
func renderGestureGIFs(to folder: URL) {
    let stage = CaseStage()
    let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
    renderer.scene = stage.scene
    renderer.pointOfView = stage.camera
    stage.scene.background.contents = HomePalette.stage       // the app's stage colour, dark: it reads on GitHub's light and dark pages
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let fps = 30.0, size = CGSize(width: 400, height: 300)
    for clip in CaseClip.all + [.connect] {
        let url = folder.appendingPathComponent(clip.id + ".gif")
        let count = Int((clip.duration * fps).rounded())
        guard let gif = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, count, nil) else { fatalError("cannot write \(url.path)") }
        CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frame = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary
        stage.load(clip)
        for i in 0..<count {
            stage.show(clip.pose(at: Double(i) / fps))
            let image = renderer.snapshot(atTime: Double(i) / fps, with: size, antialiasingMode: .multisampling4X)
            guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { fatalError("no frame") }
            CGImageDestinationAddImage(gif, cg, frame)
        }
        guard CGImageDestinationFinalize(gif) else { fatalError("cannot write \(url.path)") }
        print("\(url.path): \(count) frames")
    }
}
