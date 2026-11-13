import Foundation
import simd

// Sidecar + placement types adapted from xibihe/walk-into-memory (ArtworkState.swift),
// the visionOS original. Kept byte-compatible with the pipeline's JSON output.

/// The JSON written next to each .spz by the pipeline (`python -m wim run ...`).
struct SceneSidecar: Codable, Sendable {
    struct Wind: Codable, Sendable {
        var ground: Float // Height of the scene origin above the floor (metres).
        var up: Float // Sign that turns local y into height: h = ground + up * y.
        var stillBox: [Float] // Wind-free screen box (x0 x1 y0 y1 in [-1, 1]), usually the person.
        var stillDepth: Float // The still box only protects points closer than this (metres).
        var waterBox: [Float]? // Optional water shimmer box.
    }

    var format: String?
    var version: Int
    var cameraHeight: Float? // Original camera height above the floor, metres.
    var edgeFrame: [Float]? // 24 floats: the original camera, used by the edge, wind and immersion effects.
    var wind: Wind?

    static let noBox: [Float] = [2, 2, 2, 2]

    var validEdgeFrame: [Float]? {
        guard let edgeFrame, edgeFrame.count == 24, edgeFrame.allSatisfy(\.isFinite) else { return nil }
        return edgeFrame
    }

    /// [ground, up, still x0 x1 y0 y1, water x0 x1 y0 y1, stillDepth] as the renderer expects it.
    var windConfig: [Float]? {
        guard validEdgeFrame != nil, let wind, wind.stillBox.count == 4 else { return nil }
        let water = wind.waterBox?.count == 4 ? wind.waterBox! : Self.noBox
        let values = [wind.ground, wind.up] + wind.stillBox + water + [wind.stillDepth]
        return values.allSatisfy(\.isFinite) ? values : nil
    }

    static func load(_ url: URL) -> SceneSidecar? {
        guard let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(SceneSidecar.self, from: data),
              value.version == 1 else { return nil }
        return value
    }
}

/// Where the scene sits in world space. Model space for pipeline scenes is the
/// levelled, y-down camera frame; `flipVertical` rotates it upright at placement.
struct ScenePlacement: Equatable, Sendable {
    var position = SIMD3<Float>.zero
    var scale: Float = 1
    var flipVertical = false
    var orientation = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))

    var rotation: simd_float4x4 {
        simd_float4x4(orientation * simd_quatf(angle: flipVertical ? .pi : 0,
                                               axis: SIMD3<Float>(1, 0, 0)))
    }

    var matrix: simd_float4x4 {
        var result = rotation
        result.columns.0 *= scale
        result.columns.1 *= scale
        result.columns.2 *= scale
        result.columns.3 = SIMD4<Float>(position, 1)
        return result
    }
}
