import Foundation
import Metal
import MetalKit
import simd

/// Uniform block shared with the Metal shaders. Field order and padding must
/// match `ShaderSource.metal` exactly.
struct BendUniforms {
    var aspect: Float = 1
    var theta: Float = 0
    var bendRadius: Float = 0.3
    var hingeV: Float = 0

    var focal: Float = 3
    var progress: Float = 0
    var blurAmount: Float = 0
    var shadeAmount: Float = 0

    var sheen: Float = 0
    var saturation: Float = 1
    var grain: Float = 0
    var time: Float = 0

    var vignette: Float = 0.7
    var feather: Float = 0.22
    var panelTop: Float = 1
    var pad1: Float = 0

    var tint: SIMD4<Float> = SIMD4(1, 1, 1, 1)
}

/// Renders one frame of the bend effect: a background wash, a three-level blur
/// pyramid of the captured desktop, then the desktop leaning away from its
/// bend line with perspective.
final class BendRenderer {

    struct Frame {
        var progress: Float          // 0 flat .. 1 fully bent
        var style: BendStyle
        var intensityDegrees: Float
        var perspective: Float       // 0..1
        var blur: Float              // 0..1
        var shadow: Float            // 0..1
        var softness: Float          // 0..1
        var hingeV: Float            // 0..1
        var time: Float
    }

    let device: MTLDevice
    let commandQueue: MTLCommandQueue

    private let bgPipeline: MTLRenderPipelineState
    private let blurPipeline: MTLRenderPipelineState
    private let bendPipeline: MTLRenderPipelineState

    private let gridBuffer: MTLBuffer
    private let indexBuffer: MTLBuffer
    private let indexCount: Int

    /// Ping-pong pair per pyramid level, each half the size of the last.
    private var blurLevels: [(a: MTLTexture, b: MTLTexture)] = []
    private var blurBase: (Int, Int) = (0, 0)

    private static let levelCount = 3
    private static let columns = 16
    private static let rows = 192

    /// Compiling the source takes a noticeable moment; every renderer on the
    /// same device shares one library.
    nonisolated(unsafe) private static var libraryCache: [ObjectIdentifier: MTLLibrary] = [:]

    private static func library(for device: MTLDevice) throws -> MTLLibrary {
        let key = ObjectIdentifier(device)
        if let cached = libraryCache[key] { return cached }
        let options = MTLCompileOptions()
        options.fastMathEnabled = true
        let library = try device.makeLibrary(source: ShaderSource.metal, options: options)
        libraryCache[key] = library
        return library
    }

    init(device: MTLDevice, pixelFormat: MTLPixelFormat) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else {
            throw RendererError.setup("Could not create a Metal command queue.")
        }
        self.commandQueue = queue

        let library: MTLLibrary
        do {
            library = try Self.library(for: device)
        } catch {
            throw RendererError.setup("Shader compilation failed: \(error.localizedDescription)")
        }

        func pipeline(_ vertex: String, _ fragment: String,
                      format: MTLPixelFormat, blended: Bool) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            let attachment = descriptor.colorAttachments[0]!
            attachment.pixelFormat = format
            if blended {
                attachment.isBlendingEnabled = true
                attachment.rgbBlendOperation = .add
                attachment.alphaBlendOperation = .add
                attachment.sourceRGBBlendFactor = .sourceAlpha
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }

        bgPipeline = try pipeline("bg_vertex", "bg_fragment", format: pixelFormat, blended: false)
        // The panel's feathered far edge blends over the background.
        bendPipeline = try pipeline("bend_vertex", "bend_fragment", format: pixelFormat, blended: true)
        // The blur runs into offscreen targets that are always bgra8Unorm.
        blurPipeline = try pipeline("blur_vertex", "blur_fragment", format: .bgra8Unorm, blended: false)

        // Tessellated panel. The arc bend needs geometry along v; x only carries
        // the perspective sweep, so a coarse column count is plenty.
        var vertices: [SIMD2<Float>] = []
        vertices.reserveCapacity((Self.columns + 1) * (Self.rows + 1))
        for row in 0...Self.rows {
            let v = Float(row) / Float(Self.rows)
            for column in 0...Self.columns {
                vertices.append(SIMD2(Float(column) / Float(Self.columns), v))
            }
        }

        var indices: [UInt16] = []
        indices.reserveCapacity(Self.columns * Self.rows * 6)
        let stride = UInt16(Self.columns + 1)
        for row in 0..<Self.rows {
            for column in 0..<Self.columns {
                let base = UInt16(row) * stride + UInt16(column)
                indices.append(contentsOf: [base, base + 1, base + stride,
                                            base + 1, base + stride + 1, base + stride])
            }
        }

        guard let gridBuffer = device.makeBuffer(bytes: vertices,
                                                 length: MemoryLayout<SIMD2<Float>>.stride * vertices.count,
                                                 options: .storageModeShared),
              let indexBuffer = device.makeBuffer(bytes: indices,
                                                  length: MemoryLayout<UInt16>.stride * indices.count,
                                                  options: .storageModeShared) else {
            throw RendererError.setup("Could not allocate geometry buffers.")
        }
        self.gridBuffer = gridBuffer
        self.indexBuffer = indexBuffer
        self.indexCount = indices.count
    }

    enum RendererError: LocalizedError {
        case setup(String)
        var errorDescription: String? {
            if case .setup(let message) = self { return message }
            return nil
        }
    }

    // MARK: - Rendering

    func render(frame: Frame,
                source: MTLTexture?,
                to drawable: CAMetalDrawable,
                descriptor: MTLRenderPassDescriptor,
                viewSize: CGSize) {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        encode(frame: frame, source: source, descriptor: descriptor,
               viewSize: viewSize, in: commandBuffer)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Encodes the whole effect into `commandBuffer`. Split out from `render`
    /// so it can also be driven offscreen.
    func encode(frame: Frame,
                source: MTLTexture?,
                descriptor: MTLRenderPassDescriptor,
                viewSize: CGSize,
                in commandBuffer: MTLCommandBuffer) {
        var uniforms = makeUniforms(frame: frame, viewSize: viewSize)

        var soft: [MTLTexture] = []
        if let source, uniforms.blurAmount > 0.001, uniforms.progress > 0.001 {
            let radius = min(frame.blur * frame.style.look.blurBias, 1.5)
            soft = blurred(source: source, radius: radius, viewSize: viewSize,
                           commandBuffer: commandBuffer)
        }

        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        descriptor.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }

        encoder.setRenderPipelineState(bgPipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<BendUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        if let source {
            encoder.setRenderPipelineState(bendPipeline)
            encoder.setVertexBuffer(gridBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<BendUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<BendUniforms>.stride, index: 0)
            encoder.setFragmentTexture(source, index: 0)
            for level in 0..<Self.levelCount {
                encoder.setFragmentTexture(level < soft.count ? soft[level] : source, index: level + 1)
            }
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: indexCount,
                                          indexType: .uint16, indexBuffer: indexBuffer,
                                          indexBufferOffset: 0)
        }

        encoder.endEncoding()
    }

    private func makeUniforms(frame: Frame, viewSize: CGSize) -> BendUniforms {
        let look = frame.style.look
        var u = BendUniforms()

        u.aspect = Float(max(viewSize.width, 1) / max(viewSize.height, 1))
        u.hingeV = frame.hingeV

        // Smoothstep the whole effect: slow start, slow finish, no snap into
        // the bend. Tilt, blur, shade and feather all follow this one curve.
        let raw = min(max(frame.progress, 0), 1)
        let p = raw * raw * (3 - 2 * raw)
        u.progress = p
        u.theta = p * frame.intensityDegrees * .pi / 180

        // Softness maps to the arc radius. A tighter radius reads as a crease.
        u.bendRadius = 0.02 + frame.softness * 0.75

        // Perspective slider walks the camera in from far to close.
        u.focal = 6.0 - frame.perspective * 4.6

        u.blurAmount = min(frame.blur * look.blurBias * 1.25, 1.0)
        u.shadeAmount = min(frame.shadow * look.shadowBias * 0.9, 1.0)
        u.sheen = look.sheen
        u.saturation = look.saturation
        u.grain = look.grain
        u.time = frame.time
        u.vignette = 0.55 + frame.shadow * 0.35
        u.feather = 0.22
        u.tint = SIMD4(look.tint.x, look.tint.y, look.tint.z, 1)

        // Where the far edge lands on screen, for the background spill.
        let far = Self.farEdge(theta: u.theta, radius: u.bendRadius, hingeV: u.hingeV)
        let pyTop = far.y - (0.5 - u.hingeV)
        let wTop = (u.focal - far.z) / u.focal
        u.panelTop = (pyTop / 0.5) / max(wTop, 0.0001) * 0.5 + 0.5
        return u
    }

    /// Position of the panel's far edge after the bend, matching the arc that
    /// `bend_vertex` walks.
    private static func farEdge(theta: Float, radius r: Float,
                                hingeV: Float) -> (y: Float, z: Float) {
        let span = max(1 - hingeV, 0.0005)
        let arc = r * theta
        if arc >= span {
            let phi = span / r
            return (r * sin(phi), -r * (1 - cos(phi)))
        }
        let extra = span - arc
        return (r * sin(theta) + extra * cos(theta),
                -r * (1 - cos(theta)) - extra * sin(theta))
    }

    // MARK: - Blur

    /// Builds a three-level pyramid: each level is half the size of the last
    /// and blurred on top of the previous, so the radii grow geometrically.
    private func blurred(source: MTLTexture, radius: Float, viewSize: CGSize,
                         commandBuffer: MTLCommandBuffer) -> [MTLTexture] {
        // Never blur at more than the output resolution: a thumbnail does not
        // need a full-screen pyramid.
        let baseWidth = max(min(source.width, Int(viewSize.width)), 64)
        let baseHeight = max(baseWidth * source.height / max(source.width, 1), 1)
        ensureBlurTextures(baseWidth: baseWidth, baseHeight: baseHeight)
        guard blurLevels.count == Self.levelCount else { return [] }

        let scale = 0.6 + radius * 2.4

        func pass(from: MTLTexture, to: MTLTexture, dir: SIMD4<Float>) {
            let descriptor = MTLRenderPassDescriptor()
            descriptor.colorAttachments[0].texture = to
            descriptor.colorAttachments[0].loadAction = .dontCare
            descriptor.colorAttachments[0].storeAction = .store
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
            var direction = dir
            encoder.setRenderPipelineState(blurPipeline)
            encoder.setFragmentTexture(from, index: 0)
            encoder.setFragmentBytes(&direction, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }

        var result: [MTLTexture] = []
        var input = source
        for level in blurLevels {
            let texel = SIMD2<Float>(1.0 / Float(level.a.width), 1.0 / Float(level.a.height))
            pass(from: input, to: level.a, dir: SIMD4(0, 0, 0, 0))                 // downsample
            pass(from: level.a, to: level.b, dir: SIMD4(texel.x, 0, scale, 0))
            pass(from: level.b, to: level.a, dir: SIMD4(0, texel.y, scale, 0))
            pass(from: level.a, to: level.b, dir: SIMD4(texel.x, 0, scale * 2.4, 0))
            pass(from: level.b, to: level.a, dir: SIMD4(0, texel.y, scale * 2.4, 0))
            result.append(level.a)
            input = level.a
        }
        return result
    }

    private func ensureBlurTextures(baseWidth: Int, baseHeight: Int) {
        guard blurBase != (baseWidth, baseHeight) else { return }
        blurLevels = []
        var width = baseWidth
        var height = baseHeight
        for _ in 0..<Self.levelCount {
            width = max(width / 2, 1)
            height = max(height / 2, 1)
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            descriptor.usage = [.shaderRead, .renderTarget]
            descriptor.storageMode = .private
            guard let a = device.makeTexture(descriptor: descriptor),
                  let b = device.makeTexture(descriptor: descriptor) else {
                blurLevels = []
                blurBase = (0, 0)
                return
            }
            blurLevels.append((a, b))
        }
        blurBase = (baseWidth, baseHeight)
    }
}
