// SceneKit prepare view: build plate + real mesh from libslic3r + G-code paths.
// Coordinate convention:
//   libslic3r is Z-up (XY bed). SceneKit is Y-up.
//   All print geometry lives under "content" node rotated R_x(-90°):
//     (x, y, z)_slic3r  →  (x, z, -y)_scenekit
//   so the bed stays a simple XY plane and the grid always sits under the model.

import SwiftUI
import SceneKit
import UIKit

/// Interactive build plate with official-engine mesh geometry + optional G-code paths.
struct PlateSceneView: UIViewRepresentable {
    var mesh: MeshGeometry?
    var gcodeNode: SCNNode? = nil
    var showGCode: Bool = false
    var bedSize: SIMD2<Float> = SIMD2(220, 220)
    /// Optional machine bed texture / cover PNG path (from system profiles)
    var bedTexturePath: String? = nil
    var accent: UIColor = UIColor(red: 0, green: 150 / 255, blue: 136 / 255, alpha: 1)

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = makeScene()
        view.backgroundColor = UIColor(red: 0x2D / 255, green: 0x2D / 255, blue: 0x31 / 255, alpha: 1)
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling4X
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.inertiaEnabled = true
        view.defaultCameraController.maximumVerticalAngle = 89
        view.defaultCameraController.minimumVerticalAngle = 5
        if let cam = view.scene?.rootNode.childNode(withName: "camera", recursively: false) {
            view.pointOfView = cam
        }
        context.coordinator.view = view
        context.coordinator.lastBed = bedSize
        context.coordinator.lastTexture = bedTexturePath ?? ""
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        guard let scene = view.scene,
              let content = scene.rootNode.childNode(withName: "content", recursively: false)
        else { return }

        // Bed size / texture recreate if missing or changed
        let texKey = bedTexturePath ?? ""
        let bedMissing = content.childNode(withName: "bed", recursively: false) == nil
        if bedMissing
            || context.coordinator.lastBed.x != bedSize.x
            || context.coordinator.lastBed.y != bedSize.y
            || context.coordinator.lastTexture != texKey {
            content.childNode(withName: "bed", recursively: false)?.removeFromParentNode()
            let bed = makeBedNode(size: bedSize, accent: accent, texturePath: bedTexturePath)
            bed.name = "bed"
            content.addChildNode(bed)
            context.coordinator.lastBed = bedSize
            context.coordinator.lastTexture = texKey
            // Re-frame when bed changes so plate stays in view
            if let mesh {
                context.coordinator.frameCamera(view: view, mesh: mesh, bedSize: bedSize)
            } else {
                context.coordinator.frameCameraOnBed(view: view, bedSize: bedSize)
            }
        }

        // Mesh model
        let meshKey = mesh.map { "\($0.vertexCount)-\($0.indices.count)-\($0.min.x)-\($0.max.x)" } ?? "nil"
        if context.coordinator.lastMeshKey != meshKey {
            content.childNode(withName: "model", recursively: false)?.removeFromParentNode()
            if let mesh {
                let node = mesh.makeNode(color: accent)
                node.name = "model"
                content.addChildNode(node)
                context.coordinator.frameCamera(view: view, mesh: mesh, bedSize: bedSize)
            } else {
                context.coordinator.frameCameraOnBed(view: view, bedSize: bedSize)
            }
            context.coordinator.lastMeshKey = meshKey
        }

        // G-code toolpaths (Preview tab) — also under content (Z-up)
        content.childNode(withName: "gcode", recursively: false)?.removeFromParentNode()
        if showGCode, let gcodeNode {
            let clone = gcodeNode.clone()
            clone.name = "gcode"
            // G-code nodes were previously self-rotated; strip extra rotation if present
            clone.eulerAngles = SCNVector3Zero
            content.addChildNode(clone)
            content.childNode(withName: "model", recursively: false)?.opacity = 0.15
        } else {
            content.childNode(withName: "model", recursively: false)?.opacity = 1.0
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func makeScene() -> SCNScene {
        let scene = SCNScene()

        // Lights (SceneKit world / Y-up)
        let ambient = SCNNode()
        ambient.light = {
            let l = SCNLight()
            l.type = .ambient
            l.intensity = 500
            l.color = UIColor.white
            return l
        }()
        scene.rootNode.addChildNode(ambient)

        let key = SCNNode()
        key.light = {
            let l = SCNLight()
            l.type = .directional
            l.intensity = 900
            l.castsShadow = true
            l.shadowMode = .deferred
            l.shadowColor = UIColor.black.withAlphaComponent(0.35)
            return l
        }()
        key.eulerAngles = SCNVector3(-Float.pi / 3.2, Float.pi / 4.5, 0)
        key.position = SCNVector3(0, 400, 200)
        scene.rootNode.addChildNode(key)

        let fill = SCNNode()
        fill.light = {
            let l = SCNLight()
            l.type = .directional
            l.intensity = 280
            return l
        }()
        fill.eulerAngles = SCNVector3(-Float.pi / 6, -Float.pi / 3, 0)
        scene.rootNode.addChildNode(fill)

        // Content root: Z-up → Y-up
        let content = SCNNode()
        content.name = "content"
        content.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
        scene.rootNode.addChildNode(content)

        // Build plate (XY in slic3r / content space)
        let bed = makeBedNode(size: bedSize, accent: accent, texturePath: bedTexturePath)
        bed.name = "bed"
        content.addChildNode(bed)

        // Camera in SceneKit world space
        let cam = SCNNode()
        cam.name = "camera"
        cam.camera = SCNCamera()
        cam.camera?.zNear = 0.5
        cam.camera?.zFar = 8000
        cam.camera?.fieldOfView = 42
        // Default 3/4 view of a 220mm plate (slic3r center 110,110 → world 110, 0, -110)
        let cx = bedSize.x * 0.5
        let cy = bedSize.y * 0.5
        cam.position = SCNVector3(cx + 180, 200, -cy + 220)
        cam.look(at: SCNVector3(cx, 0, -cy))
        scene.rootNode.addChildNode(cam)

        return scene
    }

    /// Bed in content/Z-up space: SCNPlane is already XY, no extra rotation.
    private func makeBedNode(size: SIMD2<Float>, accent: UIColor, texturePath: String? = nil) -> SCNNode {
        let w = CGFloat(size.x)
        let h = CGFloat(size.y)
        let plane = SCNPlane(width: w, height: h)
        plane.widthSegmentCount = 1
        plane.heightSegmentCount = 1

        let mat = SCNMaterial()
        if let texturePath, let img = UIImage(contentsOfFile: texturePath) {
            mat.diffuse.contents = img
            mat.roughness.contents = 0.85
            mat.metalness.contents = 0.05
        } else {
            mat.diffuse.contents = UIColor(red: 0.18, green: 0.19, blue: 0.21, alpha: 1)
            mat.roughness.contents = 0.9
            mat.metalness.contents = 0.08
        }
        mat.isDoubleSided = true
        mat.locksAmbientWithDiffuse = true
        plane.materials = [mat]

        let node = SCNNode(geometry: plane)
        // Center of plate in XY (slic3r printable origin usually 0,0)
        node.position = SCNVector3(size.x * 0.5, size.y * 0.5, -0.02)

        // Grid over plate (lighter when textured so logo stays readable)
        let hasTex = texturePath != nil && !(texturePath ?? "").isEmpty
        let grid = makeGridNode(size: size, accent: accent, muted: hasTex)
        node.addChildNode(grid)

        // Teal rim slightly larger, behind plate surface
        let rim = SCNPlane(width: w + 2.0, height: h + 2.0)
        let rimMat = SCNMaterial()
        rimMat.diffuse.contents = accent.withAlphaComponent(0.45)
        rimMat.isDoubleSided = true
        rimMat.lightingModel = .constant
        rim.materials = [rimMat]
        let rimNode = SCNNode(geometry: rim)
        rimNode.position = SCNVector3(0, 0, -0.08)
        node.addChildNode(rimNode)

        // Origin marker (0,0 corner) — small accent cube
        let origin = SCNBox(width: 4, height: 4, length: 1.5, chamferRadius: 0)
        let oMat = SCNMaterial()
        oMat.diffuse.contents = accent
        oMat.lightingModel = .constant
        origin.materials = [oMat]
        let originNode = SCNNode(geometry: origin)
        // Plane local: (-w/2, -h/2) is bed (0,0)
        originNode.position = SCNVector3(-size.x * 0.5 + 2, -size.y * 0.5 + 2, 0.8)
        node.addChildNode(originNode)

        return node
    }

    private func makeGridNode(size: SIMD2<Float>, accent: UIColor, muted: Bool = false) -> SCNNode {
        let parent = SCNNode()
        let step: Float = 10
        var verts: [SCNVector3] = []
        let x0: Float = -size.x * 0.5
        let y0: Float = -size.y * 0.5
        let x1 = x0 + size.x
        let y1 = y0 + size.y

        var x = x0
        while x <= x1 + 0.01 {
            verts.append(SCNVector3(x, y0, 0.05))
            verts.append(SCNVector3(x, y1, 0.05))
            x += step
        }
        var y = y0
        while y <= y1 + 0.01 {
            verts.append(SCNVector3(x0, y, 0.05))
            verts.append(SCNVector3(x1, y, 0.05))
            y += step
        }

        // Major every 50mm (brighter)
        var majorVerts: [SCNVector3] = []
        x = x0
        while x <= x1 + 0.01 {
            if abs(x.truncatingRemainder(dividingBy: 50)) < 0.01 || abs(x) < 0.01 {
                majorVerts.append(SCNVector3(x, y0, 0.06))
                majorVerts.append(SCNVector3(x, y1, 0.06))
            }
            x += step
        }
        y = y0
        while y <= y1 + 0.01 {
            if abs(y.truncatingRemainder(dividingBy: 50)) < 0.01 || abs(y) < 0.01 {
                majorVerts.append(SCNVector3(x0, y, 0.06))
                majorVerts.append(SCNVector3(x1, y, 0.06))
            }
            y += step
        }

        func lineNode(from verts: [SCNVector3], alpha: CGFloat) -> SCNNode {
            guard verts.count >= 2 else { return SCNNode() }
            let src = SCNGeometrySource(vertices: verts)
            var indices: [Int32] = []
            for i in 0..<(verts.count / 2) {
                indices.append(Int32(i * 2))
                indices.append(Int32(i * 2 + 1))
            }
            let idxData = Data(bytes: indices, count: indices.count * MemoryLayout<Int32>.size)
            let elem = SCNGeometryElement(
                data: idxData,
                primitiveType: .line,
                primitiveCount: indices.count / 2,
                bytesPerIndex: MemoryLayout<Int32>.size
            )
            let geo = SCNGeometry(sources: [src], elements: [elem])
            let mat = SCNMaterial()
            mat.diffuse.contents = UIColor.white.withAlphaComponent(alpha)
            mat.lightingModel = .constant
            mat.isDoubleSided = true
            geo.materials = [mat]
            return SCNNode(geometry: geo)
        }

        let minorA: CGFloat = muted ? 0.06 : 0.14
        let majorA: CGFloat = muted ? 0.14 : 0.32
        parent.addChildNode(lineNode(from: verts, alpha: minorA))
        parent.addChildNode(lineNode(from: majorVerts, alpha: majorA))
        return parent
    }

    final class Coordinator {
        weak var view: SCNView?
        var lastMeshKey: String = ""
        var lastBed: SIMD2<Float> = SIMD2(0, 0)
        var lastTexture: String = ""

        /// World-space target of bed center after content R_x(-90): (cx, 0, -cy)
        private func bedCenterWorld(bedSize: SIMD2<Float>) -> SCNVector3 {
            SCNVector3(bedSize.x * 0.5, 0, -bedSize.y * 0.5)
        }

        func frameCameraOnBed(view: SCNView, bedSize: SIMD2<Float>) {
            guard let cam = view.scene?.rootNode.childNode(withName: "camera", recursively: false) else { return }
            let target = bedCenterWorld(bedSize: bedSize)
            let plate = max(bedSize.x, bedSize.y, 100)
            let dist = plate * 1.05
            cam.position = SCNVector3(
                target.x + dist * 0.55,
                dist * 0.72,
                target.z + dist * 0.75
            )
            cam.look(at: target)
            view.pointOfView = cam
        }

        func frameCamera(view: SCNView, mesh: MeshGeometry, bedSize: SIMD2<Float>) {
            guard let cam = view.scene?.rootNode.childNode(withName: "camera", recursively: false) else { return }

            // Mesh in slic3r Z-up under content; world after R_x(-90): (x, z, -y)
            let mx = (mesh.min.x + mesh.max.x) * 0.5
            let my = (mesh.min.y + mesh.max.y) * 0.5
            let mz = (mesh.min.z + mesh.max.z) * 0.5
            let modelWorld = SCNVector3(mx, mz, -my)

            // Blend toward bed center so the plate stays visible even for small models
            let bed = bedCenterWorld(bedSize: bedSize)
            let target = SCNVector3(
                modelWorld.x * 0.35 + bed.x * 0.65,
                max(modelWorld.y, 0) * 0.5,
                modelWorld.z * 0.35 + bed.z * 0.65
            )

            let meshExt = max(
                mesh.max.x - mesh.min.x,
                mesh.max.y - mesh.min.y,
                mesh.max.z - mesh.min.z,
                15
            )
            let plate = max(bedSize.x, bedSize.y, 100)
            // Pull back enough to include most of the plate + model (not a tight cube-only crop)
            let dist = max(meshExt * 3.5, plate * 0.55, 140)

            cam.position = SCNVector3(
                target.x + dist * 0.55,
                dist * 0.65,
                target.z + dist * 0.8
            )
            cam.look(at: target)
            view.pointOfView = cam
        }
    }
}

// MARK: - Mesh from C API

struct MeshGeometry {
    var positions: [Float] // xyz * n  (slic3r Z-up)
    var indices: [UInt32]
    var min: SIMD3<Float>
    var max: SIMD3<Float>

    var vertexCount: Int { positions.count / 3 }

    /// Node lives under "content" (Z-up) — no extra euler rotation.
    func makeNode(color: UIColor) -> SCNNode {
        let vcount = vertexCount
        guard vcount > 0, !indices.isEmpty else { return SCNNode() }

        let posData = Data(bytes: positions, count: positions.count * MemoryLayout<Float>.size)
        let source = SCNGeometrySource(
            data: posData,
            semantic: .vertex,
            vectorCount: vcount,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<Float>.size * 3
        )

        var normals = [Float](repeating: 0, count: positions.count)
        let triCount = indices.count / 3
        for t in 0..<triCount {
            let i0 = Int(indices[t * 3])
            let i1 = Int(indices[t * 3 + 1])
            let i2 = Int(indices[t * 3 + 2])
            guard i0 < vcount, i1 < vcount, i2 < vcount else { continue }
            let ax = positions[i0 * 3], ay = positions[i0 * 3 + 1], az = positions[i0 * 3 + 2]
            let bx = positions[i1 * 3], by = positions[i1 * 3 + 1], bz = positions[i1 * 3 + 2]
            let cx = positions[i2 * 3], cy = positions[i2 * 3 + 1], cz = positions[i2 * 3 + 2]
            let ux = bx - ax, uy = by - ay, uz = bz - az
            let vx = cx - ax, vy = cy - ay, vz = cz - az
            var nx: Float = uy * vz - uz * vy
            var ny: Float = uz * vx - ux * vz
            var nz: Float = ux * vy - uy * vx
            let lenSq: Float = nx * nx + ny * ny + nz * nz
            let len: Float = lenSq > 0.0000001 ? sqrtf(lenSq) : 0.0001
            nx /= len; ny /= len; nz /= len
            for i in [i0, i1, i2] {
                normals[i * 3] += nx
                normals[i * 3 + 1] += ny
                normals[i * 3 + 2] += nz
            }
        }
        for i in 0..<vcount {
            let nx: Float = normals[i * 3]
            let ny: Float = normals[i * 3 + 1]
            let nz: Float = normals[i * 3 + 2]
            let lenSq: Float = nx * nx + ny * ny + nz * nz
            let len: Float = lenSq > 0.0000001 ? sqrtf(lenSq) : 0.0001
            normals[i * 3] = nx / len
            normals[i * 3 + 1] = ny / len
            normals[i * 3 + 2] = nz / len
        }
        let nData = Data(bytes: normals, count: normals.count * MemoryLayout<Float>.size)
        let nSource = SCNGeometrySource(
            data: nData,
            semantic: .normal,
            vectorCount: vcount,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<Float>.size * 3
        )

        let idxData = Data(bytes: indices, count: indices.count * MemoryLayout<UInt32>.size)
        let element = SCNGeometryElement(
            data: idxData,
            primitiveType: .triangles,
            primitiveCount: triCount,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )

        let geo = SCNGeometry(sources: [source, nSource], elements: [element])
        let mat = SCNMaterial()
        mat.diffuse.contents = color
        mat.metalness.contents = 0.12
        mat.roughness.contents = 0.48
        mat.isDoubleSided = false
        geo.materials = [mat]

        // No eulerAngles — parent "content" already converts Z-up → Y-up
        return SCNNode(geometry: geo)
    }
}

// MARK: - G-code path preview (slic3r Z-up; parent content rotates)

struct GCodePathGeometry {
    struct Segment {
        var points: [SCNVector3]
        var feature: String
    }
    var segments: [Segment]
    var zMin: Float = 0
    var zMax: Float = 0

    static func parse(url: URL, maxPoints: Int = 120_000) -> GCodePathGeometry? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var x: Float = 0, y: Float = 0, z: Float = 0
        var feature = "Unknown"
        var segs: [Segment] = []
        var cur: [SCNVector3] = []
        var zMin: Float = .greatestFiniteMagnitude
        var zMax: Float = -.greatestFiniteMagnitude
        var total = 0

        func flush() {
            if cur.count > 1 {
                segs.append(Segment(points: cur, feature: feature))
            }
            cur = []
        }

        for line in text.split(whereSeparator: \.isNewline) {
            if total >= maxPoints { break }
            let s = line.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix(";TYPE:") || s.hasPrefix(";TYPE :") {
                flush()
                feature = String(s.dropFirst(6).trimmingCharacters(in: .whitespaces))
                continue
            }
            guard s.hasPrefix("G0") || s.hasPrefix("G1") || s.hasPrefix("g0") || s.hasPrefix("g1") else { continue }
            var nx = x, ny = y, nz = z
            var hasE = false
            for token in s.split(separator: " ") {
                if token.hasPrefix("X") || token.hasPrefix("x") { nx = Float(token.dropFirst()) ?? nx }
                else if token.hasPrefix("Y") || token.hasPrefix("y") { ny = Float(token.dropFirst()) ?? ny }
                else if token.hasPrefix("Z") || token.hasPrefix("z") { nz = Float(token.dropFirst()) ?? nz }
                else if token.hasPrefix("E") || token.hasPrefix("e") {
                    if let e = Float(token.dropFirst()), e > 0 { hasE = true }
                }
            }
            if hasE {
                if cur.isEmpty { cur.append(SCNVector3(x, y, z)) }
                cur.append(SCNVector3(nx, ny, nz))
                zMin = min(zMin, nz)
                zMax = max(zMax, nz)
                total += 1
            } else if abs(nz - z) > 0.01 {
                flush()
            }
            x = nx; y = ny; z = nz
        }
        flush()
        guard !segs.isEmpty else { return nil }
        if zMin > zMax { zMin = 0; zMax = 0.2 }
        return GCodePathGeometry(segments: segs, zMin: zMin, zMax: zMax)
    }

    func filtered(maxZ: Float) -> GCodePathGeometry {
        var out: [Segment] = []
        for seg in segments {
            let pts = seg.points.filter { $0.z <= maxZ + 0.001 }
            if pts.count > 1 {
                out.append(Segment(points: pts, feature: seg.feature))
            }
        }
        return GCodePathGeometry(segments: out, zMin: zMin, zMax: maxZ)
    }

    static func color(for feature: String) -> UIColor {
        let f = feature.lowercased()
        if f.contains("outer wall") || f.contains("outer_wall") {
            return UIColor(red: 0.95, green: 0.55, blue: 0.15, alpha: 1)
        }
        if f.contains("inner wall") || f.contains("inner_wall") {
            return UIColor(red: 0.95, green: 0.85, blue: 0.20, alpha: 1)
        }
        if f.contains("top") {
            return UIColor(red: 0.55, green: 0.35, blue: 0.85, alpha: 1)
        }
        if f.contains("bottom") {
            return UIColor(red: 0.30, green: 0.55, blue: 0.95, alpha: 1)
        }
        if f.contains("sparse") || f.contains("internal") || f.contains("infill") {
            return UIColor(red: 0.25, green: 0.75, blue: 0.55, alpha: 1)
        }
        if f.contains("support") {
            return UIColor(red: 0.55, green: 0.55, blue: 0.60, alpha: 1)
        }
        if f.contains("skirt") || f.contains("brim") {
            return UIColor(red: 0.70, green: 0.70, blue: 0.75, alpha: 1)
        }
        if f.contains("bridge") {
            return UIColor(red: 0.20, green: 0.75, blue: 0.85, alpha: 1)
        }
        return UIColor(red: 0, green: 150 / 255, blue: 136 / 255, alpha: 1)
    }

    /// Parent "content" applies Z-up → Y-up; do not rotate this node.
    func makeNode(color: UIColor) -> SCNNode {
        let root = SCNNode()
        root.name = "gcode"
        for seg in segments {
            guard seg.points.count > 1 else { continue }
            let src = SCNGeometrySource(vertices: seg.points)
            var indices: [Int32] = []
            for i in 0..<(seg.points.count - 1) {
                indices.append(Int32(i))
                indices.append(Int32(i + 1))
            }
            let data = Data(bytes: indices, count: indices.count * MemoryLayout<Int32>.size)
            let elem = SCNGeometryElement(
                data: data,
                primitiveType: .line,
                primitiveCount: indices.count / 2,
                bytesPerIndex: MemoryLayout<Int32>.size
            )
            let geo = SCNGeometry(sources: [src], elements: [elem])
            let mat = SCNMaterial()
            mat.diffuse.contents = Self.color(for: seg.feature)
            mat.lightingModel = .constant
            geo.materials = [mat]
            root.addChildNode(SCNNode(geometry: geo))
        }
        return root
    }
}
