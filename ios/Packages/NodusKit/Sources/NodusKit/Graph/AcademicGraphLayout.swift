import CoreGraphics
import Foundation

public enum AcademicGraphLayoutMode: String, Sendable, Codable, CaseIterable, Identifiable {
    case force, radial
    public var id: String { rawValue }
}

public struct AcademicGraphPoint: Sendable, Hashable, Codable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

/// Deterministic layout actor shared by every graph lens.
///
/// Force mode uses a Barnes–Hut quadtree for repulsion, so large publications avoid the
/// quadratic all-pairs loop. The actor keeps CPU simulation off the main thread; the Metal
/// surface only receives the resulting immutable positions.
public actor AcademicGraphLayoutEngine {
    public init() {}

    public func layout(
        graph: AcademicGraph,
        mode: AcademicGraphLayoutMode,
        iterations: Int = 160
    ) -> [String: AcademicGraphPoint] {
        guard !graph.nodes.isEmpty else { return [:] }
        switch mode {
        case .radial: return radial(graph.nodes)
        case .force: return force(graph, iterations: max(20, min(iterations, 360)))
        }
    }

    private func radial(_ nodes: [AcademicGraphNode]) -> [String: AcademicGraphPoint] {
        let sorted = nodes.sorted { $0.weight == $1.weight ? $0.id < $1.id : $0.weight > $1.weight }
        var result: [String: AcademicGraphPoint] = [:]
        for (index, node) in sorted.enumerated() {
            if index == 0 { result[node.id] = .init(x: 0, y: 0); continue }
            let ring = Int(sqrt(Double(index))) + 1
            let first = (ring - 1) * (ring - 1)
            let count = max(6, ring * 7)
            let angle = Double(index - first) / Double(count) * .pi * 2
            let radius = min(0.92, Double(ring) * 0.17)
            result[node.id] = .init(x: cos(angle) * radius, y: sin(angle) * radius)
        }
        return result
    }

    private func force(_ graph: AcademicGraph, iterations: Int) -> [String: AcademicGraphPoint] {
        let nodes = graph.nodes, indexById = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($0.element.id, $0.offset) })
        var points = nodes.map { seededPoint($0.id) }
        var velocity = Array(repeating: Vector.zero, count: nodes.count)
        let masses = nodes.map { max(0.8, min(4.5, 0.8 + log1p($0.weight) * 0.55)) }
        let edges = graph.edges.compactMap { edge -> (Int, Int, Double)? in
            guard let source = indexById[edge.source], let target = indexById[edge.target], source != target else { return nil }
            return (source, target, max(0.15, edge.weight))
        }

        for step in 0..<iterations {
            let tree = Quad(indices: Array(points.indices), points: points, masses: masses, bounds: Bounds.square(containing: points), depth: 0)
            var force = Array(repeating: Vector.zero, count: nodes.count)
            for index in points.indices {
                tree.accumulate(on: index, point: points[index], theta: 0.72, strength: 0.0038, into: &force[index])
            }
            for (source, target, weight) in edges {
                let delta = points[target] - points[source]
                let distance = max(0.015, delta.length)
                let desired = 0.19 + 0.04 / weight
                let pull = delta.normalized * ((distance - desired) * 0.018 * weight)
                force[source] = force[source] + pull
                force[target] = force[target] - pull
            }
            let cooling = max(0.025, 1 - Double(step) / Double(iterations))
            for index in points.indices {
                force[index] = force[index] - points[index] * 0.0025
                velocity[index] = (velocity[index] + force[index]) * 0.82
                points[index] = (points[index] + velocity[index] * cooling).clamped(to: -0.96...0.96)
            }
        }
        return Dictionary(uniqueKeysWithValues: nodes.indices.map { (nodes[$0].id, AcademicGraphPoint(x: points[$0].x, y: points[$0].y)) })
    }

    private func seededPoint(_ id: String) -> Vector {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in id.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        let angle = Double(hash % 100_000) / 100_000 * .pi * 2
        let radius = 0.16 + Double((hash >> 17) % 10_000) / 10_000 * 0.58
        return Vector(x: cos(angle) * radius, y: sin(angle) * radius)
    }
}

private struct Vector: Sendable {
    var x: Double
    var y: Double
    static let zero = Vector(x: 0, y: 0)
    var length: Double { sqrt(x * x + y * y) }
    var normalized: Vector { let divisor = max(0.000_01, length); return self * (1 / divisor) }
    func clamped(to range: ClosedRange<Double>) -> Vector {
        .init(x: min(range.upperBound, max(range.lowerBound, x)), y: min(range.upperBound, max(range.lowerBound, y)))
    }
    static func +(lhs: Vector, rhs: Vector) -> Vector { .init(x: lhs.x + rhs.x, y: lhs.y + rhs.y) }
    static func -(lhs: Vector, rhs: Vector) -> Vector { .init(x: lhs.x - rhs.x, y: lhs.y - rhs.y) }
    static func *(lhs: Vector, rhs: Double) -> Vector { .init(x: lhs.x * rhs, y: lhs.y * rhs) }
}

private struct Bounds {
    let minX: Double, minY: Double, size: Double
    var maxX: Double { minX + size }
    var maxY: Double { minY + size }

    static func square(containing points: [Vector]) -> Bounds {
        let minX = points.map(\.x).min() ?? -1, maxX = points.map(\.x).max() ?? 1
        let minY = points.map(\.y).min() ?? -1, maxY = points.map(\.y).max() ?? 1
        let size = max(0.1, max(maxX - minX, maxY - minY) * 1.05)
        return Bounds(minX: (minX + maxX - size) / 2, minY: (minY + maxY - size) / 2, size: size)
    }
}

private final class Quad {
    let indices: [Int]
    let bounds: Bounds
    let mass: Double
    let centre: Vector
    let children: [Quad]

    init(indices: [Int], points: [Vector], masses: [Double], bounds: Bounds, depth: Int) {
        self.indices = indices
        self.bounds = bounds
        mass = max(0.000_01, indices.reduce(0) { $0 + masses[$1] })
        centre = indices.reduce(Vector.zero) { $0 + points[$1] * masses[$1] } * (1 / mass)
        guard indices.count > 1, depth < 15, bounds.size > 0.000_1 else { children = []; return }
        let half = bounds.size / 2, midX = bounds.minX + half, midY = bounds.minY + half
        var groups = Array(repeating: [Int](), count: 4)
        for index in indices {
            let x = points[index].x >= midX ? 1 : 0, y = points[index].y >= midY ? 2 : 0
            groups[x + y].append(index)
        }
        children = groups.enumerated().compactMap { quadrant, group in
            guard !group.isEmpty, group.count < indices.count else { return nil }
            let x = quadrant % 2, y = quadrant / 2
            return Quad(
                indices: group, points: points, masses: masses,
                bounds: Bounds(minX: bounds.minX + Double(x) * half, minY: bounds.minY + Double(y) * half, size: half),
                depth: depth + 1
            )
        }
    }

    func accumulate(on index: Int, point: Vector, theta: Double, strength: Double, into result: inout Vector) {
        if indices.count == 1, indices[0] == index { return }
        let delta = point - centre, distance = max(0.012, delta.length)
        if children.isEmpty || bounds.size / distance < theta {
            result = result + delta.normalized * (strength * mass / (distance * distance + 0.008))
            return
        }
        for child in children { child.accumulate(on: index, point: point, theta: theta, strength: strength, into: &result) }
    }
}
