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
    @Published var lastSliceTimeSec: Float = 0
    @Published var lastSliceFilamentMm3: Float = 0
    @Published var lastSliceLayers: Int = 0
    @Published var lastSliceStatsText: String = ""
    @Published var mesh: MeshGeometry?
    @Published var gcodePathNode: SCNNode?
    @Published var gcodeGeometry: GCodePathGeometry?
    @Published var objectCount: Int = 0
    @Published var objectNames: [String] = []
    @Published var selectedObjectIndex: Int = -1 // -1 = all
    @Published var boundsText: String = ""
    @Published var bedSize: SIMD2<Float> = SIMD2(220, 220)
    @Published var bedHeight: Float = 250
    /// Active bundled process profile resource name (without .json)
    @Published var activeProcessProfile: String = "process_0.20mm_Standard"
    /// Approximate solid volume from orca_session_model_info (mm³); 0 if unknown
    @Published var modelVolumeMm3: Float = 0
    /// Layer scrubber: max Z shown in Preview (mm)
    @Published var previewMaxZ: Float = 100
    @Published var gcodeZMin: Float = 0
    @Published var gcodeZMax: Float = 20

    /// Bundled process profiles shipped in app Resources
    static let bundledProcessProfiles: [(id: String, title: String)] = [
        ("process_0.20mm_Standard", "0.20 mm Standard"),
        ("process_0.16mm_Fine", "0.16 mm Fine"),
    ]

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

    /// Load first available bundled process profile (Standard preferred, then Fine).
    func loadBundledProfileIfAvailable() {
        let candidates = Self.bundledProcessProfiles.map(\.id) + [
            "0.20mm Standard",
            "0.16mm Fine",
        ]
        for name in candidates {
            if loadProcessProfile(name) {
                return
            }
        }
    }

    /// Load a bundled process JSON by resource name (no extension).
    /// Re-applies bed defaults after load because process profiles omit printable_area.
    @discardableResult
    func loadProcessProfile(_ resourceName: String) -> Bool {
        #if ORCA_LINKED
        guard let s = session else { return false }
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "json") else {
            return false
        }
        let rc = url.path.withCString { orca_session_load_config(s, $0) }
        if rc == 0 {
            // Preserve current bed if already set; otherwise apply FFF defaults including bed
            let w = bedSize.x, d = bedSize.y, h = bedHeight
            // Process profiles may wipe unrelated keys — reassert nozzle/filament + bed
            _ = setOptionRaw("filament_diameter", "1.75")
            _ = setOptionRaw("nozzle_diameter", "0.4")
            setBedSize(width: w, depth: d, height: h)
            activeProcessProfile = resourceName
            // setBedSize updates lastMessage — restore profile load status
            lastMessage = "Loaded process profile: \(resourceName)"
            return true
        } else {
            let err = orca_session_last_error(s).map { String(cString: $0) } ?? "?"
            lastMessage = "Profile \(resourceName) rc=\(rc): \(err)"
            return false
        }
        #else
        return false
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
        refreshBedSize()
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

    /// Copy security-scoped URL into temp for the C engine.
    private func copyToTemp(_ url: URL) -> URL? {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(url.lastPathComponent)
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: url, to: dest)
            return dest
        } catch {
            lastMessage = "Copy failed: \(error.localizedDescription)"
            return nil
        }
    }

    /// Load model, replacing the plate (default).
    func loadModel(url: URL) -> String {
        loadModel(url: url, append: false)
    }

    /// Add model onto the plate without clearing existing objects.
    func addModel(url: URL) -> String {
        loadModel(url: url, append: true)
    }

    func loadModel(url: URL, append: Bool) -> String {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        guard let dest = copyToTemp(url) else { return lastMessage }

        #if ORCA_LINKED
        guard let s = session else {
            lastMessage = "No session"
            return lastMessage
        }
        let rc: Int32 = dest.path.withCString { path in
            if append {
                return orca_session_add_model(s, path)
            } else {
                return orca_session_load_model(s, path)
            }
        }
        if rc != 0 {
            let err = orca_session_last_error(s).map { String(cString: $0) } ?? "error"
            lastMessage = "\(append ? "add" : "load")_model rc=\(rc): \(err)"
            if !append {
                hasModel = false
                mesh = nil
            }
            return lastMessage
        }
        modelName = append
            ? "\(objectCount + 1) objects · last \(url.lastPathComponent)"
            : url.lastPathComponent
        hasModel = true
        if !append {
            _ = orca_session_center_on_bed(s)
        } else {
            _ = orca_session_arrange(s)
        }
        refreshObjectList()
        refreshMesh()
        refreshBounds()
        refreshModelInfo()
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

    /// object count + optional volume via orca_session_model_info
    func refreshModelInfo() {
        #if ORCA_LINKED
        guard let s = session, hasModel else {
            modelVolumeMm3 = 0
            return
        }
        var count: Int32 = 0
        var vol: Float = 0
        if orca_session_model_info(s, &count, &vol) == 0 {
            objectCount = Int(count)
            modelVolumeMm3 = vol
        } else {
            modelVolumeMm3 = 0
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
            refreshMesh(); refreshBounds(); refreshModelInfo()
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
            refreshMesh(); refreshBounds(); refreshModelInfo()
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
            refreshMesh(); refreshBounds(); refreshModelInfo()
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
            refreshMesh(); refreshBounds(); refreshModelInfo()
            lastMessage = "Centered on bed"
        }
        #endif
    }

    func arrange() {
        #if ORCA_LINKED
        guard let s = session, hasModel else { return }
        if orca_session_arrange(s) == 0 {
            refreshMesh(); refreshBounds(); refreshModelInfo()
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
            refreshMesh(); refreshBounds(); refreshModelInfo()
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
                modelVolumeMm3 = 0
                lastMessage = "Plate empty"
            } else {
                refreshObjectList()
                refreshMesh(); refreshBounds(); refreshModelInfo()
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
        modelVolumeMm3 = 0
        gcodeURL = nil
        gcodePathNode = nil
        gcodeGeometry = nil
        lastMessage = "Plate cleared"
        #endif
    }

    /// Common bed sizes (mm) — prefers orca_session_set_printable_area, falls back to options
    func setBedSize(width: Float, depth: Float, height: Float = 250) {
        #if ORCA_LINKED
        guard let s = session else { return }
        let rc = orca_session_set_printable_area(s, width, depth, height)
        if rc != 0 {
            // Fallback for older engine binaries without set_printable_area
            let area = String(format: "0x0,%.0fx0,%.0fx%.0f,0x%.0f", width, width, depth, depth)
            _ = setOptionRaw("printable_area", area)
            _ = setOptionRaw("printable_height", String(format: "%.0f", height))
        }
        refreshBedSize()
        lastMessage = String(
            format: "Bed %.0f×%.0f×%.0f mm",
            bedSize.x, bedSize.y, bedHeight
        )
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
        // OpaquePointer is not Sendable; pass as bitPattern across Task.detached (Swift 6).
        let sessionBits = UInt(bitPattern: s)
        let outPath = out.path
        let rc = await Task.detached {
            let sess = OpaquePointer(bitPattern: sessionBits)!
            return outPath.withCString { orca_session_slice_to_gcode(sess, $0) }
        }.value
        if rc != 0 {
            let err = orca_session_last_error(s).map { String(cString: $0) } ?? "slice failed"
            return "slice rc=\(rc): \(err)"
        }
        await MainActor.run { [sessionBits] in
            let sess = OpaquePointer(bitPattern: sessionBits)!
            self.gcodeURL = out
            self.slicePercent = 100
            self.slicePhase = "Done"
            var t: Float = 0, fil: Float = 0
            var layers: Int32 = 0
            if orca_session_last_slice_stats(sess, &t, &fil, &layers) == 0 {
                self.lastSliceTimeSec = t
                self.lastSliceFilamentMm3 = fil
                self.lastSliceLayers = Int(layers)
                let mins = Int(t) / 60
                let secs = Int(t) % 60
                let grams = fil * 0.00124 // approx PLA density g/mm³
                self.lastSliceStatsText = String(
                    format: "~%dm %02ds · %.1f g filament · %d layers",
                    mins, secs, grams, Int(layers)
                )
            } else {
                self.lastSliceStatsText = ""
            }
            if let path = GCodePathGeometry.parse(url: out) {
                self.gcodeGeometry = path
                self.gcodeZMin = path.zMin
                self.gcodeZMax = max(path.zMax, path.zMin + 0.2)
                self.previewMaxZ = self.gcodeZMax
                self.applyPreviewLayer()
            }
        }
        let stats = await MainActor.run { self.lastSliceStatsText }
        if stats.isEmpty {
            return "G-code written: \(out.lastPathComponent) (Print::export_gcode)"
        }
        return "Sliced \(out.lastPathComponent) · \(stats)"
        #else
        return "Link orca_ios_api + libslic3r to slice"
        #endif
    }

    /// Save plate + config as 3MF via official store_3mf.
    func saveProject3MF() -> URL? {
        #if ORCA_LINKED
        guard let s = session, hasModel else {
            lastMessage = "Nothing to save"
            return nil
        }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("orcaslicer_project.3mf")
        let rc = out.path.withCString { orca_session_save_3mf(s, $0) }
        if rc != 0 {
            lastMessage = orca_session_last_error(s).map { String(cString: $0) } ?? "save_3mf failed"
            return nil
        }
        lastMessage = "Saved \(out.lastPathComponent)"
        return out
        #else
        lastMessage = "Not linked"
        return nil
        #endif
    }
}
