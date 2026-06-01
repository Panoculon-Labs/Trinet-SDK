// OrientationCubeView.swift — wireframe cube rotated by the fused orientation
// quaternion. Lightweight 3D-on-2D orthographic projection (no SceneKit), just
// enough to visualize device attitude alongside the video. Port of the Android
// SDK's OrientationCube.kt.

import SwiftUI

public struct OrientationCubeView: View {
    public let quaternion: Quaternion
    public init(quaternion: Quaternion) { self.quaternion = quaternion }

    private static let verts: [SIMD3<Float>] = [
        [-1,-1,-1], [1,-1,-1], [1,1,-1], [-1,1,-1],
        [-1,-1, 1], [1,-1, 1], [1,1, 1], [-1,1, 1],
    ]
    private static let edges: [(Int, Int)] = [
        (0,1),(1,2),(2,3),(3,0),
        (4,5),(5,6),(6,7),(7,4),
        (0,4),(1,5),(2,6),(3,7),
    ]

    // The +Z face, highlighted so rotation reads clearly (matches Android).
    private static let frontEdges: [(Int, Int)] = [(4,5),(5,6),(6,7),(7,4)]

    public var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height) * 0.26
            let cx = size.width / 2, cy = size.height / 2
            let pts: [CGPoint] = Self.verts.map { v in
                let r = Self.rotate(v, by: quaternion)
                // orthographic: ignore z, flip y for screen coords
                return CGPoint(x: cx + CGFloat(r.x) * s, y: cy - CGFloat(r.y) * s)
            }
            // Cube wireframe (faint cyan) so the colored axes read on top.
            var path = Path()
            for (a, b) in Self.edges { path.move(to: pts[a]); path.addLine(to: pts[b]) }
            ctx.stroke(path, with: .color(Color(red: 0, green: 0.898, blue: 1.0).opacity(0.55)),
                       lineWidth: 1.3)
            // Front (+Z) face brighter so "facing" is unambiguous.
            var front = Path()
            for (a, b) in Self.frontEdges { front.move(to: pts[a]); front.addLine(to: pts[b]) }
            ctx.stroke(front, with: .color(Color(red: 1.0, green: 0.251, blue: 0.506)), lineWidth: 2.5)

            // Device axes from the cube center, colored to MATCH the IMU plots
            // (x blue, y orange, z green) so the cube and the traces share a key.
            let origin = CGPoint(x: cx, y: cy)
            let axes: [(SIMD3<Float>, String, Color)] = [
                ([1.5, 0, 0], "X", ImuAxis.colors[0]),
                ([0, 1.5, 0], "Y", ImuAxis.colors[1]),
                ([0, 0, 1.5], "Z", ImuAxis.colors[2]),
            ]
            for (v, label, color) in axes {
                let r = Self.rotate(v, by: quaternion)
                let p = CGPoint(x: cx + CGFloat(r.x) * s, y: cy - CGFloat(r.y) * s)
                var ap = Path(); ap.move(to: origin); ap.addLine(to: p)
                ctx.stroke(ap, with: .color(color), lineWidth: 2)
                ctx.draw(Text(label).font(.system(size: 9, weight: .bold)).foregroundColor(color),
                         at: p)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Device orientation")
        .accessibilityValue(Self.attitudeDescription(quaternion))
    }

    /// Roll/pitch in degrees for VoiceOver, from the quaternion (w,x,y,z).
    static func attitudeDescription(_ q: Quaternion) -> String {
        let sinr = 2 * (q.w * q.x + q.y * q.z)
        let cosr = 1 - 2 * (q.x * q.x + q.y * q.y)
        let roll = atan2(sinr, cosr) * 180 / .pi
        let sinp = max(-1, min(1, 2 * (q.w * q.y - q.z * q.x)))
        let pitch = asin(sinp) * 180 / .pi
        return String(format: "roll %.0f°, pitch %.0f°", roll, pitch)
    }

    /// Rotate a 3-vector by quaternion (w,x,y,z): v + 2w(q×v) + 2(q×(q×v)).
    static func rotate(_ v: SIMD3<Float>, by q: Quaternion) -> SIMD3<Float> {
        let w = q.w, x = q.x, y = q.y, z = q.z
        let tx = 2 * (y * v.z - z * v.y)
        let ty = 2 * (z * v.x - x * v.z)
        let tz = 2 * (x * v.y - y * v.x)
        return SIMD3<Float>(
            v.x + w * tx + (y * tz - z * ty),
            v.y + w * ty + (z * tx - x * tz),
            v.z + w * tz + (x * ty - y * tx)
        )
    }
}
