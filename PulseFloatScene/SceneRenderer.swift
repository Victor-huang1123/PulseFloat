import Metal
import PulseFloatCore
import QuartzCore
import SceneKit
import Synchronization

/// 每幀耗時（毫秒）。CPU 與 GPU 分開量：CPU 是主執行緒上的 update + SceneKit encode，
/// GPU 是 command buffer 的 gpuEndTime − gpuStartTime（即時畫面會落後 1–2 幀回報）。
public struct SceneTiming: Sendable, Equatable {
    public var cpuUpdateMs: Double = 0
    public var cpuEncodeMs: Double = 0
    public var gpuMs: Double = 0
    public var renderedFrames = 0
    public var skippedFrames = 0
    public var cpuMs: Double { cpuUpdateMs + cpuEncodeMs }
}

/// 離屏渲染的結果：BGRA8、premultiplied alpha（光暈可能是 alpha 0 的加法光）。
public struct SceneImage: Sendable {
    public let width: Int
    public let height: Int
    /// 每列 width × 4 bytes，B G R A。
    public let pixels: [UInt8]
    public let timing: SceneTiming

    /// 疊在純色或上下漸層背景上（premultiplied over：out = src + bg × (1 − α)），回傳不透明的 CGImage。
    public func composited(top: RGB, bottom: RGB) -> CGImage? {
        var out = [UInt8](repeating: 255, count: width * height * 4)
        var y = 0
        while y < height {
            let t = height > 1 ? Double(y) / Double(height - 1) : 0
            let bg = SculptureStyleColors.mix(top, bottom, t)
            var x = 0
            while x < width {
                let i = (y * width + x) * 4
                let a = Double(pixels[i + 3]) / 255
                out[i] = UInt8(min(255, Double(pixels[i]) + Double(bg.blue) * (1 - a)))
                out[i + 1] = UInt8(min(255, Double(pixels[i + 1]) + Double(bg.green) * (1 - a)))
                out[i + 2] = UInt8(min(255, Double(pixels[i + 2]) + Double(bg.red) * (1 - a)))
                out[i + 3] = 255
                x += 1
            }
            y += 1
        }
        let info = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let provider = CGDataProvider(data: Data(out) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: SceneMaterials.sRGB, bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// 不透明（alpha > 0）或發光（RGB > 0）像素的比例。
    public var visibleRatio: Double {
        var count = 0
        var i = 0
        while i < pixels.count {
            if pixels[i + 3] > 0 || pixels[i] > 4 || pixels[i + 1] > 4 || pixels[i + 2] > 4 { count += 1 }
            i += 4
        }
        return pixels.isEmpty ? 0 : Double(count) / Double(pixels.count / 4)
    }
}

/// 用 `SCNRenderer` 把 SceneKit 主題畫進 CAMetalLayer（即時）或離屏貼圖（測試、截圖、預覽）。
/// 由 App 唯一的畫面時鐘在主執行緒驅動；主題回報靜止且沒有任何改變時不重繪（GPU 也不工作）。
@MainActor
public final class SceneRenderer {
    public let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let renderer: SCNRenderer
    public private(set) var themeID: ThemeID?
    public private(set) var theme: (any SceneTheme)?
    public private(set) var settings = SceneSettings()
    public private(set) var timing = SceneTiming()
    private var needsRender = true
    /// 最後一次真正畫出來的畫面是否已經是靜止狀態；否則即使主題已靜止也要再畫一次最終的靜止畫面。
    private var renderedAtRest = false
    private var colorTexture: (any MTLTexture)?
    private var depthTexture: (any MTLTexture)?
    private var targetKey = ""
    private var offscreenTarget: (any MTLTexture)?
    private let gpuClock = GPUClock()

    /// 沒有 Metal 裝置時回傳 nil（呼叫端改用 Core Graphics 備援）。
    public init?(device: (any MTLDevice)? = MTLCreateSystemDefaultDevice()) {
        guard let device, let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        renderer = SCNRenderer(device: device, options: nil)
        renderer.autoenablesDefaultLighting = false
        renderer.isJitteringEnabled = false
        renderer.isTemporalAntialiasingEnabled = false
        renderer.isPlaying = false
    }

    /// MSAA 取樣數：LOW 1、MEDIUM/HIGH 4。
    public static func sampleCount(_ quality: RenderQuality) -> Int { quality == .low ? 1 : 4 }

    /// 切換主題（不是 SceneKit 主題時清空）並套用設定。
    public func setTheme(_ id: ThemeID, settings: SceneSettings) {
        if themeID != id {
            themeID = id
            let previous = theme?.stage
            theme = SceneThemeFactory.make(id)
            if let previous { theme?.stage.setUserCamera(yaw: previous.userYaw, pitch: previous.userPitch, zoom: previous.userZoom) }
            self.settings = settings
            theme?.apply(settings)
            renderer.scene = theme?.scene
            renderer.pointOfView = theme?.pointOfView
            timing = SceneTiming()
            needsRender = true
        } else {
            apply(settings)
        }
    }

    /// 設定有變才重新套用。
    public func apply(_ settings: SceneSettings) {
        guard settings != self.settings else { return }
        self.settings = settings
        theme?.apply(settings)
        renderer.pointOfView = theme?.pointOfView
        needsRender = true
    }

    /// 下一幀一定重繪（例如視窗重新顯示、尺寸改變）。
    public func invalidate() { needsRender = true }

    /// 使用者在雕塑模式旋轉／縮放鏡頭（明確的操作，靜音時也會重繪一次）。
    public func setUserCamera(yaw: Float, pitch: Float, zoom: Float) {
        theme?.stage.setUserCamera(yaw: yaw, pitch: pitch, zoom: zoom)
        needsRender = true
    }

    /// 前進一幀並畫進 layer 的下一個 drawable；畫面靜止時略過並回傳 false。
    @discardableResult
    public func render(frame: SpectrumFrame, dt: Double, into layer: CAMetalLayer) -> Bool {
        guard let theme else { return false }
        let start = CACurrentMediaTime()
        let wasAtRest = theme.isAtRest
        theme.update(frame: frame, dt: Self.clampDT(dt))
        timing.cpuUpdateMs = (CACurrentMediaTime() - start) * 1000
        if !wasAtRest || !theme.isAtRest { renderedAtRest = false }
        let width = Int(layer.drawableSize.width), height = Int(layer.drawableSize.height)
        guard width > 0, height > 0 else { return false }
        if theme.isAtRest && renderedAtRest && !needsRender {
            timing.skippedFrames += 1
            timing.cpuEncodeMs = 0
            return false
        }
        guard let drawable = layer.nextDrawable(), let commandBuffer = queue.makeCommandBuffer() else { return false }
        let encodeStart = CACurrentMediaTime()
        encode(commandBuffer, target: drawable.texture, width: width, height: height)
        commandBuffer.present(drawable)
        let gpu = gpuClock
        commandBuffer.addCompletedHandler { buffer in
            let ms = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000
            if ms.isFinite, ms >= 0 { gpu.value.withLock { $0 = ms } }
        }
        commandBuffer.commit()
        timing.cpuEncodeMs = (CACurrentMediaTime() - encodeStart) * 1000
        timing.gpuMs = gpuClock.value.withLock { $0 }
        timing.renderedFrames += 1
        needsRender = false
        renderedAtRest = theme.isAtRest
        return true
    }

    /// 前進一幀並離屏繪製，等 GPU 完成後讀回像素（GPU 時間是這一幀的精確值）。測試、截圖、主題預覽用。
    public func renderOffscreen(frame: SpectrumFrame, dt: Double, width: Int, height: Int) -> SceneImage? {
        guard let theme, width > 0, height > 0 else { return nil }
        let start = CACurrentMediaTime()
        theme.update(frame: frame, dt: Self.clampDT(dt))
        timing.cpuUpdateMs = (CACurrentMediaTime() - start) * 1000
        if offscreenTarget?.width != width || offscreenTarget?.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .shared
            offscreenTarget = device.makeTexture(descriptor: descriptor)
        }
        guard let target = offscreenTarget, let commandBuffer = queue.makeCommandBuffer() else { return nil }
        let encodeStart = CACurrentMediaTime()
        encode(commandBuffer, target: target, width: width, height: height)
        timing.cpuEncodeMs = (CACurrentMediaTime() - encodeStart) * 1000
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        let ms = (commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * 1000
        timing.gpuMs = ms.isFinite ? ms : 0
        timing.renderedFrames += 1
        needsRender = false
        renderedAtRest = theme.isAtRest
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            target.getBytes(base, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return SceneImage(width: width, height: height, pixels: pixels, timing: timing)
    }

    /// 只前進主題狀態、不繪製（量 CPU update 用）。
    public func advance(frame: SpectrumFrame, dt: Double) {
        guard let theme else { return }
        let start = CACurrentMediaTime()
        let wasAtRest = theme.isAtRest
        theme.update(frame: frame, dt: Self.clampDT(dt))
        timing.cpuUpdateMs = (CACurrentMediaTime() - start) * 1000
        if !wasAtRest || !theme.isAtRest { renderedAtRest = false }
    }

    /// 主題目前是否靜止。
    public var isAtRest: Bool { theme?.isAtRest ?? true }

    private static func clampDT(_ dt: Double) -> Double { dt.isFinite ? min(0.05, max(0, dt)) : 0 }

    private func encode(_ commandBuffer: any MTLCommandBuffer, target: any MTLTexture, width: Int, height: Int) {
        let samples = Self.sampleCount(settings.quality)
        let key = "\(width)x\(height)x\(samples)"
        if key != targetKey { makeTargets(width: width, height: height, samples: samples, key: key) }
        let pass = MTLRenderPassDescriptor()
        if samples > 1, let colorTexture {
            pass.colorAttachments[0].texture = colorTexture
            pass.colorAttachments[0].resolveTexture = target
            pass.colorAttachments[0].storeAction = .multisampleResolve
        } else {
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].storeAction = .store
        }
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.depthAttachment.texture = depthTexture
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = 1
        renderer.pointOfView = theme?.pointOfView
        // 節點的修改先停在隱式交易裡，要等 run loop 結束才會進入呈現樹；我們在同一個時鐘回呼裡就要畫，所以先套用。
        SCNTransaction.flush()
        renderer.render(withViewport: CGRect(x: 0, y: 0, width: width, height: height), commandBuffer: commandBuffer, passDescriptor: pass)
    }

    private func makeTargets(width: Int, height: Int, samples: Int, key: String) {
        targetKey = key
        if samples > 1 {
            let color = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            color.textureType = .type2DMultisample
            color.sampleCount = samples
            color.usage = .renderTarget
            color.storageMode = .private
            colorTexture = device.makeTexture(descriptor: color)
        } else {
            colorTexture = nil
        }
        let depth = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
        depth.usage = .renderTarget
        depth.storageMode = .private
        if samples > 1 {
            depth.textureType = .type2DMultisample
            depth.sampleCount = samples
        }
        depthTexture = device.makeTexture(descriptor: depth)
    }
}

/// Metal 完成回呼（其他執行緒）寫入、主執行緒讀取的最近一幀 GPU 時間。
private final class GPUClock: Sendable {
    let value = Mutex<Double>(0)
}
