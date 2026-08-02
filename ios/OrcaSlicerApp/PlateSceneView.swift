// SceneKit prepare view: real mesh from libslic3r + orbit / pan / zoom.

import SwiftUI
import SceneKit
import UIKit

/// Interactive build plate with official-engine mesh geometry + optional G-code paths.
struct PlateSceneView: UIViewRepresentable {
    var mesh: MeshGeometry?
    var gcodeNode: SCNNode? = nil
    var showGCode: Bool = false
    var bedSize: SIMD2<Float> = SIMD2(220, 220)
    var accent: UIColor = UIColor(red: 0, green: 150 / 255, blue: 136 / 255, alpha: 1)

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = makeScene()
        view.backgroundColor = UIColor(red: 0x2D / 255, green: 0x2D / 255, blue: 0x31 / 255, alpha: 1)
        view.allowsCameraControl = true // orbit / pan / zoom (built-in)
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling4X
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.inertiaEnabled = true
        view.defaultCameraController.maximumVerticalAngle = 89
        view.defaultCameraController.minimumVerticalAngle = 5
        view.pointOfView = view.scene?.rootNode.childNode(withName: "camera", recursively: false)
        context.coordinator.view = view
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        guard let scene = view.scene else { return }

        // Mesh model
        let meshKey = mesh.map { "\($0.vertexCount)-\($0.indices.count)" } ?? "nil"
        if context.coordinator.lastMeshKey != meshKey {
            scene.rootNode.childNode(withName: "model", recursively: false)?.removeFromParentNode()
            if let mesh {
                let node = mesh.makeNode(color: accent)
                node.name = "model"
                scene.rootNode.addChildNode(node)
                context.coordinator.frameCamera(view: view, mesh: mesh, bedSize: bedSize)
            }
            context.coordinator.lastMeshKey = meshKey
        }

        // G-code toolpaths (Preview tab)
        scene.rootNode.childNode(withName: "gcode", recursively: false)?.removeFromParentNode()
        if showGCode, let gcodeNode {
            // Clone so SceneKit owns a copy (source node may be re-used)
            let clone = gcodeNode.clone()
            clone.name = "gcode"
            scene.rootNode.addChildNode(clone)
            // Dim solid mesh when previewing paths
            scene.rootNode.childNode(withName: "model", recursively: false)?.opacity = 0.18
        } else {
            scene.rootNode.childNode(withName: "model", recursively: false)?.opacity = 1.0
        }

        // Bed size change
        if context.coordinator.lastBed.x != bedSize.x || context.coordinator.lastBed.y != bedSize.y {
            scene.rootNode.childNode(withName: "bed", recursively: false)?.removeFromParentNode()
            let bed = makeBedNode(size: bedSize, accent: accent)
            bed.name = "bed"
            scene.rootNode.addChildNode(bed)
            context.coordinator.lastBed = bedSize
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func makeScene() -> SCNScene {
        let scene = SCNScene()

        // Ambient + key light
        let ambient = SCNNode()
        ambient.light = {
            let l = SCNLight()
            l.type = .ambient
            l.intensity = 400
            l.color = UIColor.white
            return l
        }()
        scene.rootNode.addChildNode(ambient)

        let key = SCNNode()
        key.light = {
            let l = SCNLight()
            l.type = .directional
            l.intensity = 800
            l.castsShadow = true
            return l
        }()
        key.eulerAngles = SCNVector3(-Float.pi / 3, Float.pi / 4, 0)
        scene.rootNode.addChildNode(key)

        // Build plate
        let bed = makeBedNode(size: bedSize, accent: accent)
        bed.name = "bed"
        scene.rootNode.addChildNode(bed)

        // Default camera
        let cam = SCNNode()
        cam.name = "camera"
        cam.camera = SCNCamera()
        cam.camera?.zNear = 0.1
        cam.camera?.zFar = 5000
        cam.camera?.fieldOfView = 45
        let cx = bedSize.x * 0.5
        let cy = bedSize.y * 0.5
        cam.position = SCNVector3(cx + 120, -160, 140)
        cam.look(at: SCNVector3(cx, cy, 0))
        scene.rootNode.addChildNode(cam)

        return scene
    }

    private func makeBedNode(size: SIMD2<Float>, accent: UIColor) -> SCNNode {
        let w = CGFloat(size.x)
        let h = CGFloat(size.y)
        let plane = SCNPlane(width: w, height: h)
        plane.widthSegmentCount = 1
        plane.heightSegmentCount = 1

        let mat = SCNMaterial()
        mat.diffuse.contents = UIColor(red: 0.20, green: 0.21, blue: 0.23, alpha: 1)
        mat.roughness.contents = 0.85
        mat.metalness.contents = 0.05
        mat.isDoubleSided = true
        plane.materials = [mat]

        let node = SCNNode(geometry: plane)
        // XY bed, Z up (SceneKit default is Y-up — rotate plate to Z-up)
        node.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
        node.position = SCNVector3(size.x * 0.5, size.y * 0.5, 0)

        // Grid lines as child
        let grid = makeGridNode(size: size, accent: accent)
        node.addChildNode(grid)

        // Orange/teal rim
        let rim = SCNPlane(width: w + 1.2, height: h + 1.2)
        let rimMat = SCNMaterial()
        rimMat.diffuse.contents = accent.withAlphaComponent(0.35)
        rimMat.isDoubleSided = true
        rim.materials = [rimMat]
        let rimNode = SCNNode(geometry: rim)
        rimNode.position = SCNVector3(0, 0, -0.05)
        node.addChildNode(rimNode)

        return node
    }

    private func makeGridNode(size: SIMD2<Float>, accent: UIColor) -> SCNNode {
        let parent = SCNNode()
        let step: Float = 10
        var verts: [SCNVector3] = []
        let x0: Float = -size.x * 0.5
        let y0: Float = -size.y * 0.5
        let x1 = x0 + size.x
        let y1 = y0 + size.y
        var x = x0
        while x <= x1 + 0.01 {
            verts.append(SCNVector3(x, y0, 0.02))
            verts.append(SCNVector3(x, y1, 0.02))
            x += step
        }
        var y = y0
        while y <= y1 + 0.01 {
            verts.append(SCNVector3(x0, y, 0.02))
            verts.append(SCNVector3(x1, y, 0.02))
            y += step
        }
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
        mat.diffuse.contents = UIColor.white.withAlphaComponent(0.18)
        mat.lightingModel = .constant
        geo.materials = [mat]
        parent.geometry = geo
        return parent
    }

    final class Coordinator {
        weak var view: SCNView?
        var lastMeshKey: String = ""
        var lastBed: SIMD2<Float> = SIMD2(0, 0)

        func frameCamera(view: SCNView, mesh: MeshGeometry, bedSize: SIMD2<Float>) {
            guard let cam = view.scene?.rootNode.childNode(withName: "camera", recursively: false) else { return }
            // Mesh node is rotated -90° around X (slic3r Z-up → SceneKit Y-up):
            // (x,y,z)_slic3r → (x, z, -y)_scenekit
            let mx = (mesh.min.x + mesh.max.x) * 0.5
            let my = (mesh.min.y + mesh.max.y) * 0.5
            let mz = (mesh.min.z + mesh.max.z) * 0.5
            let target = SCNVector3(mx, mz, -my)
            let meshExt = max(mesh.max.x - mesh.min.x, mesh.max.y - mesh.min.y, mesh.max.z - mesh.min.z, 10)
            // Frame model tightly enough to see a 20mm cube, still leave bed context
            let dist = max(meshExt * 4.5, 80)
            cam.position = SCNVector3(
                mx + dist * 0.65,
                mz + dist * 0.55,
                -my + dist * 0.9
            )
            cam.look(at: target)
            view.pointOfView = cam
        }
    }
}

// MARK: - Mesh from C API

struct MeshGeometry {
    var positions: [Float] // xyz * n
    var indices: [UInt32]
    var min: SIMD3<Float>
    var max: SIMD3<Float>

    var vertexCount: Int { positions.count / 3 }

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

        // Compute smooth-ish normals per vertex (flat accumulation)
        var normals = [Float](repeating: 0, count: positions.count)
        let triCount = indices.count / 3
        for t in 0..<triCount {
            let i0 = Int(indices[t * 3])
            let i1 = Int(indices[t * 3 + 1])
            let i2 = Int(indices[t * 3 + 2])
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
            var nx: Float = normals[i * 3]
            var ny: Float = normals[i * 3 + 1]
            var nz: Float = normals[i * 3 + 2]
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
        mat.metalness.contents = 0.15
        mat.roughness.contents = 0.45
        mat.isDoubleSided = false
        geo.materials = [mat]

        let node = SCNNode(geometry: geo)
        // Engine uses Z-up; SceneKit Y-up — rotate model so Z becomes Y
        // Actually bed is rotated -Float.pi/2 so bed XY is horizontal in SceneKit.
        // Model from slic3r is Z-up with XY on bed. Apply same rotation as bed children.
        // Model positions are in world mm with Z up. Our bed plane is in XY at z=0 after
        // rotating plane from default (which faces +Z in local, after -90 X faces +Y...).
        //
        // SceneKit: Y up. Slic3r: Z up, XY bed.
        // Convert: (x, y, z)_slic3r -> (x, z, -y)_scenekit  OR rotate -90 around X:
        // R_x(-90): (x,y,z) -> (x, z, -y) wait R_x(θ): y' = y cos - z sin, z' = y sin + z cos
        // R_x(-π/2): y' = z, z' = -y  => (x, z, -y)
        node.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
        return node
    }
}

// MARK: - G-code path preview (simple extrusion moves)

struct GCodePathGeometry {
    var points: [SCNVector3] // polyline (slic3r Z-up)
    var zMin: Float = 0
    var zMax: Float = 0

    /// Full parse of extrusion moves; use `filtered(maxZ:)` for layer scrubbing.
    static func parse(url: URL, maxPoints: Int = 120_000) -> GCodePathGeometry? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var x: Float = 0, y: Float = 0, z: Float = 0
        var pts: [SCNVector3] = []
        var zMin: Float = .greatestFiniteMagnitude
        var zMax: Float = -.greatestFiniteMagnitude
        pts.reserveCapacity(min(maxPoints, 4096))
        for line in text.split(whereSeparator: \.isNewline) {
            if pts.count >= maxPoints { break }
            let s = line.trimmingCharacters(in: .whitespaces)
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
                pts.append(SCNVector3(nx, ny, nz))
                zMin = min(zMin, nz)
                zMax = max(zMax, nz)
            } else if abs(nz - z) > 0.01 {
                // layer change marker — keep sparse Z hops so segments don't jump
                pts.append(SCNVector3(nx, ny, nz))
            }
            x = nx; y = ny; z = nz
        }
        guard pts.count > 2 else { return nil }
        if zMin > zMax { zMin = 0; zMax = 0.2 }
        return GCodePathGeometry(points: pts, zMin: zMin, zMax: zMax)
    }

    /// Keep only points with Z <= maxZ (layer slider).
    func filtered(maxZ: Float) -> GCodePathGeometry {
        let f = points.filter { $0.z <= maxZ + 0.001 }
        return GCodePathGeometry(points: f, zMin: zMin, zMax: maxZ)
    }

    func makeNode(color: UIColor) -> SCNNode {
        guard points.count > 1 else { return SCNNode() }
        let src = SCNGeometrySource(vertices: points)
        var indices: [Int32] = []
        for i in 0..<(points.count - 1) {
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
        mat.diffuse.contents = color
        mat.lightingModel = .constant
        geo.materials = [mat]
        let node = SCNNode(geometry: geo)
        node.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
        node.name = "gcode"
        return node
    }
}
