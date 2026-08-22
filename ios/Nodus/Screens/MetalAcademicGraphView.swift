import MetalKit
import NodusKit
import SwiftUI

/// Thin SwiftUI host for the same graph on iPhone and iPad. All simulation is completed by
/// `AcademicGraphLayoutEngine`; this view only uploads immutable line/point vertices to Metal.
struct AcademicMetalGraphSurface: UIViewRepresentable {
    let graph: AcademicGraph
    let positions: [String: AcademicGraphPoint]
    let zoom: CGFloat
    let offset: CGSize
    let selectedId: String?
    let accent: Color

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero)
        view.device = MTLCreateSystemDefaultDevice()
        view.isOpaque = false
        view.backgroundColor = .clear
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = 30
        view.enableSetNeedsDisplay = true
        view.isPaused = true
        context.coordinator.install(on: view)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.update(
            graph: graph, positions: positions, zoom: zoom, offset: offset,
            selectedId: selectedId, accent: UIColor(accent)
        )
        view.setNeedsDisplay()
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        private struct Vertex {
            /// `xy` is the clip-space position and `w` the point size. Two aligned
            /// float4 values keep Swift and Metal's ABI identical on every device.
            var positionAndSize: SIMD4<Float>
            var color: SIMD4<Float>
        }

        private var queue: MTLCommandQueue?
        private var linePipeline: MTLRenderPipelineState?
        private var pointPipeline: MTLRenderPipelineState?
        private var lines: [Vertex] = []
        private var points: [Vertex] = []

        func install(on view: MTKView) {
            guard let device = view.device else { return }
            queue = device.makeCommandQueue()
            let source = """
            #include <metal_stdlib>
            using namespace metal;
            struct Vertex { float4 positionAndSize; float4 color; };
            struct Out { float4 position [[position]]; float4 color; float size [[point_size]]; };
            vertex Out vertex_main(const device Vertex *vertices [[buffer(0)]], uint id [[vertex_id]]) {
                Out out; out.position = float4(vertices[id].positionAndSize.xy, 0, 1);
                out.color = vertices[id].color; out.size = vertices[id].positionAndSize.w; return out;
            }
            fragment float4 line_fragment(Out in [[stage_in]]) { return in.color; }
            fragment float4 point_fragment(Out in [[stage_in]], float2 coordinate [[point_coord]]) {
                float distance = length(coordinate - float2(0.5));
                float alpha = 1.0 - smoothstep(0.42, 0.5, distance);
                return float4(in.color.rgb, in.color.a * alpha);
            }
            """
            guard let library = try? device.makeLibrary(source: source, options: nil),
                  let vertex = library.makeFunction(name: "vertex_main") else { return }
            func pipeline(fragment name: String) -> MTLRenderPipelineState? {
                guard let fragment = library.makeFunction(name: name) else { return nil }
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = vertex
                descriptor.fragmentFunction = fragment
                descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
                descriptor.colorAttachments[0].isBlendingEnabled = true
                descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
                descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
                descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
                descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
                return try? device.makeRenderPipelineState(descriptor: descriptor)
            }
            linePipeline = pipeline(fragment: "line_fragment")
            pointPipeline = pipeline(fragment: "point_fragment")
            view.delegate = self
        }

        func update(
            graph: AcademicGraph, positions: [String: AcademicGraphPoint], zoom: CGFloat,
            offset: CGSize, selectedId: String?, accent: UIColor
        ) {
            let accentComponents = accent.rgba
            let transformed: [String: SIMD2<Float>] = positions.mapValues { point in
                SIMD2<Float>(
                    Float(point.x * Double(zoom) + Double(offset.width) / 360),
                    Float(point.y * Double(zoom) - Double(offset.height) / 360)
                )
            }
            lines = graph.edges.flatMap { edge -> [Vertex] in
                guard let source = transformed[edge.source], let target = transformed[edge.target] else { return [] }
                let color: SIMD4<Float> = switch edge.kind {
                case "contradicts", "refutes": .init(0.94, 0.28, 0.34, 0.68)
                case "supports": .init(0.22, 0.78, 0.52, 0.52)
                case "extends", "refines": .init(0.32, 0.62, 0.98, 0.5)
                default: .init(0.55, 0.56, 0.62, 0.34)
                }
                return [
                    .init(positionAndSize: .init(source.x, source.y, 0, 1), color: color),
                    .init(positionAndSize: .init(target.x, target.y, 0, 1), color: color),
                ]
            }
            let maxWeight = max(1, graph.nodes.map(\.weight).max() ?? 1)
            points = graph.nodes.compactMap { node in
                guard let position = transformed[node.id] else { return nil }
                let selected = node.id == selectedId
                let size = Float(14 + min(20, node.weight / maxWeight * 20) + (selected ? 8 : 0))
                let kindColor: SIMD4<Float> = switch node.kind {
                case "theme": .init(1.0, 0.58, 0.08, 1)
                case "claim": .init(0.39, 0.43, 0.96, 1)
                case "finding": .init(0.14, 0.76, 0.58, 1)
                case "construct", "framework": .init(0.05, 0.69, 0.82, 1)
                case "method": .init(0.93, 0.24, 0.57, 1)
                case "author": .init(0.64, 0.38, 0.95, 1)
                default: .init(accentComponents.0, accentComponents.1, accentComponents.2, 1)
                }
                let color = selected
                    ? SIMD4<Float>(1, 1, 1, 1)
                    : SIMD4<Float>(kindColor.x, kindColor.y, kindColor.z, node.read ? 0.58 : 0.96)
                return Vertex(positionAndSize: .init(position.x, position.y, 0, size), color: color)
            }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let drawable = view.currentDrawable, let pass = view.currentRenderPassDescriptor,
                  let queue, let command = queue.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: pass)
            else { return }
            if let linePipeline, let device = view.device, let buffer = makeBuffer(lines, device: device) {
                encoder.setRenderPipelineState(linePipeline)
                encoder.setVertexBuffer(buffer, offset: 0, index: 0)
                encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: lines.count)
            }
            if let pointPipeline, let device = view.device, let buffer = makeBuffer(points, device: device) {
                encoder.setRenderPipelineState(pointPipeline)
                encoder.setVertexBuffer(buffer, offset: 0, index: 0)
                encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: points.count)
            }
            encoder.endEncoding()
            command.present(drawable)
            command.commit()
        }

        private func makeBuffer(_ vertices: [Vertex], device: MTLDevice) -> MTLBuffer? {
            guard !vertices.isEmpty else { return nil }
            return vertices.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return nil }
                return device.makeBuffer(bytes: base, length: bytes.count)
            }
        }
    }
}

private extension UIColor {
    var rgba: (Float, Float, Float, Float) {
        var red: CGFloat = 0.4, green: CGFloat = 0.35, blue: CGFloat = 0.96, alpha: CGFloat = 1
        getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return (Float(red), Float(green), Float(blue), Float(alpha))
    }
}
