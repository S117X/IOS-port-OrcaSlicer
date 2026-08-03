// Bridges SwiftUI to official orca_ios_api (libslic3r).

import Foundation
import Combine
import SceneKit
#if canImport(UIKit)
import UIKit
#endif

/// Thin ObservableObject around C ABI in `src/ios/orca_slice_c_api.h`.
final class OrcaEngine: ObservableObject {
    @Published var modelName: String?
    @Published var hasModel = false
    @Published var gcodeURL: URL?
    @Published var lastMessage = ""
    @Published var mesh: MeshGeometry?
    @Published var gcodePathNode: SCNNode?
    @Published var gcodeGeometry: GCodePathGeometry?
    @Published var objectCount: Int = 0
    @Published var objectNames: [String] = []
    @Published var selectedObjectIndex: Int = -1 // -1 = all
    @Published var boundsText: String = ""
    @Published var bedSize: SIMD2<Float> = SIMD2(220, 220)
    @Published var bedHeight: Float = 250
    /// Layer scrubber: max Z shown in Preview (mm)
    @Published var previewMaxZ: Float = 100
    @Published var gcodeZMin: Float = 0
    @Published var gcodeZMax: Float = 20

    private var session: OpaquePointer?

    var version: String {
        #if ORCA_LINKED
        if let c = orca_version_string() {
            return String(cString: c)
        }
        #endif
        return "OrcaSlicer host (engine not linked)"
    }

    var isLinked: Bool {
        #if ORCA_LINKED
        return session != nil
        #else
        return false
        #endif
    }

    init() {
        #if ORCA_LINKED
        let res = Bundle.main.resourcePath
        session = orca_session_create(res)
        if session == nil {
            lastMessage = "orca_session_create failed"
        } else {
            lastMessage = "Engine ready (official libslic3r)"
            applyDefaultFFF()
            // Prefer bundled profile if present
            loadBundledProfileIfAvailable()
        }
        #else
        lastMessage = "Build with ORCA_LINKED + liborca_engine.a"
        #endif
    }

    deinit {
        #if ORCA_LINKED
        if let s = session { orca_session_destroy(s) }
        #endif
    }

    #if ORCA_LINKED
    @discardableResult
    private func setOptionRaw(_ key: String, _ value: String) -> Int32 {
        guard let s = session else { return -1 }
        return key.withCString { k in
            value.withCString { v in
                orca_session_set_option(s, k, v)
            }
        }
    }
    #endif

    private func applyDefaultFFF() {
        #if ORCA_LINKED
        _ = setOptionRaw("layer_height", "0.2")
        _ = setOptionRaw("wall_loops", "2")
        _ = setOptionRaw("sparse_infill_density", "15%")
        _ = setOptionRaw("filament_diameter", "1.75")
        _ = setOptionRaw("nozzle_diameter", "0.4")
        _ = setOptionRaw("printable_area", "0x0,220x0,220x220,0x220")
        _ = setOptionRaw("printable_height", "250")
        bedSize = SIMD2(220, 220)
        bedHeight = 250
        refreshBedSize()
        #endif
    }

    func refreshBedSize() {
        #if ORCA_LINKED
        guard let s = session else { return }
        var w: Float = 220, d: Float = 220, h: Float = 250
        if orca_session_bed_size(s, &w, &d, &h) == 0 {
            bedSize = SIMD2(w, d)
            bedHeight = h
        }
        #endif
    }

    func refreshObjectList() {
        #if ORCA_LINKED
        guard let s = session, hasModel else {
            objectNames = []
            objectCount = 0
            return
        }
        let n = Int(orca_session_object_count(s))
        objectCount = n
        var names: [String] = []
        for i in 0..<n {
            if let c = orca_session_object_name(s, Int32(i)) {
                let name = String(cString: c)
                names.append(name.isEmpty ? "Object \(i + 1)" : name)
            } else {
                names.append("Object \(i + 1)")
            }
        }
        objectNames = names
        if selectedObjectIndex >= n {
            selectedObjectIndex = n > 0 ? 0 : -1
        }
        #endif
    }

    /// Load bundled process JSON from app (process_0.20mm_Standard.json)
    func loadBundledProfileIfAvailable() {
        #if ORCA_LINKED
        guard let s = session else { return }
        let candidates = [
            "process_0.20mm_Standard",
            "0.20mm Standard",
        ]
        for name in candidates {
            if let url = Bundle.main.url(forResource: name, withExtension: "json") {
                let rc = url.path.withCString { orca_session_load_config(s, $0) }
                if rc == 0 {
                    lastMessage = "Loaded process profile: \(name)"
                    // Re-apply bed size after profile (profiles may omit printable_area)
                    applyDefaultFFF()
                    lastMessage = "Loaded process profile: \(name)"
                    return
                } else {
                    let err = orca_session_last_error(s).map { String(cString: $0) } ?? "?"
                    lastMessage = "Profile \(name) rc=\(rc): \(err)"
                }
            }
        }
        #endif
    }

    func loadConfig(url: URL) -> String {
        #if ORCA_LINKED
        guard let s = session else { return "No session" }
        let rc = url.path.withCString { orca_session_load_config(s, $0) }
        if rc != 0 {
            let err = orca_session_last_error(s).map { String(cString: $0) } ?? "error"
            lastMessage = "load_config rc=\(rc): \(err)"
            return lastMessage
        }
        lastMessage = "Loaded config \(url.lastPathComponent)"
        return lastMessage
        #else
        return "Not linked"
        #endif
    }

    func loadBundledSampleCube() -> String {
        if let url = Bundle.main.url(forResource: "sample_cube_20mm", withExtension: "stl") {
            return loadModel(url: url)
        }
        lastMessage = "sample_cube_20mm.stl not in bundle"
        return lastMessage
    }

    func loadModel(url: URL) -> String {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(url.lastPathComponent)
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: url, to: dest)
        } catch {
            lastMessage = "Copy failed: \(error.localizedDescription)"
            return lastMessage
        }

        #if ORCA_LINKED
        guard let s = session else {
            lastMessage = "No session"
            return lastMessage
        }
        let rc = dest.path.withCString { orca_session_load_model(s, $0) }
        if rc != 0 {
            let err = orca_session_last_error(s).map { String(cString: $0) } ?? "error"
            lastMessage = "load_model rc=\(rc): \(err)"
            hasModel = false
            mesh = nil
            return lastMessage
        }
        modelName = url.lastPathComponent
        hasModel = true
        // Center on bed so cube appears on the plate grid
        _ = orca_session_center_on_bed(s)
        refreshObjectList()
        refreshMesh()
        refreshBounds()
        refreshBedSize()
        gcodeURL = nil
        gcodePathNode = nil
        gcodeGeometry = nil
        lastMessage = "Loaded \(url.lastPathComponent) · \(objectCount) object(s) · mesh ready"
        return lastMessage
        #else
        modelName = url.lastPathComponent + " (engine not linked)"
        hasModel = false
        lastMessage = "Engine not linked"
        return lastMessage
        #endif
    }

    /// Rebuild G-code SceneKit node from geometry filtered by previewMaxZ
    func applyPreviewLayer() {
        guard let geo = gcodeGeometry else {
            gcodePathNode = nil
            return
        }
        let filtered = geo.filtered(maxZ: previewMaxZ)
        #if canImport(UIKit)
        gcodePathNode = filtered.makeNode(
            color: UIColor(red: 0, green: 150 / 255, blue: 136 / 255, alpha: 1)
        )
        #endif
    }

    func refreshMesh() {
        #if ORCA_LINKED
        guard let s = session, hasModel else {
            mesh = nil
            return
        }
        var posPtr: UnsafeMutablePointer<Float>?
        var idxPtr: UnsafeMutablePointer<UInt32>?
        var vcount: Int = 0
        var icount: Int = 0
        let rc = orca_session_export_mesh(s, &posPtr, &vcount, &idxPtr, &icount)
        defer {
            if let p = posPtr { orca_free(p) }
            if let i = idxPtr { orca_free(i) }
        }
        guard rc == 0, let posPtr, let idxPtr, vcount > 0, icount > 0 else {
            mesh = nil
            return
        }
        let positions = Array(UnsafeBufferPointer(start: posPtr, count: vcount * 3))
        let indices = Array(UnsafeBufferPointer(start: idxPtr, count: icount))
        var bmin = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var bmax = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for i in 0..<vcount {
            let p = SIMD3(positions[i * 3], positions[i * 3 + 1], positions[i * 3 + 2])
            bmin = min(bmin, p)
            bmax = max(bmax, p)
        }
        mesh = MeshGeometry(positions: positions, indices: indices, min: bmin, max: bmax)
        #endif
    }

    func refreshBounds() {
        #if ORCA_LINKED
        guard let s = session, hasModel else {
            boundsText = ""
            return
        }
        var minx: Float = 0, miny: Float = 0, minz: Float = 0
        var maxx: Float = 0, maxy: Float = 0, maxz: Float = 0
        if orca_session_model_bounds(s, &minx, &miny, &minz, &maxx, &maxy, &maxz) == 0 {
            boundsText = String(
                format: "BB %.1f×%.1f×%.1f mm",
                maxx - minx, maxy - miny, maxz - minz
            )
        }
        #endif
    }

    func setOption(_ key: String, value: String) {
        #if ORCA_LINKED
        guard let s = session else { return }
        let rc = key.withCString { k in
            value.withCString { v in
                orca_session_set_option(s, k, v)
            }
        }
        lastMessage = rc == 0
            ? "set \(key)=\(value)"
            : (orca_session_last_error(s).map { String(cString: $0) } ?? "set failed")
        #else
        lastMessage = "Not linked"
        #endif
    }

    /// Uses selectedObjectIndex when index omitted (-1 = all, or selection)
    private var transformIndex: Int32 {
        Int32(selectedObjectIndex)
    }

    /// index -1 = all objects; default uses selectedObjectIndex
    func translate(dx: Float, dy: Float, dz: Float = 0, index: Int? = nil) {
        #if ORCA_LINKED
        guard let s = session, hasModel else { return }
        let idx = Int32(index ?? selectedObjectIndex)
        let rc = orca_session_translate_object(s, idx, dx, dy, dz)
        if rc == 0 {
            refreshMesh(); refreshBounds()
            lastMessage = String(format: "Moved Δ(%.1f, %.1f, %.1f) mm", dx, dy, dz)
        } else {
            lastMessage = orca_session_last_error(s).map { String(cString: $0) } ?? "translate failed"
        }
        #endif
    }

    func rotateZ(degrees: Float, index: Int? = nil) {
        #if ORCA_LINKED
        guard let s = session, hasModel else { return }
        let idx = Int32(index ?? selectedObjectIndex)
        let rc = orca_session_rotate_object_z(s, idx, degrees)
        if rc == 0 {
            refreshMesh(); refreshBounds()
            lastMessage = String(format: "Rotated Z %.0f°", degrees)
        } else {
            lastMessage = orca_session_last_error(s).map { String(cString: $0) } ?? "rotate failed"
        }
        #endif
    }

    func scale(factor: Float, index: Int? = nil) {
        #if ORCA_LINKED
        guard let s = session, hasModel else { return }
        let idx = Int32(index ?? selectedObjectIndex)
        let rc = orca_session_scale_object(s, idx, factor)
        if rc == 0 {
            refreshMesh(); refreshBounds()
            lastMessage = String(format: "Scaled ×%.2f", factor)
        } else {
            lastMessage = orca_session_last_error(s).map { String(cString: $0) } ?? "scale failed"
        }
        #endif
    }

    func centerOnBed() {
        #if ORCA_LINKED
        guard let s = session, hasModel else { return }
        if orca_session_center_on_bed(s) == 0 {
            refreshMesh(); refreshBounds()
            lastMessage = "Centered on bed"
        }
        #endif
    }

    func arrange() {
        #if ORCA_LINKED
        guard let s = session, hasModel else { return }
        if orca_session_arrange(s) == 0 {
            refreshMesh(); refreshBounds()
            lastMessage = "Arranged objects on plate"
        } else {
            lastMessage = orca_session_last_error(s).map { String(cString: $0) } ?? "arrange failed"
        }
        #endif
    }

    func duplicateSelected() {
        #if ORCA_LINKED
        guard let s = session, hasModel else { return }
        let idx = selectedObjectIndex >= 0 ? selectedObjectIndex : 0
        let rc = orca_session_duplicate_object(s, Int32(idx))
        if rc >= 0 {
            hasModel = true
            refreshObjectList()
            selectedObjectIndex = Int(rc)
            refreshMesh(); refreshBounds()
            lastMessage = "Duplicated object → index \(rc)"
        } else {
            lastMessage = orca_session_last_error(s).map { String(cString: $0) } ?? "duplicate failed"
        }
        #endif
    }

    func deleteSelected() {
        #if ORCA_LINKED
        guard let s = session, hasModel else { return }
        let idx = selectedObjectIndex >= 0 ? selectedObjectIndex : 0
        let rc = orca_session_delete_object(s, Int32(idx))
        if rc == 0 {
            let n = Int(orca_session_object_count(s))
            hasModel = n > 0
            if !hasModel {
                mesh = nil
                modelName = nil
                objectNames = []
                objectCount = 0
                lastMessage = "Plate empty"
            } else {
                refreshObjectList()
                refreshMesh(); refreshBounds()
                lastMessage = "Deleted object \(idx)"
            }
        } else {
            lastMessage = orca_session_last_error(s).map { String(cString: $0) } ?? "delete failed"
        }
        #endif
    }

    func clearPlate() {
        #if ORCA_LINKED
        guard let s = session else { return }
        _ = orca_session_clear_model(s)
        hasModel = false
        mesh = nil
        modelName = nil
        objectNames = []
        objectCount = 0
        gcodeURL = nil
        gcodePathNode = nil
        gcodeGeometry = nil
        lastMessage = "Plate cleared"
        #endif
    }

    /// Common bed sizes (mm) — updates printable_area + printable_height
    func setBedSize(width: Float, depth: Float, height: Float = 250) {
        #if ORCA_LINKED
        let area = String(format: "0x0,%.0fx0,%.0fx%.0f,0x%.0f", width, width, depth, depth)
        _ = setOptionRaw("printable_area", area)
        _ = setOptionRaw("printable_height", String(format: "%.0f", height))
        bedSize = SIMD2(width, depth)
        bedHeight = height
        lastMessage = String(format: "Bed %.0f×%.0f×%.0f mm", width, depth, height)
        #endif
    }

    func getOption(_ key: String) -> String? {
        #if ORCA_LINKED
        guard let s = session else { return nil }
        var buf = [CChar](repeating: 0, count: 512)
        let rc = key.withCString { k in
            orca_session_get_option(s, k, &buf, buf.count)
        }
        guard rc == 0 else { return nil }
        return String(cString: buf)
        #else
        return nil
        #endif
    }

    @Published var slicePercent: Int = 0
    @Published var slicePhase: String = ""

    func slice() async -> String {
        #if ORCA_LINKED
        guard let s = session else { return "No session" }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("plate_1.gcode")
        await MainActor.run {
            self.slicePercent = 0
            self.slicePhase = "Starting"
        }
        // Progress bridge: C callback → main-thread published fields
        final class ProgressBox: @unchecked Sendable {
            weak var engine: OrcaEngine?
            init(_ e: OrcaEngine) { engine = e }
        }
        let box = ProgressBox(self)
        let boxPtr = Unmanaged.passRetained(box).toOpaque()
        orca_session_set_progress_callback(s, { pct, msg, user in
            guard let user else { return }
            let b = Unmanaged<ProgressBox>.fromOpaque(user).takeUnretainedValue()
            let phase = msg.map { String(cString: $0) } ?? ""
            DispatchQueue.main.async {
                b.engine?.slicePercent = Int(pct)
                b.engine?.slicePhase = phase
            }
        }, boxPtr)
        defer {
            orca_session_set_progress_callback(s, nil, nil)
            Unmanaged<ProgressBox>.fromOpaque(boxPtr).release()
        }
        let rc = await Task.detached {
            out.path.withCString { orca_session_slice_to_gcode(s, $0) }
        }.value
        if rc != 0 {
            let err = orca_session_last_error(s).map { String(cString: $0) } ?? "slice failed"
            return "slice rc=\(rc): \(err)"
        }
        await MainActor.run {
            self.gcodeURL = out
            self.slicePercent = 100
            self.slicePhase = "Done"
            if let path = GCodePathGeometry.parse(url: out) {
                self.gcodeGeometry = path
                self.gcodeZMin = path.zMin
                self.gcodeZMax = max(path.zMax, path.zMin + 0.2)
                self.previewMaxZ = self.gcodeZMax
                self.applyPreviewLayer()
            }
        }
        return "G-code written: \(out.lastPathComponent) (Print::export_gcode)"
        #else
        return "Link orca_ios_api + libslic3r to slice"
        #endif
    }
}
