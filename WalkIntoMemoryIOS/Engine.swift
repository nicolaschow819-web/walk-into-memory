import Foundation
import SwiftUI
import ARKit
import MetalKit
import MetalSplatter
import SplatIO
import simd

/// Owns the AR session, the splat renderer and all per-frame math.
/// Placement / reveal / dissolve mirror the visionOS original (ArtworkRenderer)
/// with the head pose replaced by the iPhone's ARKit camera and the hand-driven
/// dissolve sphere replaced by the camera position.
final class AppEngine: NSObject, ObservableObject, MTKViewDelegate {
    @Published var status: String = "先导入一个 .spz 场景（可带同名 .json）"
    @Published var hasScene = false

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let session = ARSession()
    private let renderer: SplatRenderer
    private var textureCache: CVMetalTextureCache?
    private var cameraPipeline: MTLRenderPipelineState?
    private var compositePipeline: MTLRenderPipelineState?
    private var offColor: MTLTexture?
    private var offDepth: MTLTexture?

    private let startTime = CACurrentMediaTime()
    private var sidecar: SceneSidecar?
    private var placement: ScenePlacement?
    private var placedAt: CFTimeInterval = 0
    private var needsReplace = false
    /// Thread-safe "first sort finished" flag. SplatRenderer.onSortComplete is
    /// a @Sendable closure fired off the main thread, so it must not capture
    /// the non-Sendable engine itself.
    private final class SortGate: @unchecked Sendable {
        private let lock = NSLock()
        private var sorted = false
        var isSorted: Bool { lock.lock(); defer { lock.unlock() }; return sorted }
        func markSorted() { lock.lock(); sorted = true; lock.unlock() }
        func reset() { lock.lock(); sorted = false; lock.unlock() }
    }
    private let sortGate = SortGate()
    private var stats: (near: Float, far: Float, quantiles: [Float], low: Float, high: Float)?

    override init() {
        device = MTLCreateSystemDefaultDevice()!
        queue = device.makeCommandQueue()!
        renderer = try! SplatRenderer(device: device,
                                      colorFormat: .bgra8Unorm,
                                      depthFormat: .depth32Float,
                                      sampleCount: 1,
                                      maxViewCount: 1,
                                      maxSimultaneousRenders: 3,
                                      highQualityDepth: false,
                                      clearColor: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0))
        super.init()
        let gate = sortGate
        renderer.onSortComplete = { _ in gate.markSorted() }
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
        buildPipelines()
    }

    private func buildPipelines() {
        guard let library = device.makeDefaultLibrary() else { return }
        let camDesc = MTLRenderPipelineDescriptor()
        camDesc.vertexFunction = library.makeFunction(name: "cameraVertex")
        camDesc.fragmentFunction = library.makeFunction(name: "cameraFragment")
        camDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        cameraPipeline = try? device.makeRenderPipelineState(descriptor: camDesc)

        let compDesc = MTLRenderPipelineDescriptor()
        compDesc.vertexFunction = library.makeFunction(name: "compositeVertex")
        compDesc.fragmentFunction = library.makeFunction(name: "compositeFragment")
        compDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        compDesc.colorAttachments[0].isBlendingEnabled = true
        compDesc.colorAttachments[0].rgbBlendOperation = .add
        compDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        compDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        compDesc.colorAttachments[0].alphaBlendOperation = .add
        compDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
        compDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        compositePipeline = try? device.makeRenderPipelineState(descriptor: compDesc)
    }

    @MainActor func attach(_ view: MTKView) {
        view.device = device
        view.delegate = self
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .invalid
        view.framebufferOnly = false
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.preferredFramesPerSecond = 60
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal]
        config.worldAlignment = .gravity
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    func requestReplace() { needsReplace = true }

    // MARK: - Scene loading

    func loadScene(spzURL: URL, jsonURL: URL?) {
        DispatchQueue.main.async { self.status = "正在加载场景…" }
        sidecar = jsonURL.flatMap { SceneSidecar.load($0) }
        placement = nil
        sortGate.reset()
        Task.detached { [weak self] in
            guard let self else { return }
            do {
                let reader = try AutodetectSceneReader(spzURL)
                var points: [SplatPoint] = []
                for try await batch in try await reader.read() {
                    points.append(contentsOf: batch)
                }
                guard !points.isEmpty else {
                    await MainActor.run { self.status = "场景是空的，换个文件试试" }
                    return
                }
                self.stats = Self.computeStats(points)
                let chunk = try SplatChunk(device: self.device, from: points)
                await self.renderer.addChunk(chunk)
                await MainActor.run {
                    self.hasScene = true
                    self.status = "场景已加载，把手机对准前方，正在放置…"
                }
            } catch {
                await MainActor.run { self.status = "加载失败：\(error.localizedDescription)" }
            }
        }
    }

    /// Called from the app's onAppear: reloads a bundled default.spz when one
    /// is packaged, otherwise the most recently imported scene still staged in
    /// Documents/Scenes. No-op on first launch, when nothing exists yet.
    func loadDefaultSceneIfAvailable() {
        if let bundled = Bundle.main.url(forResource: "default", withExtension: "spz") {
            loadScene(spzURL: bundled,
                      jsonURL: Bundle.main.url(forResource: "default", withExtension: "json"))
            return
        }
        let fm = FileManager.default
        let root = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Scenes", isDirectory: true)
        guard let dirs = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let scenes: [(spz: URL, json: URL?, date: Date)] = dirs.compactMap { dir in
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil),
                  let spz = files.first(where: { $0.pathExtension.lowercased() == "spz" })
            else { return nil }
            let json = files.first { $0.pathExtension.lowercased() == "json" }
            let date = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return (spz, json, date)
        }
        guard let latest = scenes.max(by: { $0.date < $1.date }) else { return }
        loadScene(spzURL: latest.spz, jsonURL: latest.json)
    }

    private static func computeStats(_ points: [SplatPoint])
        -> (near: Float, far: Float, quantiles: [Float], low: Float, high: Float) {
        let step = max(1, points.count / 4096)
        var depths: [Float] = []
        var low = Float.greatestFiniteMagnitude
        var high = -Float.greatestFiniteMagnitude
        for i in stride(from: 0, to: points.count, by: step) {
            let p = points[i].position
            depths.append(p.z)
            low = min(low, p.y)
            high = max(high, p.y)
        }
        depths.sort()
        guard !depths.isEmpty else { return (0.1, 10, [], -1, 1) }
        func q(_ f: Float) -> Float { depths[min(depths.count - 1, max(0, Int(f * Float(depths.count - 1))))] }
        let quantiles = (0...16).map { q(Float($0) / 16) }
        return (q(0.05), q(0.95), quantiles, low, high)
    }

    // MARK: - Placement (mirrors the original's place-at-head-pose)

    private func placeIfNeeded(frame: ARFrame) {
        guard hasScene, placement == nil || needsReplace else { return }
        guard case .normal = frame.camera.trackingState else { return }
        let camT = frame.camera.transform
        let head = SIMD3<Float>(camT.columns.3.x, camT.columns.3.y, camT.columns.3.z)
        var forward = SIMD3<Float>(-camT.columns.2.x, 0, -camT.columns.2.z)
        guard simd_length_squared(forward) > 0.0001 else { return }
        forward = simd_normalize(forward)

        // Floor: lowest horizontal plane ARKit has found; else assume the phone
        // is held ~1.5 m above the floor.
        var lowestPlane: Float? = nil
        for anchor in frame.anchors {
            if let plane = anchor as? ARPlaneAnchor, plane.alignment == .horizontal {
                let y = plane.transform.columns.3.y
                lowestPlane = lowestPlane.map { min($0, y) } ?? y
            }
        }
        let floorY = lowestPlane ?? (head.y - 1.5)
        let cameraHeight = sidecar?.cameraHeight
        let entry: Float = cameraHeight != nil ? 0 : 0.65
        let originY = cameraHeight != nil ? floorY + cameraHeight! : head.y
        var p = ScenePlacement()
        p.position = SIMD3<Float>(head.x, originY, head.z) + forward * entry
        p.orientation = simd_quatf(angle: atan2(-forward.x, -forward.z), axis: SIMD3<Float>(0, 1, 0))
        p.flipVertical = sidecar != nil
        p.scale = 1
        placement = p
        placedAt = CACurrentMediaTime()
        needsReplace = false
        DispatchQueue.main.async { self.status = "已放置：往前走，走近它，它会散开" }
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let frame = session.currentFrame,
              let drawable = view.currentDrawable,
              let cameraPipeline, let compositePipeline else { return }
        let size = view.drawableSize
        guard size.width > 0, size.height > 0 else { return }
        ensureOffscreen(size: size)
        guard let offColor, let offDepth else { return }

        placeIfNeeded(frame: frame)
        let now = CACurrentMediaTime()
        let elapsed = Float(now - startTime)

        // Pass 1: splats into the offscreen target (only once placed + sorted).
        if let placement, sortGate.isSorted {
            let progress = Float(min(1, max(0, (now - placedAt) / 2.5)))
            var reveal = SplatRenderer.RevealEffect(
                progress: progress,
                noiseFrequency: 1.3, frontWidth: 0.24, seedRadius: 0.003, particleTravel: 0.045,
                origin: .zero, direction: SIMD3<Float>(0, 0, 1),
                nearDepth: stats?.near ?? 0.1, farDepth: stats?.far ?? 10,
                style: 1, up: SIMD3<Float>(0, -1, 0),
                low: stats?.low ?? -1, high: stats?.high ?? 1, radius: 5)
            reveal.depthQuantiles = stats?.quantiles ?? []

            if let frame24 = sidecar?.validEdgeFrame {
                renderer.edgeBreath = SplatRenderer.EdgeBreath(
                    frame: frame24, time: elapsed, mix: 0.85 * progress)
            } else {
                renderer.edgeBreath = nil
            }

            // Walk-in dissolve: camera position in model space drives sphere A.
            if progress >= 1 {
                let camWorld = SIMD3<Float>(frame.camera.transform.columns.3.x,
                                            frame.camera.transform.columns.3.y,
                                            frame.camera.transform.columns.3.z)
                let inv = placement.matrix.inverse
                let mp = inv * SIMD4<Float>(camWorld, 1)
                let p = SIMD3<Float>(mp.x, mp.y, mp.z)
                let stillDepth = sidecar?.wind?.stillDepth ?? 1.6
                let t = (p.z - 0.45 * stillDepth) / (0.5 * stillDepth)
                let amount = min(1, max(0, t))
                if amount > 0.001 {
                    renderer.touchDissolve = SplatRenderer.TouchDissolve(
                        a: SIMD4<Float>(p, 0.55), b: .zero,
                        amount: SIMD2<Float>(amount, 0),
                        feather: 0.45, time: elapsed,
                        up: SIMD3<Float>(0, -1, 0), drift: 0.05)
                } else {
                    renderer.touchDissolve = nil
                }
            } else {
                renderer.touchDissolve = nil
            }

            let viewport = SplatRenderer.ViewportDescriptor(
                viewport: MTLViewport(originX: 0, originY: 0,
                                      width: Double(size.width), height: Double(size.height),
                                      znear: 0, zfar: 1),
                projectionMatrix: frame.camera.projectionMatrix(
                    for: .portrait, viewportSize: size, zNear: 0.05, zFar: 80),
                viewMatrix: frame.camera.viewMatrix(for: .portrait) * placement.matrix,
                screenSize: SIMD2<Int>(Int(size.width), Int(size.height)))
            if let buffer = queue.makeCommandBuffer() {
                _ = try? renderer.render(viewports: [viewport],
                                         colorTexture: offColor, colorStoreAction: .store,
                                         depthTexture: offDepth, rasterizationRateMap: nil,
                                         renderTargetArrayLength: 1, revealEffect: reveal,
                                         to: buffer)
                buffer.commit()
            }
        }

        // Pass 2: camera image, then splats composited over it.
        guard let buffer = queue.makeCommandBuffer(),
              let pass = view.currentRenderPassDescriptor else { return }
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].loadAction = .clear
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }

        if let (texY, texCbCr) = cameraTextures(frame: frame, viewportSize: size) {
            // Fullscreen quad (triangle strip), UVs mapped through displayTransform.
            let positions: [SIMD2<Float>] = [SIMD2(-1, -1), SIMD2(1, -1), SIMD2(-1, 1), SIMD2(1, 1)]
            let baseUV: [SIMD2<Float>] = [SIMD2(0, 1), SIMD2(1, 1), SIMD2(0, 0), SIMD2(1, 0)]
            let dt = frame.displayTransform(for: .portrait, viewportSize: size)
            let uvs: [SIMD2<Float>] = baseUV.map { uv in
                let p = CGPoint(x: CGFloat(uv.x), y: CGFloat(uv.y)).applying(dt)
                return SIMD2<Float>(Float(p.x), Float(p.y))
            }
            encoder.setRenderPipelineState(cameraPipeline)
            positions.withUnsafeBytes { encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
            uvs.withUnsafeBytes { encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 1) }
            encoder.setFragmentTexture(texY, index: 0)
            encoder.setFragmentTexture(texCbCr, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        if placement != nil {
            encoder.setRenderPipelineState(compositePipeline)
            encoder.setFragmentTexture(offColor, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    private func ensureOffscreen(size: CGSize) {
        let w = Int(size.width), h = Int(size.height)
        if let offColor, offColor.width == w, offColor.height == h { return }
        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        colorDesc.usage = [.renderTarget, .shaderRead]
        colorDesc.storageMode = .private
        offColor = device.makeTexture(descriptor: colorDesc)
        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: w, height: h, mipmapped: false)
        depthDesc.usage = [.renderTarget]
        depthDesc.storageMode = .private
        offDepth = device.makeTexture(descriptor: depthDesc)
    }

    private func cameraTextures(frame: ARFrame, viewportSize: CGSize) -> (MTLTexture, MTLTexture)? {
        guard let cache = textureCache else { return nil }
        let buffer = frame.capturedImage
        func makeTexture(_ plane: Int, _ format: MTLPixelFormat) -> MTLTexture? {
            var cvTexture: CVMetalTexture?
            let width = CVPixelBufferGetWidthOfPlane(buffer, plane)
            let height = CVPixelBufferGetHeightOfPlane(buffer, plane)
            guard CVMetalTextureCacheCreateTextureFromImage(
                nil, cache, buffer, nil, format, width, height, plane, &cvTexture) == kCVReturnSuccess,
                let cvTexture else { return nil }
            return CVMetalTextureGetTexture(cvTexture)
        }
        guard let y = makeTexture(0, .r8Unorm), let cbcr = makeTexture(1, .rg8Unorm) else { return nil }
        return (y, cbcr)
    }
}

struct ARMetalView: UIViewRepresentable {
    @ObservedObject var engine: AppEngine

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        engine.attach(view)
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}
}
