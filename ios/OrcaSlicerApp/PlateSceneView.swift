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
    /// Prepare tab: pan on bed plane moves selected object(s) in mm (slic3r XY).
    var moveMode: Bool = false
    /// Measure gizmo: tap places points in slic3r XYZ (mm).
    var measureMode: Bool = false
    /// Paint gizmo: tap/drag paints facets via libslic3r FacetsAnnotation.
    var paintMode: Bool = false
    /// Painted facet overlay mesh (world slic3r coords)
    var paintOverlay: MeshGeometry? = nil
    /// Overlay color for current paint kind
    var paintOverlayColor: UIColor = UIColor(red: 0.2, green: 0.85, blue: 0.35, alpha: 0.85)
    /// Called with total Δx, Δy mm when a drag ends (official translate_object).
    var onDragCommit: ((Float, Float) -> Void)? = nil
    /// Live visual feedback during drag (optional status text).
    var onDragLive: ((Float, Float) -> Void)? = nil
    /// Measure tap in slic3r coordinates (x,y,z mm).
    var onMeasurePick: ((SIMD3<Float>) -> Void)? = nil
    /// Paint hit in slic3r XYZ mm (first stroke of a gesture sets recordUndo via parent).
    var onPaintHit: ((SIMD3<Float>, Bool /*isBegin*/) -> Void)? = nil

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
        context.coordinator.parent = self
        context.coordinator.lastBed = bedSize
        context.coordinator.lastTexture = bedTexturePath ?? ""
        context.coordinator.installGestures(on: view)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.parent = self
        guard let scene = view.scene,
              let content = scene.rootNode.childNode(withName: "content", recursively: false)
        else { return }

        // Move / measure / paint: disable orbit so gestures own the surface
        let wantCamera = !moveMode && !measureMode && !paintMode && !context.coordinator.isDragging
        if view.allowsCameraControl != wantCamera {
            view.allowsCameraControl = wantCamera
        }
        context.coordinator.panGesture?.isEnabled = moveMode || paintMode
        context.coordinator.tapGesture?.isEnabled = measureMode || paintMode

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

        // Mesh model — skip rebuild while dragging (node is offset live)
        let meshKey = mesh.map { "\($0.vertexCount)-\($0.indices.count)-\($0.min.x)-\($0.max.x)-\($0.min.y)-\($0.max.y)" } ?? "nil"
        if !context.coordinator.isDragging, context.coordinator.lastMeshKey != meshKey {
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
            context.coordinator.visualOffset = .zero
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

        // Paint overlay (support/seam/mmu/fuzzy facets)
        content.childNode(withName: "paintOverlay", recursively: false)?.removeFromParentNode()
        if let paintOverlay, paintOverlay.vertexCount > 0 {
            let node = paintOverlay.makeNode(color: paintOverlayColor)
            node.name = "paintOverlay"
            // Slight inflate so painted faces sit above base mesh
            node.renderingOrder = 10
            if let mats = node.geometry?.materials {
                for m in mats {
                    m.writesToDepthBuffer = false
                    m.transparencyMode = .singleLayer
                }
            }
            content.addChildNode(node)
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

    final class Coordinator: NSObject {
        weak var view: SCNView?
        var parent: PlateSceneView?
        var lastMeshKey: String = ""
        var lastBed: SIMD2<Float> = SIMD2(0, 0)
        var lastTexture: String = ""
        var panGesture: UIPanGestureRecognizer?
        var tapGesture: UITapGestureRecognizer?
        var isDragging = false
        /// Accumulated visual offset in slic3r XY mm applied to model node while dragging
        var visualOffset: SIMD2<Float> = .zero
        private var dragStartBedXY: SIMD2<Float>?
        private var lastBedXY: SIMD2<Float>?
        private var paintStrokeActive = false
        private var lastPaintScreen: CGPoint?

        func installGestures(on view: SCNView) {
            if panGesture == nil {
                let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
                pan.maximumNumberOfTouches = 1
                pan.isEnabled = false
                view.addGestureRecognizer(pan)
                panGesture = pan
            }
            if tapGesture == nil {
                let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
                tap.isEnabled = false
                view.addGestureRecognizer(tap)
                tapGesture = tap
            }
        }

        /// SceneKit world → slic3r XYZ under content R_x(-90°)
        private func slic3rFromWorld(_ w: SCNVector3) -> SIMD3<Float> {
            SIMD3<Float>(w.x, -w.z, w.y)
        }

        private func hitModelSlic3r(view: SCNView, screen: CGPoint) -> SIMD3<Float>? {
            let hits = view.hitTest(screen, options: [
                SCNHitTestOption.searchMode: SCNHitTestSearchMode.all.rawValue
            ])
            if let h = hits.first(where: {
                let n = $0.node.name
                let p = $0.node.parent?.name
                return n == "model" || p == "model" || n == "paintOverlay" || p == "paintOverlay"
            }) {
                return slic3rFromWorld(h.worldCoordinates)
            }
            return nil
        }

        @objc private func handleTap(_ gr: UITapGestureRecognizer) {
            guard let view = view, let parent = parent else { return }
            let screen = gr.location(in: view)
            if parent.paintMode {
                if let p = hitModelSlic3r(view: view, screen: screen) {
                    parent.onPaintHit?(p, true)
                }
                return
            }
            guard parent.measureMode else { return }
            // Hit-test mesh first for true Z; fall back to bed plane Z=0
            if let p = hitModelSlic3r(view: view, screen: screen) {
                parent.onMeasurePick?(p)
                return
            }
            if let bedXY = projectToBedXY(view: view, screen: screen) {
                parent.onMeasurePick?(SIMD3(bedXY.x, bedXY.y, 0))
            }
        }

        @objc private func handlePan(_ gr: UIPanGestureRecognizer) {
            guard let view = view, let parent = parent else { return }
            let pt = gr.location(in: view)

            // Paint brush stroke
            if parent.paintMode {
                switch gr.state {
                case .began:
                    isDragging = true
                    paintStrokeActive = true
                    view.allowsCameraControl = false
                    lastPaintScreen = pt
                    if let p = hitModelSlic3r(view: view, screen: pt) {
                        parent.onPaintHit?(p, true)
                    }
                case .changed:
                    // Throttle by screen distance to avoid flooding
                    if let last = lastPaintScreen {
                        let dx = pt.x - last.x, dy = pt.y - last.y
                        if dx * dx + dy * dy < 36 { return } // ~6pt
                    }
                    lastPaintScreen = pt
                    if let p = hitModelSlic3r(view: view, screen: pt) {
                        parent.onPaintHit?(p, false)
                    }
                case .ended, .cancelled, .failed:
                    isDragging = false
                    paintStrokeActive = false
                    lastPaintScreen = nil
                    view.allowsCameraControl = false
                default:
                    break
                }
                return
            }

            guard parent.moveMode else { return }

            switch gr.state {
            case .began:
                guard let bedXY = projectToBedXY(view: view, screen: pt) else { return }
                isDragging = true
                view.allowsCameraControl = false
                dragStartBedXY = bedXY
                lastBedXY = bedXY
                visualOffset = .zero

            case .changed:
                guard let start = dragStartBedXY,
                      let bedXY = projectToBedXY(view: view, screen: pt)
                else { return }
                let total = SIMD2(bedXY.x - start.x, bedXY.y - start.y)
                visualOffset = total
                applyVisualOffset(total)
                lastBedXY = bedXY
                parent.onDragLive?(total.x, total.y)

            case .ended, .cancelled, .failed:
                let total = visualOffset
                isDragging = false
                dragStartBedXY = nil
                lastBedXY = nil
                // Reset visual offset; engine commit will rebuild mesh at new position
                applyVisualOffset(.zero)
                visualOffset = .zero
                if abs(total.x) > 0.05 || abs(total.y) > 0.05 {
                    parent.onDragCommit?(total.x, total.y)
                }
                view.allowsCameraControl = !(parent.moveMode)

            default:
                break
            }
        }

        /// Ray → world Y=0 (bed) → slic3r XY under content R_x(-90).
        private func projectToBedXY(view: SCNView, screen: CGPoint) -> SIMD2<Float>? {
            // Unproject near/far along the view ray
            let near = view.unprojectPoint(SCNVector3(Float(screen.x), Float(screen.y), 0))
            let far = view.unprojectPoint(SCNVector3(Float(screen.x), Float(screen.y), 1))
            let dx = far.x - near.x
            let dy = far.y - near.y
            let dz = far.z - near.z
            // Intersect ray with world Y = 0 (content bed after R_x(-90))
            if abs(dy) < 1e-6 { return nil }
            let t = -near.y / dy
            if t < 0 || t > 1.5 { return nil } // slightly allow beyond far
            let wx = near.x + dx * t
            let wz = near.z + dz * t
            // World (x, 0, z) ← content (x, y, 0) with content R_x(-90): (x,z,-y) ⇒ y = -z
            let slic3rX = wx
            let slic3rY = -wz
            return SIMD2(slic3rX, slic3rY)
        }

        private func applyVisualOffset(_ offset: SIMD2<Float>) {
            guard let content = view?.scene?.rootNode.childNode(withName: "content", recursively: false),
                  let model = content.childNode(withName: "model", recursively: false)
            else { return }
            // Model is in content/Z-up space; offset is slic3r XY
            model.position = SCNVector3(offset.x, offset.y, 0)
        }

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
    /// Preview color mode (feature type / height gradient / speed gradient).
    enum ColorMode: String, CaseIterable, Identifiable {
        case feature
        case height
        case speed
        var id: String { rawValue }
        var label: String {
            switch self {
            case .feature: return "Feature"
            case .height: return "Height"
            case .speed: return "Speed"
            }
        }
    }

    struct Segment {
        var points: [SCNVector3]
        var feature: String
        /// Extrusion width mm from official `;WIDTH:` comments (0 = travel / unknown)
        var width: Float
        /// Feedrate mm/min from last F word on the segment (0 if unknown)
        var feedrate: Float
    }
    var segments: [Segment]
    var zMin: Float = 0
    var zMax: Float = 0
    var feedMin: Float = 0
    var feedMax: Float = 0
    /// Default line width when WIDTH comment missing (from nozzle / line_width)
    var defaultWidth: Float = 0.45

    static func parse(url: URL, maxPoints: Int = 120_000, defaultWidth: Float = 0.45) -> GCodePathGeometry? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var x: Float = 0, y: Float = 0, z: Float = 0
        var feed: Float = 0
        var feature = "Unknown"
        var width = defaultWidth
        var segs: [Segment] = []
        var cur: [SCNVector3] = []
        var curWidth = defaultWidth
        var curFeed: Float = 0
        var zMin: Float = .greatestFiniteMagnitude
        var zMax: Float = -.greatestFiniteMagnitude
        var feedMin: Float = .greatestFiniteMagnitude
        var feedMax: Float = -.greatestFiniteMagnitude
        var total = 0

        func flush() {
            if cur.count > 1 {
                segs.append(Segment(points: cur, feature: feature, width: curWidth, feedrate: curFeed))
                if curFeed > 0 {
                    feedMin = min(feedMin, curFeed)
                    feedMax = max(feedMax, curFeed)
                }
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
            // Official Orca comment: ;WIDTH:0.45
            if s.hasPrefix(";WIDTH:") || s.hasPrefix(";WIDTH :") {
                let raw = s.drop(while: { $0 != ":" }).dropFirst()
                    .trimmingCharacters(in: .whitespaces)
                if let w = Float(raw), w > 0.05, w < 5 {
                    width = w
                    curWidth = w
                }
                continue
            }
            // ;HEIGHT: for layer height awareness (optional)
            if s.hasPrefix(";HEIGHT:") || s.hasPrefix(";HEIGHT :") {
                continue
            }
            guard s.hasPrefix("G0") || s.hasPrefix("G1") || s.hasPrefix("g0") || s.hasPrefix("g1") else { continue }
            var nx = x, ny = y, nz = z
            var hasE = false
            for token in s.split(separator: " ") {
                if token.hasPrefix("X") || token.hasPrefix("x") { nx = Float(token.dropFirst()) ?? nx }
                else if token.hasPrefix("Y") || token.hasPrefix("y") { ny = Float(token.dropFirst()) ?? ny }
                else if token.hasPrefix("Z") || token.hasPrefix("z") { nz = Float(token.dropFirst()) ?? nz }
                else if token.hasPrefix("F") || token.hasPrefix("f") {
                    if let f = Float(token.dropFirst()), f > 0 { feed = f }
                } else if token.hasPrefix("E") || token.hasPrefix("e") {
                    if let e = Float(token.dropFirst()), e > 0 { hasE = true }
                }
            }
            if hasE {
                // Extrusion → keep current ;TYPE: / ;WIDTH: / F
                if cur.isEmpty {
                    cur.append(SCNVector3(x, y, z))
                    curWidth = width
                    curFeed = feed
                }
                cur.append(SCNVector3(nx, ny, nz))
                zMin = min(zMin, nz)
                zMax = max(zMax, nz)
                total += 1
            } else {
                // Non-extrusion: record travel only if long enough (skip micro-jogs for RAM)
                let dx = nx - x, dy = ny - y, dz = nz - z
                let dist = sqrtf(dx * dx + dy * dy + dz * dz)
                if dist > 1.5 {
                    flush()
                    // Subsample travel budget: at most ~1/4 of maxPoints
                    if total < maxPoints / 4 {
                        segs.append(Segment(
                            points: [SCNVector3(x, y, z), SCNVector3(nx, ny, nz)],
                            feature: "Travel",
                            width: 0,
                            feedrate: feed
                        ))
                        zMin = min(zMin, nz, z)
                        zMax = max(zMax, nz, z)
                        total += 1
                    }
                } else if abs(dz) > 0.01 {
                    flush()
                }
            }
            x = nx; y = ny; z = nz
        }
        flush()
        guard !segs.isEmpty else { return nil }
        if zMin > zMax { zMin = 0; zMax = 0.2 }
        if feedMin > feedMax { feedMin = 0; feedMax = 1 }
        return GCodePathGeometry(
            segments: segs, zMin: zMin, zMax: zMax,
            feedMin: feedMin, feedMax: feedMax, defaultWidth: defaultWidth
        )
    }

    /// Feature group used by preview toggles (wall / infill / support / travel / other).
    enum FeatureGroup: String, CaseIterable, Identifiable {
        case wall
        case infill
        case support
        case travel
        case other
        var id: String { rawValue }
        var label: String {
            switch self {
            case .wall: return "Wall"
            case .infill: return "Infill"
            case .support: return "Support"
            case .travel: return "Travel"
            case .other: return "Other"
            }
        }
    }

    static func group(for feature: String) -> FeatureGroup {
        let f = feature.lowercased()
        if f.contains("travel") || f.contains("move") || f.contains("wipe") {
            return .travel
        }
        if f.contains("support") {
            return .support
        }
        if f.contains("wall") || f.contains("perimeter") || f.contains("external") {
            return .wall
        }
        if f.contains("infill") || f.contains("sparse") || f.contains("internal")
            || f.contains("solid") || f.contains("top") || f.contains("bottom")
            || f.contains("bridge") || f.contains("skin") {
            return .infill
        }
        if f.contains("skirt") || f.contains("brim") || f.contains("ironing") {
            return .other
        }
        return .other
    }

    func filtered(maxZ: Float, enabledGroups: Set<FeatureGroup>? = nil) -> GCodePathGeometry {
        var out: [Segment] = []
        for seg in segments {
            if let enabled = enabledGroups {
                let g = Self.group(for: seg.feature)
                if !enabled.contains(g) { continue }
            }
            let pts = seg.points.filter { $0.z <= maxZ + 0.001 }
            if pts.count > 1 {
                out.append(Segment(points: pts, feature: seg.feature, width: seg.width, feedrate: seg.feedrate))
            }
        }
        return GCodePathGeometry(
            segments: out, zMin: zMin, zMax: maxZ,
            feedMin: feedMin, feedMax: feedMax, defaultWidth: defaultWidth
        )
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
        if f.contains("travel") {
            return UIColor(red: 0.45, green: 0.45, blue: 0.50, alpha: 0.55)
        }
        return UIColor(red: 0, green: 150 / 255, blue: 136 / 255, alpha: 1)
    }

    /// Heatmap blue→cyan→green→yellow→red for t in 0…1.
    static func gradientColor(t: Float, alpha: CGFloat = 1) -> UIColor {
        let x = max(0, min(1, CGFloat(t)))
        let r: CGFloat, g: CGFloat, b: CGFloat
        if x < 0.25 {
            let u = x / 0.25
            r = 0.15; g = 0.35 + 0.45 * u; b = 0.95
        } else if x < 0.5 {
            let u = (x - 0.25) / 0.25
            r = 0.15 + 0.1 * u; g = 0.80; b = 0.95 - 0.55 * u
        } else if x < 0.75 {
            let u = (x - 0.5) / 0.25
            r = 0.25 + 0.70 * u; g = 0.80; b = 0.40 - 0.25 * u
        } else {
            let u = (x - 0.75) / 0.25
            r = 0.95; g = 0.80 - 0.55 * u; b = 0.15
        }
        return UIColor(red: r, green: g, blue: b, alpha: alpha)
    }

    func color(for seg: Segment, mode: ColorMode) -> UIColor {
        switch mode {
        case .feature:
            return Self.color(for: seg.feature)
        case .height:
            let midZ: Float
            if let first = seg.points.first, let last = seg.points.last {
                midZ = (first.z + last.z) * 0.5
            } else {
                midZ = zMin
            }
            let span = max(0.001, zMax - zMin)
            let t = (midZ - zMin) / span
            return Self.gradientColor(t: t)
        case .speed:
            let span = max(1, feedMax - feedMin)
            let t = seg.feedrate > 0 ? (seg.feedrate - feedMin) / span : 0
            return Self.gradientColor(t: t)
        }
    }

    /// Parent "content" applies Z-up → Y-up; do not rotate this node.
    /// Extrusions: ribbon quads at official `;WIDTH:` (fallback defaultWidth).
    /// Travel: thin line.
    func makeNode(color: UIColor, colorMode: ColorMode = .feature) -> SCNNode {
        let root = SCNNode()
        root.name = "gcode"
        for seg in segments {
            guard seg.points.count > 1 else { continue }
            let c = self.color(for: seg, mode: colorMode)
            let isTravel = Self.group(for: seg.feature) == .travel || seg.width <= 0.01
            if isTravel {
                root.addChildNode(makeLineNode(points: seg.points, color: c.withAlphaComponent(0.55)))
            } else {
                let w = seg.width > 0.05 ? seg.width : defaultWidth
                if let ribbon = makeRibbonNode(points: seg.points, width: w, color: c) {
                    root.addChildNode(ribbon)
                } else {
                    root.addChildNode(makeLineNode(points: seg.points, color: c))
                }
            }
        }
        return root
    }

    private func makeLineNode(points: [SCNVector3], color: UIColor) -> SCNNode {
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
        return SCNNode(geometry: geo)
    }

    /// Flat ribbon in XY (slic3r bed plane) extruded ±half-width perpendicular to path.
    private func makeRibbonNode(points: [SCNVector3], width: Float, color: UIColor) -> SCNNode? {
        let n = points.count
        guard n >= 2 else { return nil }
        let half = max(width, 0.12) * 0.5
        // Cap segment density for large paths
        let stride = max(1, n / 4000)
        var sampled: [SCNVector3] = []
        var i = 0
        while i < n {
            sampled.append(points[i])
            i += stride
        }
        if sampled.last.map({ $0.x != points[n - 1].x || $0.y != points[n - 1].y || $0.z != points[n - 1].z }) ?? true {
            sampled.append(points[n - 1])
        }
        let m = sampled.count
        guard m >= 2 else { return nil }

        var verts: [SCNVector3] = []
        verts.reserveCapacity(m * 2)
        for j in 0..<m {
            let p = sampled[j]
            // Tangent from neighbors
            let prev = sampled[max(0, j - 1)]
            let next = sampled[min(m - 1, j + 1)]
            var tx = next.x - prev.x
            var ty = next.y - prev.y
            let len = max(sqrtf(tx * tx + ty * ty), 1e-4)
            tx /= len; ty /= len
            // Perpendicular in XY
            let px = -ty * half
            let py = tx * half
            verts.append(SCNVector3(p.x + px, p.y + py, p.z + 0.02))
            verts.append(SCNVector3(p.x - px, p.y - py, p.z + 0.02))
        }

        var indices: [UInt32] = []
        indices.reserveCapacity((m - 1) * 6)
        for j in 0..<(m - 1) {
            let a = UInt32(j * 2)
            let b = a + 1
            let c = a + 2
            let d = a + 3
            // two triangles (double-sided via material)
            indices.append(contentsOf: [a, c, b, b, c, d])
        }

        // SCNVector3 may pack as 16 bytes on some platforms — use Float triples explicitly
        var floats: [Float] = []
        floats.reserveCapacity(verts.count * 3)
        for v in verts {
            floats.append(v.x); floats.append(v.y); floats.append(v.z)
        }
        let fData = Data(bytes: floats, count: floats.count * MemoryLayout<Float>.size)
        let src = SCNGeometrySource(
            data: fData,
            semantic: .vertex,
            vectorCount: verts.count,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<Float>.size * 3
        )
        let idxData = Data(bytes: indices, count: indices.count * MemoryLayout<UInt32>.size)
        let elem = SCNGeometryElement(
            data: idxData,
            primitiveType: .triangles,
            primitiveCount: indices.count / 3,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )
        let geo = SCNGeometry(sources: [src], elements: [elem])
        let mat = SCNMaterial()
        mat.diffuse.contents = color
        mat.lightingModel = .constant
        mat.isDoubleSided = true
        mat.writesToDepthBuffer = true
        mat.readsFromDepthBuffer = true
        geo.materials = [mat]
        return SCNNode(geometry: geo)
    }
}
