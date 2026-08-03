// Bridges SwiftUI to official orca_ios_api (libslic3r).

import Foundation
import Combine
import SceneKit
import Darwin
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
    /// Extended analysis (G15)
    @Published var lastInitialLayerTimeSec: Float = 0
    @Published var lastAvgLayerTimeSec: Float = 0
    @Published var lastSupportMm3: Float = 0
    @Published var lastWipeTowerMm3: Float = 0
    @Published var lastAvgLayerTimeText: String = ""
    /// Filament by feature/role: (name, meters, grams)
    @Published var filamentByRole: [(name: String, meters: Float, grams: Float)] = []
    @Published var mesh: MeshGeometry?
    /// Per-object meshes for plate hit-test / selection (same order as objectNames)
    @Published var objectMeshes: [MeshGeometry] = []
    @Published var gcodePathNode: SCNNode?
    @Published var gcodeGeometry: GCodePathGeometry?
    @Published var objectCount: Int = 0
    @Published var objectNames: [String] = []
    @Published var selectedObjectIndex: Int = -1 // -1 = all / none
    @Published var boundsText: String = ""
    /// Model AABB Z (mm) for cut mid-height default
    @Published var modelMinZ: Float = 0
    @Published var modelMaxZ: Float = 0
    @Published var bedSize: SIMD2<Float> = SIMD2(220, 220)
    @Published var bedHeight: Float = 250
    /// Active process profile display name (system preset or bundled JSON id)
    @Published var activeProcessProfile: String = "process_0.20mm_Standard"
    /// Approximate solid volume from orca_session_model_info (mm³); 0 if unknown
    @Published var modelVolumeMm3: Float = 0
    /// Layer scrubber: max/min Z shown in Preview (mm) — horizontal clip plane
    @Published var previewMaxZ: Float = 100
    @Published var previewMinZ: Float = 0
    @Published var gcodeZMin: Float = 0
    @Published var gcodeZMax: Float = 20
    /// Assembly explode factor (0 = collapsed layout)
    @Published var explodeFactor: Float = 0
    /// Preview feature toggles (wall / infill / support / travel / other)
    @Published var previewShowWall = true
    @Published var previewShowInfill = true
    @Published var previewShowSupport = true
    @Published var previewShowTravel = false
    @Published var previewShowOther = true
    /// Color toolpaths by feature type, height, or feedrate
    @Published var previewColorMode: GCodePathGeometry.ColorMode = .feature

    // MARK: System presets (all vendors / printers / process / filament)
    @Published var presetsLoaded = false
    @Published var presetsLoading = false
    @Published var printerNames: [String] = []
    @Published var processNames: [String] = []
    @Published var filamentNames: [String] = []
    /// Parallel to printerNames
    @Published var printerVendors: [String] = []
    @Published var selectedPrinter: String = ""
    @Published var selectedProcess: String = ""
    @Published var selectedFilament: String = ""
    /// Only list process/filament marked compatible with the selected printer
    @Published var compatibleOnly: Bool = true
    /// User-saved process preset names (also in processNames after save)
    @Published var userProcessNames: [String] = []
    /// User-saved filament preset names
    @Published var userFilamentNames: [String] = []
    /// File path to machine cover / bed texture for plate logo
    @Published var bedTexturePath: String?
    @Published var printerCoverPath: String?
    /// Active calibration mode (Slic3r::CalibMode raw int); 0 = none
    @Published var calibMode: Int = 0
    @Published var calibSummary: String = ""
    /// Last mesh health report (open edges / manifold)
    @Published var meshHealthText: String = ""
    /// Painted facet overlay (support/seam/mmu/fuzzy) for SceneKit
    @Published var paintOverlayMesh: MeshGeometry?
    /// Facets painted in last brush stroke / fill
    @Published var lastPaintCount: Int = 0
    /// Running total for active paint kind (any non-NONE)
    @Published var paintStatsText: String = ""
    /// Brim ear count for active object (W1)
    @Published var brimEarCount: Int = 0
    /// Second object index for mesh boolean (W2); -1 = auto next/prev
    @Published var booleanOtherObjectIndex: Int = -1

    private let prefsPrinterKey = "orca.lastPrinter"
    private let prefsProcessKey = "orca.lastProcess"
    private let prefsFilamentKey = "orca.lastFilament"
    private let prefsCompatKey = "orca.compatibleOnly"
    static let prefsWizardDoneKey = "orca.configWizardDone"
    static let prefsPreferredVendorsKey = "orca.preferredVendors"
    static let prefsRegionKey = "orca.region"
    static let prefsLanguageKey = "orca.language"
    static let prefsJobHistoryKey = "orca.printHostJobHistory"

    /// Print host job history entries (host + filename + date ISO8601)
    struct JobHistoryEntry: Identifiable, Codable, Equatable {
        var id: String { "\(date)|\(host)|\(filename)" }
        var host: String
        var filename: String
        var date: String // ISO8601
        var hostType: String
    }
    @Published var jobHistory: [JobHistoryEntry] = OrcaEngine.loadJobHistory()

    // MARK: Multi-plate (slot-based; each plate stores model+config as 3MF)
    @Published var plateCount: Int = 1
    @Published var currentPlateIndex: Int = 0
    /// Per-plate snapshot paths under Documents/OrcaSlicer/plates/
    private var platePaths: [URL] = []

    /// Fallback bundled process JSONs if system presets fail to load
    static let bundledProcessProfiles: [(id: String, title: String)] = [
        ("process_0.20mm_Standard", "0.20 mm Standard"),
        ("process_0.16mm_Fine", "0.16 mm Fine"),
    ]

    /// Unique vendor labels (sorted) from loaded printers
    var vendorList: [String] {
        Array(Set(printerVendors.filter { !$0.isEmpty })).sorted()
    }

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
            // Writable data dir for installed system vendor trees
            configureDataDir()
            // Kick off full system profile install+load in background
            Task { await loadAllSystemPresets() }
        }
        // Free heavy preview caches under OS memory pressure (full profile tree is large).
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleMemoryWarning()
        }
        #else
        lastMessage = "Build with ORCA_LINKED + liborca_engine.a"
        #endif
    }

    /// Drop G-code preview + settings-browser caches. Model mesh kept for prepare.
    func handleMemoryWarning() {
        #if ORCA_LINKED
        gcodePathNode = nil
        gcodeGeometry = nil
        gcodeURL = nil
        if let s = session {
            orca_session_purge_option_caches(s)
        }
        lastMessage = "Freed preview/settings caches (memory pressure)"
        #endif
    }

    /// Approximate app footprint (MB) for status after profile load.
    func reportMemoryMB() -> Double {
        #if canImport(UIKit)
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Double(info.resident_size) / (1024.0 * 1024.0)
        #else
        return 0
        #endif
    }

    #if ORCA_LINKED
    private func configureDataDir() {
        guard let s = session else { return }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        let data = (docs ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("OrcaSlicer", isDirectory: true)
        try? FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        _ = data.path.withCString { orca_session_set_data_dir(s, $0) }
    }
    #endif

    /// Install + load every vendor under Bundle/profiles via official PresetBundle.
    @MainActor
    func loadAllSystemPresets() async {
        #if ORCA_LINKED
        guard let s = session else { return }
        if presetsLoaded || presetsLoading { return }
        presetsLoading = true
        lastMessage = "Loading all system profiles…"
        let sessionBits = UInt(bitPattern: s)
        let rc = await Task.detached(priority: .userInitiated) {
            let sess = OpaquePointer(bitPattern: sessionBits)!
            return orca_session_load_all_presets(sess)
        }.value
        if rc != 0 {
            let err = orca_session_last_error(s).map { String(cString: $0) } ?? "load failed"
            lastMessage = "System profiles rc=\(rc): \(err) — using bundled process"
            presetsLoading = false
            loadBundledProfileIfAvailable()
            return
        }
        refreshPresetLists()
        presetsLoaded = orca_session_presets_loaded(s) != 0
        presetsLoading = false
        // Restore compatible-only filter preference
        if UserDefaults.standard.object(forKey: prefsCompatKey) != nil {
            compatibleOnly = UserDefaults.standard.bool(forKey: prefsCompatKey)
            setCompatibleOnly(compatibleOnly)
        }
        // Restore last selection if still present; else prefer known printers
        let savedPrinter = UserDefaults.standard.string(forKey: prefsPrinterKey) ?? ""
        var picked = false
        if !savedPrinter.isEmpty, printerNames.contains(savedPrinter) {
            picked = selectPrinter(savedPrinter)
        }
        if !picked {
            let preferred = [
                "Voron 2.4 300 0.4 nozzle",
                "Voron 2.4 250 0.4 nozzle",
                "Bambu Lab X1 Carbon 0.4 nozzle",
                "Generic Klipper Printer 0.4 nozzle",
            ]
            for name in preferred where printerNames.contains(name) {
                if selectPrinter(name) { picked = true; break }
            }
        }
        if !picked, let first = printerNames.first {
            _ = selectPrinter(first)
        }
        // Restore process/filament if still in (filtered) lists
        if let sp = UserDefaults.standard.string(forKey: prefsProcessKey),
           !sp.isEmpty, processNames.contains(sp) {
            _ = selectProcess(sp)
        }
        if let sf = UserDefaults.standard.string(forKey: prefsFilamentKey),
           !sf.isEmpty, filamentNames.contains(sf) {
            _ = selectFilament(sf)
        }
        let mem = reportMemoryMB()
        lastMessage = String(
            format: "Loaded %d printers · %d process · %d filament (compat %@) · ~%.0f MB",
            printerNames.count, processNames.count, filamentNames.count,
            compatibleOnly ? "on" : "off",
            mem
        )
        #endif
    }

    #if ORCA_LINKED
    private func refreshPresetLists() {
        guard let s = session else { return }
        let pc = Int(orca_session_printer_count(s))
        var printers: [String] = []
        var vendors: [String] = []
        printers.reserveCapacity(pc)
        vendors.reserveCapacity(pc)
        for i in 0..<pc {
            if let c = orca_session_printer_name(s, Int32(i)) {
                printers.append(String(cString: c))
            }
            if let v = orca_session_printer_vendor(s, Int32(i)) {
                vendors.append(String(cString: v))
            } else {
                vendors.append("")
            }
        }
        printerNames = printers
        printerVendors = vendors

        let prc = Int(orca_session_process_count(s))
        var procs: [String] = []
        procs.reserveCapacity(prc)
        for i in 0..<prc {
            if let c = orca_session_process_name(s, Int32(i)) {
                procs.append(String(cString: c))
            }
        }
        processNames = procs

        let fc = Int(orca_session_filament_count(s))
        var fils: [String] = []
        fils.reserveCapacity(fc)
        for i in 0..<fc {
            if let c = orca_session_filament_name(s, Int32(i)) {
                fils.append(String(cString: c))
            }
        }
        filamentNames = fils

        if let c = orca_session_selected_printer(s) {
            selectedPrinter = String(cString: c)
        }
        if let c = orca_session_selected_process(s) {
            selectedProcess = String(cString: c)
            if !selectedProcess.isEmpty { activeProcessProfile = selectedProcess }
        }
        if let c = orca_session_selected_filament(s) {
            selectedFilament = String(cString: c)
        }

        let uc = Int(orca_session_user_process_count(s))
        var users: [String] = []
        users.reserveCapacity(uc)
        for i in 0..<uc {
            if let c = orca_session_user_process_name(s, Int32(i)) {
                users.append(String(cString: c))
            }
        }
        userProcessNames = users
        let ufc = Int(orca_session_user_filament_count(s))
        var ufils: [String] = []
        ufils.reserveCapacity(ufc)
        for i in 0..<ufc {
            if let c = orca_session_user_filament_name(s, Int32(i)) {
                ufils.append(String(cString: c))
            }
        }
        userFilamentNames = ufils
        compatibleOnly = orca_session_get_compatible_only(s) != 0
    }

    private func refreshCoverAndBedTexture() {
        guard let s = session else { return }
        var buf = [CChar](repeating: 0, count: 2048)
        if orca_session_printer_cover_path(s, &buf, buf.count) == 0 {
            printerCoverPath = String(cString: buf)
        } else {
            printerCoverPath = nil
        }
        buf = [CChar](repeating: 0, count: 2048)
        if orca_session_printer_bed_texture_path(s, &buf, buf.count) == 0 {
            bedTexturePath = String(cString: buf)
        } else {
            bedTexturePath = printerCoverPath
        }
    }
    #endif

    @discardableResult
    func selectPrinter(_ name: String) -> Bool {
        #if ORCA_LINKED
        guard let s = session, presetsLoaded else { return false }
        let rc = name.withCString { orca_session_select_printer(s, $0) }
        if rc != 0 {
            lastMessage = orca_session_last_error(s).map { String(cString: $0) } ?? "select_printer failed"
            return false
        }
        // Apply machine+process+filament → session config + bed size
        let arc = orca_session_apply_presets(s)
        if arc != 0 {
            lastMessage = orca_session_last_error(s).map { String(cString: $0) } ?? "apply_presets failed"
            return false
        }
        // Compatible process/filament lists rebuilt in C after update_compatible
        refreshPresetLists()
        selectedPrinter = name
        if let c = orca_session_selected_process(s) {
            selectedProcess = String(cString: c)
            activeProcessProfile = selectedProcess
        }
        if let c = orca_session_selected_filament(s) {
            selectedFilament = String(cString: c)
        }
        refreshBedSize()
        refreshCoverAndBedTexture()
        persistSelection()
        lastMessage = String(
            format: "Printer: %@ · bed %d×%d · %d process · %d filament",
            name, Int(bedSize.x), Int(bedSize.y), processNames.count, filamentNames.count
        )
        return true
        #else
        return false
        #endif
    }

    @discardableResult
    func selectProcess(_ name: String) -> Bool {
        #if ORCA_LINKED
        guard let s = session, presetsLoaded else { return false }
        let rc = name.withCString { orca_session_select_process(s, $0) }
        if rc != 0 {
            lastMessage = orca_session_last_error(s).map { String(cString: $0) } ?? "select_process failed"
            return false
        }
        _ = orca_session_apply_presets(s)
        selectedProcess = name
        activeProcessProfile = name
        refreshPresetLists()
        refreshBedSize()
        persistSelection()
        lastMessage = "Process: \(name)"
        return true
        #else
        return false
        #endif
    }

    @discardableResult
    func selectFilament(_ name: String) -> Bool {
        #if ORCA_LINKED
        guard let s = session, presetsLoaded else { return false }
        let rc = name.withCString { orca_session_select_filament(s, $0) }
        if rc != 0 {
            lastMessage = orca_session_last_error(s).map { String(cString: $0) } ?? "select_filament failed"
            return false
        }
        _ = orca_session_apply_presets(s)
        selectedFilament = name
        persistSelection()
        lastMessage = "Filament: \(name)"
        return true
        #else
        return false
        #endif
    }

    func setCompatibleOnly(_ on: Bool) {
        #if ORCA_LINKED
        guard let s = session else { return }
        compatibleOnly = on
        orca_session_set_compatible_only(s, on ? 1 : 0)
        UserDefaults.standard.set(on, forKey: prefsCompatKey)
        refreshPresetLists()
        lastMessage = on
            ? "Compatible process/filament only"
            : "Showing all process/filament profiles"
        #endif
    }

    /// Persist current process settings as a user preset (Documents/…/user_presets/process).
    @discardableResult
    func saveUserProcess(name: String) -> Bool {
        #if ORCA_LINKED
        guard let s = session else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastMessage = "Enter a name for the user process"
            return false
        }
        let rc = trimmed.withCString { orca_session_save_user_process(s, $0) }
        if rc != 0 {
            lastMessage = orca_session_last_error(s).map { String(cString: $0) } ?? "save user process failed"
            return false
        }
        refreshPresetLists()
        selectedProcess = trimmed
        activeProcessProfile = trimmed
        persistSelection()
        lastMessage = "Saved user process “\(trimmed)”"
        return true
        #else
        return false
        #endif
    }

    /// Persist current filament settings as user preset (Documents/…/user_presets/filament).
    @discardableResult
    func saveUserFilament(name: String) -> Bool {
        #if ORCA_LINKED
        guard let s = session else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastMessage = "Enter a name for the user filament"
            return false
        }
        let rc = trimmed.withCString { orca_session_save_user_filament(s, $0) }
        if rc != 0 {
            lastMessage = orca_session_last_error(s).map { String(cString: $0) } ?? "save user filament failed"
            return false
        }
        refreshPresetLists()
        selectedFilament = trimmed
        persistSelection()
        lastMessage = "Saved user filament “\(trimmed)”"
        return true
        #else
        return false
        #endif
    }

    /// Export current DynamicPrintConfig to Documents (or given URL) as JSON.
    @discardableResult
    func exportConfigJSON(to url: URL? = nil) -> URL? {
        #if ORCA_LINKED
        guard let s = session else {
            lastMessage = "No session"
            return nil
        }
        let dest: URL
        if let url {
            dest = url
        } else {
            let name = selectedProcess.isEmpty ? "OrcaConfig" : selectedProcess
                .replacingOccurrences(of: "/", with: "-")
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            dest = docs.appendingPathComponent("OrcaSlicer/exports/\(name).json")
            try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let rc = dest.path.withCString { orca_session_export_config(s, $0) }
        if rc != 0 {
            lastMessage = orca_session_last_error(s).map { String(cString: $0) } ?? "export config failed"
            return nil
        }
        lastMessage = "Exported config → \(dest.lastPathComponent)"
        return dest
        #else
        lastMessage = "Not linked"
        return nil
        #endif
    }

    /// Import config JSON as overlay (or as user process/filament if kind set).
    /// kind: nil = overlay only; 0 = user process; 1 = user filament
    @discardableResult
    func importConfigJSON(url: URL, asUserPreset kind: Int? = nil) -> Bool {
        #if ORCA_LINKED
        guard let s = session else { return false }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let dest = copyToTemp(url) else { return false }
        if let kind {
            let rc = dest.path.withCString { orca_session_import_user_preset(s, $0, Int32(kind)) }
            if rc != 0 {
                lastMessage = orca_session_last_error(s).map { String(cString: $0) } ?? "import preset failed"
                return false
            }
            refreshPresetLists()
            if kind == 0 {
                if let c = orca_session_selected_process(s) {
                    selectedProcess = String(cString: c)
                    activeProcessProfile = selectedProcess
                }
            } else {
                if let c = orca_session_selected_filament(s) {
                    selectedFilament = String(cString: c)
                }
            }
            persistSelection()
            lastMessage = kind == 0
                ? "Imported user process from \(url.lastPathComponent)"
                : "Imported user filament from \(url.lastPathComponent)"
            return true
        } else {
            let rc = dest.path.withCString { orca_session_import_config(s, $0) }
            if rc != 0 {
                lastMessage = orca_session_last_error(s).map { String(cString: $0) } ?? "import config failed"
                return false
            }
            lastMessage = "Imported config overlay from \(url.lastPathComponent)"
            return true
        }
        #else
        return false
        #endif
    }

    // MARK: - Mesh / object ops (G14)

    @discardableResult
    func cloneGrid(nx: Int, ny: Int, spacingMm: Float = 15) -> Bool {
        #if ORCA_LINKED
        guard let s = session, hasModel else { return false }
        let idx = selectedObjectIndex >= 0 ? selectedObjectIndex : 0
        let rc = orca_session_clone_grid(s, Int32(idx), Int32(nx), Int32(ny), spacingMm)
        if rc < 0 {
            lastMessage = orca_session_last_error(s).map { String(cString: $0) } ?? "clone_grid failed"
            return false
        }
        refreshObjectList()
        refreshMesh()
        refreshBounds()
        refreshModelInfo()
        lastMessage = "Clone grid \(nx)×\(ny) → \(objectCount) objects"
        return true
        #else
        return false
        #endif
    }

    @discardableResult
    func refreshMeshHealth() -> Bool {
        #if ORCA_LINKED
        guard let s = session, hasModel else {
            meshHealthText = ""
            return false
        }
        let idx = selectedObjectIndex >= 0 ? Int32(selectedObjectIndex) : Int32(-1)
        var facets: Int32 = 0, openEdges: Int32 = 0, parts: Int32 = 0
        var vol: Float = 0
        let rc = orca_session_mesh_stats(s, idx, &facets, &openEdges, &parts, &vol)
        if rc != 0 {
            meshHealthText = orca_session_last_error(s).map { String(cString: $0) } ?? "stats failed"
            return false
        }
        if openEdges == 0 {
            meshHealthText = "Manifold · \(facets) facets · \(parts) part(s)"
        } else {
            meshHealthText = "Non-manifold · \(openEdges) open edges · \(facets) facets"
        }
        lastMessage = meshHealthText
        return true
        #else
        return false
        #endif
    }

    @discardableResult
    func repairMesh() -> Bool {
        #if ORCA_LINKED
        guard let s = session, hasModel else { return false }
        let idx = selectedObjectIndex >= 0 ? Int32(selectedObjectIndex) : Int32(-1)
        let rc = orca_session_repair_mesh(s, idx)
        if rc != 0 {
            lastMessage = orca_session_last_error(s).map { String(cString: $0) } ?? "repair failed"
            _ = refreshMeshHealth()
            return false
        }
        refreshMesh()
        refreshBounds()
        refreshModelInfo()
        _ = refreshMeshHealth()
        lastMessage = "Repair done · \(meshHealthText)"
        return true
        #else
        return false
        #endif
    }

    /// Horizontal plane cut at world Z (mm). keep both halves by default.
    @discardableResult
    func cutObjectZ(_ zMm: Float, keepUpper: Bool = true, keepLower: Bool = true) -> Bool {
        #if ORCA_LINKED
        guard let s = session, hasModel else { return false }
        let idx = selectedObjectIndex >= 0 ? selectedObjectIndex : 0
        let rc = orca_session_cut_object_z(
            s, Int32(idx), zMm, keepUpper ? 1 : 0, keepLower ? 1 : 0
        )
        if rc < 0 {
            lastMessage = orca_session_last_error(s).map { String(cString: $0) } ?? "cut failed"
            return false
        }
        selectedObjectIndex = -1
        refreshObjectList()
        refreshMesh()
        refreshBounds()
        refreshModelInfo()
        lastMessage = String(format: "Cut at Z=%.2f mm → %d object(s)", zMm, objectCount)
        return true
        #else
        return false
        #endif
    }

    private func persistSelection() {
        UserDefaults.standard.set(selectedPrinter, forKey: prefsPrinterKey)
        UserDefaults.standard.set(selectedProcess, forKey: prefsProcessKey)
        UserDefaults.standard.set(selectedFilament, forKey: prefsFilamentKey)
    }

    /// Printers for a vendor (empty vendor = all). Optional search filter.
    func filteredPrinters(vendor: String?, search: String) -> [String] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return printerNames.enumerated().compactMap { idx, name in
            if let vendor, !vendor.isEmpty {
                let v = idx < printerVendors.count ? printerVendors[idx] : ""
                if v.caseInsensitiveCompare(vendor) != .orderedSame { return nil }
            }
            if !q.isEmpty && !name.lowercased().contains(q) { return nil }
            return name
        }
    }

    func filteredProcesses(search: String) -> [String] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return processNames }
        return processNames.filter { $0.lowercased().contains(q) }
    }

    func filteredFilaments(search: String) -> [String] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return filamentNames }
        return filamentNames.filter { $0.lowercased().contains(q) }
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
        let is3MF = url.pathExtension.lowercased() == "3mf"
        // 3MF projects already store world transforms + print config — do not re-center.
        if append {
            _ = orca_session_arrange(s)
        } else if !is3MF {
            _ = orca_session_center_on_bed(s)
        }
        refreshObjectList()
        refreshMesh()
        refreshBounds()
        refreshModelInfo()
        refreshBedSize()
        gcodeURL = nil
        gcodePathNode = nil
        gcodeGeometry = nil
        if is3MF && !append {
            lastMessage = "Opened project \(url.lastPathComponent) · \(objectCount) object(s) · config restored"
        } else {
            lastMessage = "Loaded \(url.lastPathComponent) · \(objectCount) object(s) · mesh ready"
        }
        return lastMessage
        #else
        modelName = url.lastPathComponent + " (engine not linked)"
        hasModel = false
        lastMessage = "Engine not linked"
        return lastMessage
        #endif
    }

    /// Rebuild G-code SceneKit node from geometry filtered by min/max Z clip + feature toggles
    func applyPreviewLayer() {
        guard let geo = gcodeGeometry else {
            gcodePathNode = nil
            return
        }
        var groups = Set<GCodePathGeometry.FeatureGroup>()
        if previewShowWall { groups.insert(.wall) }
        if previewShowInfill { groups.insert(.infill) }
        if previewShowSupport { groups.insert(.support) }
        if previewShowTravel { groups.insert(.travel) }
        if previewShowOther { groups.insert(.other) }
        // Clamp min ≤ max
        let lo = min(previewMinZ, previewMaxZ)
        let hi = max(previewMinZ, previewMaxZ)
        let filtered = geo.filtered(
            minZ: lo,
            maxZ: hi,
            enabledGroups: groups
        )
        #if canImport(UIKit)
        gcodePathNode = filtered.makeNode(
            color: UIColor(red: 0, green: 150 / 255, blue: 136 / 255, alpha: 1),
            colorMode: previewColorMode
        )
        #endif
    }

    func refreshMesh() {
        #if ORCA_LINKED
        guard let s = session, hasModel else {
            mesh = nil
            objectMeshes = []
            return
        }
        // Combined mesh (framing + single-object fallback)
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
            objectMeshes = []
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

        // Per-object meshes so the user can tap/select on the plate
        let n = Int(orca_session_object_count(s))
        var per: [MeshGeometry] = []
        per.reserveCapacity(max(n, 0))
        for oi in 0..<n {
            var oPos: UnsafeMutablePointer<Float>?
            var oIdx: UnsafeMutablePointer<UInt32>?
            var ov: Int = 0, oiCount: Int = 0
            let orc = orca_session_export_object_mesh(s, Int32(oi), &oPos, &ov, &oIdx, &oiCount)
            defer {
                if let p = oPos { orca_free(p) }
                if let i = oIdx { orca_free(i) }
            }
            guard orc == 0, let oPos, let oIdx, ov > 0, oiCount > 0 else {
                per.append(MeshGeometry(positions: [], indices: [], min: .zero, max: .zero))
                continue
            }
            let pos = Array(UnsafeBufferPointer(start: oPos, count: ov * 3))
            let ind = Array(UnsafeBufferPointer(start: oIdx, count: oiCount))
            var omin = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
            var omax = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
            for i in 0..<ov {
                let p = SIMD3(pos[i * 3], pos[i * 3 + 1], pos[i * 3 + 2])
                omin = min(omin, p)
                omax = max(omax, p)
            }
            per.append(MeshGeometry(positions: pos, indices: ind, min: omin, max: omax))
        }
        objectMeshes = per
        #endif
    }

    func selectObject(at index: Int) {
        let count = max(objectCount, objectMeshes.count)
        guard index >= 0, index < count else {
            clearSelection()
            return
        }
        // Tap same object again → deselect
        if selectedObjectIndex == index {
            clearSelection()
            return
        }
        selectedObjectIndex = index
        let name = objectNames.indices.contains(index) ? objectNames[index] : "Object \(index + 1)"
        lastMessage = "Selected \(name) · tap again or empty plate to deselect"
    }

    func clearSelection() {
        selectedObjectIndex = -1
        lastMessage = "Nothing selected · tap an object to select"
    }

    func refreshBounds() {
        #if ORCA_LINKED
        guard let s = session, hasModel else {
            boundsText = ""
            modelMinZ = 0
            modelMaxZ = 0
            return
        }
        var minx: Float = 0, miny: Float = 0, minz: Float = 0
        var maxx: Float = 0, maxy: Float = 0, maxz: Float = 0
        if orca_session_model_bounds(s, &minx, &miny, &minz, &maxx, &maxy, &maxz) == 0 {
            modelMinZ = minz
            modelMaxZ = maxz
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
        if rc == 0 {
            lastMessage = "set \(key)=\(value)"
        } else {
            let err = orca_session_last_error(s).map { String(cString: $0) } ?? "unknown"
            lastMessage = "Failed to set \(key)=\(value): \(err)"
        }
        #else
        lastMessage = "Not linked"
        #endif
    }

    /// Uses selectedObjectIndex when index omitted (-1 = all, or selection)
    private var transformIndex: Int32 {
        Int32(selectedObjectIndex)
    }

    /// index -1 = all objects; default uses selectedObjectIndex
    func translate(dx: Float, dy: Float, dz: Float = 0, index: Int? = nil, recordUndo: Bool = true) {
        #if ORCA_LINKED
        guard let s = session, hasModel else { return }
        if recordUndo { pushUndoSnapshot(label: "move") }
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
        rotate(axis: 2, degrees: degrees, index: index)
    }

    /// axis: 0=X, 1=Y, 2=Z
    func rotate(axis: Int, degrees: Float, index: Int? = nil) {
        #if ORCA_LINKED
        guard let s = session, hasModel else { return }
        pushUndoSnapshot(label: "rotate")
        let idx = Int32(index ?? selectedObjectIndex)
        let rc = orca_session_rotate_object_axis(s, idx, Int32(axis), degrees)
        if rc == 0 {
            refreshMesh(); refreshBounds(); refreshModelInfo()
            let ax = ["X", "Y", "Z"][max(0, min(2, axis))]
            lastMessage = String(format: "Rotated %@ %.0f°", ax, degrees)
        } else {
            lastMessage = orca_session_last_error(s).map { String(cString: $0) } ?? "rotate failed"
        }
        #endif
    }

    /// axis: 0=X, 1=Y, 2=Z
    func mirror(axis: Int, index: Int? = nil) {
        #if ORCA_LINKED
        guard let s = session, hasModel else { return }
        pushUndoSnapshot(label: "mirror")
        let idx = Int32(index ?? selectedObjectIndex)
        let rc = orca_session_mirror_object(s, idx, Int32(axis))
        if rc == 0 {
            refreshMesh(); refreshBounds(); refreshModelInfo()
            let ax = ["X", "Y", "Z"][max(0, min(2, axis))]
            lastMessage = "Mirrored \(ax)"
        } else {
            lastMessage = orca_session_last_error(s).map { String(cString: $0) } ?? "mirror failed"
        }
        #endif
    }

    func scale(factor: Float, index: Int? = nil) {
        #if ORCA_LINKED
        guard let s = session, hasModel else { return }
        pushUndoSnapshot(label: "scale")
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

    func scaleToFit(marginMm: Float = 5, index: Int? = nil) {
        #if ORCA_LINKED
        guard let s = session, hasModel else { return }
        let idx = Int32(index ?? selectedObjectIndex)
        let rc = orca_session_scale_to_fit(s, idx, marginMm)
        if rc == 0 {
            refreshMesh(); refreshBounds(); refreshModelInfo()
            lastMessage = "Scaled to fit bed"
        } else {
            lastMessage = orca_session_last_error(s).map { String(cString: $0) } ?? "scale_to_fit failed"
        }
        #endif
    }

    func autoOrient(index: Int? = nil) {
        #if ORCA_LINKED
        guard let s = session, hasModel else { return }
        let idx = Int32(index ?? selectedObjectIndex)
        let rc = orca_session_orient_object(s, idx)
        if rc == 0 {
            refreshMesh(); refreshBounds(); refreshModelInfo()
            lastMessage = "Auto-oriented"
        } else {
            lastMessage = orca_session_last_error(s).map { String(cString: $0) } ?? "orient failed"
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

    /// factor 0 = collapse, 1+ = explode (wx assembly explode lite)
    func explode(factor: Float, spacingMm: Float = 25) {
        _ = explodeObjects(factor: factor, spacingMm: spacingMm)
    }

    // MARK: Host job history (wx send queue lite)
    private static let hostHistoryKey = "orca.host.jobHistory"
    @Published var hostJobHistory: [String] = UserDefaults.standard.stringArray(forKey: OrcaEngine.hostHistoryKey) ?? []

    func recordHostJob(host: String, file: String, hostType: String = "") {
        let line = "\(ISO8601DateFormatter().string(from: Date())) · \(host) · \(file)"
        var h = hostJobHistory
        h.insert(line, at: 0)
        if h.count > 40 { h = Array(h.prefix(40)) }
        hostJobHistory = h
        UserDefaults.standard.set(h, forKey: Self.hostHistoryKey)
        // Also structured history for Device tab detail
        appendJobHistory(host: host, filename: file, hostType: hostType)
    }

    func clearHostJobHistory() {
        hostJobHistory = []
        UserDefaults.standard.removeObject(forKey: Self.hostHistoryKey)
        clearJobHistory()
    }

    // MARK: First-run wizard prefs (language / region / vendors / last printer)
    static let wizardDoneKey = "orca.wizard.done"
    static var wizardCompleted: Bool {
        get {
            UserDefaults.standard.bool(forKey: wizardDoneKey)
                || UserDefaults.standard.bool(forKey: prefsWizardDoneKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: wizardDoneKey)
            UserDefaults.standard.set(newValue, forKey: prefsWizardDoneKey)
        }
    }

    static var preferredVendors: [String] {
        get {
            UserDefaults.standard.stringArray(forKey: prefsPreferredVendorsKey)
                ?? UserDefaults.standard.stringArray(forKey: "orca.wizard.vendors")
                ?? []
        }
        set {
            UserDefaults.standard.set(newValue, forKey: prefsPreferredVendorsKey)
            UserDefaults.standard.set(newValue, forKey: "orca.wizard.vendors")
        }
    }

    static var appLanguage: String {
        get { UserDefaults.standard.string(forKey: prefsLanguageKey) ?? "en" }
        set { UserDefaults.standard.set(newValue, forKey: prefsLanguageKey) }
    }

    static var appRegion: String {
        get { UserDefaults.standard.string(forKey: prefsRegionKey) ?? "International" }
        set { UserDefaults.standard.set(newValue, forKey: prefsRegionKey) }
    }

    var extruderCount: Int {
        #if ORCA_LINKED
        guard let s = session else { return 1 }
        return max(1, Int(orca_session_extruder_count(s)))
        #else
        return 1
        #endif
    }

    func filamentSlotName(_ slot: Int) -> String {
        #if ORCA_LINKED
        guard let s = session, let c = orca_session_filament_slot_name(s, Int32(slot)) else { return "" }
        return String(cString: c)
        #else
        return ""
        #endif
    }

    @discardableResult
    func setFilamentSlot(_ slot: Int, name: String) -> Bool {
        #if ORCA_LINKED
        guard let s = session else { return false }
        let rc = name.withCString { orca_session_set_filament_slot(s, Int32(slot), $0) }
        if rc == 0 {
            if slot == 0 { selectedFilament = name }
            lastMessage = "Slot \(slot + 1): \(name)"
            return true
        }
        lastMessage = orca_session_last_error(s).map { String(cString: $0) } ?? "set filament slot failed"
        return false
        #else
        return false
        #endif
    }

    // MARK: Recent files
    private static let recentKey = "orca.recent.models"
    @Published var recentModelPaths: [String] = UserDefaults.standard.stringArray(forKey: OrcaEngine.recentKey) ?? []

    func rememberRecent(url: URL) {
        var list = recentModelPaths.filter { $0 != url.path }
        list.insert(url.path, at: 0)
        if list.count > 12 { list = Array(list.prefix(12)) }
        recentModelPaths = list
        UserDefaults.standard.set(list, forKey: Self.recentKey)
    }

    func duplicateObject(at index: Int) {
        #if ORCA_LINKED
        guard let s = session, hasModel, index >= 0 else { return }
        let rc = orca_session_duplicate_object(s, Int32(index))
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

    func duplicateSelected() {
        let idx = selectedObjectIndex >= 0 ? selectedObjectIndex : 0
        duplicateObject(at: idx)
    }

    func deleteObject(at index: Int) {
        #if ORCA_LINKED
        guard let s = session, hasModel, index >= 0 else { return }
        let rc = orca_session_delete_object(s, Int32(index))
        if rc == 0 {
            let n = Int(orca_session_object_count(s))
            hasModel = n > 0
            if !hasModel {
                mesh = nil
                modelName = nil
                objectNames = []
                objectCount = 0
                modelVolumeMm3 = 0
                selectedObjectIndex = -1
                lastMessage = "Plate empty"
            } else {
                if selectedObjectIndex >= n {
                    selectedObjectIndex = n - 1
                }
                refreshObjectList()
                refreshMesh(); refreshBounds(); refreshModelInfo()
                lastMessage = "Deleted object \(index)"
            }
        } else {
            lastMessage = orca_session_last_error(s).map { String(cString: $0) } ?? "delete failed"
        }
        #endif
    }

    func deleteSelected() {
        let idx = selectedObjectIndex >= 0 ? selectedObjectIndex : 0
        deleteObject(at: idx)
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
        var buf = [CChar](repeating: 0, count: 4096)
        let rc = key.withCString { k in
            orca_session_get_option(s, k, &buf, buf.count)
        }
        guard rc == 0 else { return nil }
        return String(cString: buf)
        #else
        return nil
        #endif
    }

    // MARK: - Full settings browser (print_config_def + session values)

    /// Snapshot of DynamicPrintConfig keys for the searchable browser.
    /// Enum choice lists are loaded lazily via `enumChoices(for:)` to save RAM.
    func allConfigOptions() -> [ConfigOptionEntry] {
        #if ORCA_LINKED
        guard let s = session else { return [] }
        let n = Int(orca_session_option_count(s))
        guard n > 0 else { return [] }
        var out: [ConfigOptionEntry] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            guard let ck = orca_session_option_key(s, Int32(i)) else { continue }
            let key = String(cString: ck)
            var type: Int32 = 6
            var labelBuf = [CChar](repeating: 0, count: 256)
            var catBuf = [CChar](repeating: 0, count: 128)
            var sideBuf = [CChar](repeating: 0, count: 64)
            _ = key.withCString { k in
                orca_session_option_info(
                    s, k, &type,
                    &labelBuf, labelBuf.count,
                    &catBuf, catBuf.count,
                    &sideBuf, sideBuf.count
                )
            }
            let label = String(cString: labelBuf)
            let category = String(cString: catBuf)
            let sidetext = String(cString: sideBuf)
            let value = getOption(key) ?? ""
            // Defer enum choice materialization — hundreds of keys × N labels was costly
            out.append(ConfigOptionEntry(
                key: key,
                label: label.isEmpty ? key : label,
                category: category,
                sidetext: sidetext,
                type: ConfigOptionEntry.Kind(rawValue: Int(type)) ?? .other,
                value: value,
                enumChoices: []
            ))
        }
        return out
        #else
        return []
        #endif
    }

    /// Load enum serialize keys for one option (call when user expands an enum row).
    func enumChoices(for key: String) -> [ProcessEnumChoice] {
        #if ORCA_LINKED
        guard let s = session else { return [] }
        let ec = Int(key.withCString { orca_session_option_enum_count(s, $0) })
        guard ec > 0 else { return [] }
        var enums: [ProcessEnumChoice] = []
        enums.reserveCapacity(ec)
        for j in 0..<ec {
            let vk = key.withCString { orca_session_option_enum_value(s, $0, Int32(j)) }
                .map { String(cString: $0) } ?? ""
            let lb = key.withCString { orca_session_option_enum_label(s, $0, Int32(j)) }
                .map { String(cString: $0) } ?? vk
            if !vk.isEmpty {
                enums.append(ProcessEnumChoice(key: vk, label: lb.isEmpty ? vk : lb))
            }
        }
        return enums
        #else
        return []
        #endif
    }

    /// Apply option; returns true on success. Updates lastMessage with engine error text.
    @discardableResult
    func applyConfigOption(key: String, value: String) -> Bool {
        #if ORCA_LINKED
        guard let s = session else {
            lastMessage = "No session"
            return false
        }
        let rc = key.withCString { k in
            value.withCString { v in
                orca_session_set_option(s, k, v)
            }
        }
        if rc == 0 {
            lastMessage = "set \(key)=\(value)"
            return true
        }
        let err = orca_session_last_error(s).map { String(cString: $0) } ?? "unknown"
        lastMessage = "Failed to set \(key)=\(value): \(err)"
        return false
        #else
        lastMessage = "Not linked"
        return false
        #endif
    }

    // MARK: - Calibration (official CalibMode via Print::set_calib_params)

    /// Set calibration sweep for next slice. mode matches CalibMode enum.
    @discardableResult
    func setCalib(mode: Int, start: Double, end: Double, step: Double) -> Bool {
        #if ORCA_LINKED
        guard let s = session else {
            lastMessage = "No session"
            return false
        }
        let rc = orca_session_set_calib(s, Int32(mode), start, end, step)
        if rc != 0 {
            let err = orca_session_last_error(s).map { String(cString: $0) } ?? "error"
            lastMessage = "set_calib rc=\(rc): \(err)"
            return false
        }
        calibMode = mode
        calibSummary = Self.calibLabel(mode: mode, start: start, end: end, step: step)
        lastMessage = "Calibration: \(calibSummary)"
        return true
        #else
        lastMessage = "Not linked"
        return false
        #endif
    }

    @discardableResult
    func clearCalib() -> Bool {
        #if ORCA_LINKED
        guard let s = session else { return false }
        _ = orca_session_clear_calib(s)
        calibMode = 0
        calibSummary = ""
        lastMessage = "Calibration cleared"
        return true
        #else
        return false
        #endif
    }

    private static func calibLabel(mode: Int, start: Double, end: Double, step: Double) -> String {
        let name: String
        switch mode {
        case 1: name = "PA Line"
        case 2: name = "PA Pattern"
        case 3: name = "PA Tower"
        case 5: name = "Flow Rate"
        case 6: name = "Temp Tower"
        case 9: name = "Retraction"
        default: name = "Mode \(mode)"
        }
        if mode == 5 { return name }
        return String(format: "%@ %.3g→%.3g step %.3g", name, start, end, step)
    }

    /// Load official bundled calib mesh under Resources/calib/…
    @discardableResult
    func loadBundledCalib(relativePath: String) -> Bool {
        // Try folder-reference layout (Resources/calib/…) then flat lookup
        let candidates: [URL?] = [
            Bundle.main.resourceURL?.appendingPathComponent("calib").appendingPathComponent(relativePath),
            Bundle.main.url(forResource: (relativePath as NSString).deletingPathExtension,
                            withExtension: (relativePath as NSString).pathExtension,
                            subdirectory: "calib/" + ((relativePath as NSString).deletingLastPathComponent)),
            Bundle.main.url(forResource: (relativePath as NSString).lastPathComponent.replacingOccurrences(of: ".\((relativePath as NSString).pathExtension)", with: ""),
                            withExtension: (relativePath as NSString).pathExtension,
                            subdirectory: "calib"),
        ]
        for case let url? in candidates {
            if FileManager.default.fileExists(atPath: url.path) {
                let msg = loadModel(url: url, append: false)
                lastMessage = "Calib model: \(url.lastPathComponent) · \(msg)"
                return hasModel
            }
        }
        lastMessage = "Bundled calib missing: calib/\(relativePath)"
        return false
    }

    /// Temp tower: load model + set Calib_Temp_Tower (temps change each 5 °C block).
    @discardableResult
    func prepareTempTower(startC: Double = 230, endC: Double = 190) -> Bool {
        guard loadBundledCalib(relativePath: "temperature_tower/temperature_tower.drc") else {
            return false
        }
        // Brim helps adhesion on tall towers
        setOption("brim_type", value: "outer_only")
        setOption("brim_width", value: "5")
        setOption("enable_support", value: "0")
        let start = max(endC + 5, min(500, startC))
        let end = min(start - 5, max(155, endC))
        setOption("nozzle_temperature", value: String(Int(start)))
        setOption("nozzle_temperature_initial_layer", value: String(Int(start)))
        return setCalib(mode: 6, start: start, end: end, step: 5)
    }

    /// Flow rate pass 1 or 2 (official multi-object 3MF with per-object flow modifiers).
    @discardableResult
    func prepareFlowRate(pass: Int = 1, linear: Bool = true) -> Bool {
        let path: String
        if linear {
            path = pass == 2
                ? "filament_flow/Orca-LinearFlow_fine.3mf"
                : "filament_flow/Orca-LinearFlow.3mf"
        } else {
            path = pass == 2
                ? "filament_flow/flowrate-test-pass2.3mf"
                : "filament_flow/flowrate-test-pass1.3mf"
        }
        guard loadBundledCalib(relativePath: path) else { return false }
        setOption("enable_support", value: "0")
        return setCalib(mode: 5, start: 0, end: 0, step: 0)
    }

    /// Pressure advance line test (Klipper/Marlin PA).
    @discardableResult
    func preparePressureAdvance(start: Double = 0, end: Double = 0.1, step: Double = 0.002) -> Bool {
        guard loadBundledCalib(relativePath: "pressure_advance/pressure_advance_test.drc") else {
            return false
        }
        setOption("enable_support", value: "0")
        return setCalib(mode: 1, start: start, end: end, step: max(0.0001, step))
    }

    /// Retraction tower (length increases with Z).
    @discardableResult
    func prepareRetraction(start: Double = 0, end: Double = 2, step: Double = 0.1) -> Bool {
        guard loadBundledCalib(relativePath: "retraction/retraction_tower.drc") else {
            return false
        }
        setOption("enable_support", value: "0")
        return setCalib(mode: 9, start: start, end: end, step: max(0.01, step))
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
            // Extended analysis (layer times + role usage)
            var initT: Float = 0, avgT: Float = 0, sup: Float = 0, wipe: Float = 0
            var t2: Float = 0, fil2: Float = 0
            var layers2: Int32 = 0
            if orca_session_last_slice_analysis(sess, &t2, &initT, &avgT, &fil2, &sup, &wipe, &layers2) == 0 {
                self.lastInitialLayerTimeSec = initT
                self.lastAvgLayerTimeSec = avgT
                self.lastSupportMm3 = sup
                self.lastWipeTowerMm3 = wipe
                if avgT > 0 {
                    let am = Int(avgT) / 60
                    let as_ = Int(avgT) % 60
                    let im = Int(initT) / 60
                    let is_ = Int(initT) % 60
                    self.lastAvgLayerTimeText = String(
                        format: "avg layer ~%dm %02ds · 1st ~%dm %02ds",
                        am, as_, im, is_
                    )
                } else {
                    self.lastAvgLayerTimeText = ""
                }
            } else {
                self.lastAvgLayerTimeText = ""
            }
            let rc = Int(orca_session_filament_role_count(sess))
            var roles: [(name: String, meters: Float, grams: Float)] = []
            roles.reserveCapacity(rc)
            for i in 0..<rc {
                guard let c = orca_session_filament_role_name(sess, Int32(i)) else { continue }
                let name = String(cString: c)
                let m = orca_session_filament_role_meters(sess, Int32(i))
                let g = orca_session_filament_role_grams(sess, Int32(i))
                roles.append((name, m, g))
            }
            roles.sort { $0.grams > $1.grams }
            self.filamentByRole = roles
            // Default ribbon width from official line_width / nozzle_diameter
            var defW: Float = 0.45
            if let lw = self.getOptionFirst("line_width").flatMap(Float.init), lw > 0.05 {
                defW = lw
            } else if let nd = self.getOptionFirst("nozzle_diameter").flatMap(Float.init), nd > 0.05 {
                defW = nd * 1.1
            }
            // Cap path points for mobile RAM (ribbons are heavier than lines)
            if let path = GCodePathGeometry.parse(url: out, maxPoints: 60_000, defaultWidth: defW) {
                self.gcodeGeometry = path
                self.gcodeZMin = path.zMin
                self.gcodeZMax = max(path.zMax, path.zMin + 0.2)
                self.previewMinZ = self.gcodeZMin
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

    // MARK: Multi-plate slots

    private var platesDir: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = docs.appendingPathComponent("OrcaSlicer/plates", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func ensurePlateSlots() {
        while platePaths.count < plateCount {
            let i = platePaths.count
            platePaths.append(platesDir.appendingPathComponent("plate_\(i).3mf"))
        }
        if platePaths.count > plateCount {
            platePaths = Array(platePaths.prefix(plateCount))
        }
    }

    /// Persist current plate to its slot file (no-op if empty).
    @discardableResult
    func saveCurrentPlateSlot() -> Bool {
        #if ORCA_LINKED
        ensurePlateSlots()
        guard currentPlateIndex >= 0, currentPlateIndex < platePaths.count else { return false }
        let dest = platePaths[currentPlateIndex]
        if !hasModel {
            // Empty plate: remove prior snapshot if any
            try? FileManager.default.removeItem(at: dest)
            return true
        }
        guard let s = session else { return false }
        let rc = dest.path.withCString { orca_session_save_3mf(s, $0) }
        return rc == 0
        #else
        return false
        #endif
    }

    /// Switch to plate index (saves current first). Loads slot 3MF or clears if empty.
    func selectPlate(_ index: Int) {
        #if ORCA_LINKED
        guard index >= 0, index < plateCount else { return }
        if index == currentPlateIndex { return }
        _ = saveCurrentPlateSlot()
        currentPlateIndex = index
        ensurePlateSlots()
        let path = platePaths[index]
        if FileManager.default.fileExists(atPath: path.path) {
            _ = loadModel(url: path, append: false)
            lastMessage = "Plate \(index + 1) loaded"
        } else {
            clearPlate()
            lastMessage = "Plate \(index + 1) empty"
        }
        #endif
    }

    /// Add a new empty plate and switch to it.
    func addPlate() {
        #if ORCA_LINKED
        _ = saveCurrentPlateSlot()
        plateCount += 1
        ensurePlateSlots()
        currentPlateIndex = plateCount - 1
        clearPlate()
        lastMessage = "Added plate \(plateCount)"
        #endif
    }

    /// Remove current plate if more than one remain.
    func removeCurrentPlate() {
        #if ORCA_LINKED
        guard plateCount > 1 else {
            lastMessage = "Need at least one plate"
            return
        }
        ensurePlateSlots()
        let removeIdx = currentPlateIndex
        try? FileManager.default.removeItem(at: platePaths[removeIdx])
        platePaths.remove(at: removeIdx)
        plateCount -= 1
        if currentPlateIndex >= plateCount {
            currentPlateIndex = plateCount - 1
        }
        ensurePlateSlots()
        let path = platePaths[currentPlateIndex]
        if FileManager.default.fileExists(atPath: path.path) {
            _ = loadModel(url: path, append: false)
        } else {
            clearPlate()
        }
        lastMessage = "Removed plate · now \(plateCount) plate(s)"
        #endif
    }

    // MARK: - wx-parity: undo stack (3MF snapshots) + per-object settings

    private struct UndoEntry {
        let url: URL
        let label: String
    }
    private var undoStack: [UndoEntry] = []
    private var redoStack: [UndoEntry] = []
    private let maxUndo = 40
    @Published var canUndo = false
    @Published var canRedo = false
    /// How many undo steps are available (for UI)
    @Published var undoDepth: Int = 0
    @Published var redoDepth: Int = 0

    private func undoDir() -> URL {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("OrcaUndo", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func refreshUndoFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
        undoDepth = undoStack.count
        redoDepth = redoStack.count
    }

    private func writeSnapshotFile(session s: OpaquePointer, prefix: String) -> URL? {
        let url = undoDir().appendingPathComponent("\(prefix)_\(UUID().uuidString).3mf")
        let rc = url.path.withCString { orca_session_snapshot(s, $0) }
        guard rc == 0 else { return nil }
        // Verify non-empty file — empty 3MF means store failed silently
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber, size.intValue > 64
        else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return url
    }

    private func applySnapshotFile(_ url: URL) -> Bool {
        #if ORCA_LINKED
        guard let s = session else { return false }
        let rc = url.path.withCString { orca_session_restore_snapshot(s, $0) }
        guard rc == 0 else { return false }
        let n = Int(orca_session_object_count(s))
        hasModel = n > 0
        if hasModel {
            refreshObjectList()
            refreshMesh()
            refreshBounds()
            refreshModelInfo()
            refreshBedSize()
            // Keep selection if still valid
            if selectedObjectIndex >= n {
                selectedObjectIndex = n > 0 ? 0 : -1
            }
        } else {
            clearPlate()
        }
        return true
        #else
        return false
        #endif
    }

    /// Call before destructive/transform operations (desktop Edit → Undo stack).
    func pushUndoSnapshot(label: String = "edit") {
        #if ORCA_LINKED
        guard let s = session, hasModel else { return }
        guard let url = writeSnapshotFile(session: s, prefix: "undo") else {
            // Don't wipe existing stack if this push fails
            return
        }
        undoStack.append(UndoEntry(url: url, label: label))
        while undoStack.count > maxUndo {
            let old = undoStack.removeFirst()
            try? FileManager.default.removeItem(at: old.url)
        }
        // New edit branch invalidates redo
        for e in redoStack { try? FileManager.default.removeItem(at: e.url) }
        redoStack.removeAll()
        refreshUndoFlags()
        // Don't stomp lastMessage (caller sets "Moved…" etc.)
        #endif
    }

    func undo() {
        #if ORCA_LINKED
        guard let s = session, let entry = undoStack.popLast() else {
            lastMessage = "Nothing to undo"
            refreshUndoFlags()
            return
        }
        // Save current as redo (post-action state)
        if hasModel, let redoURL = writeSnapshotFile(session: s, prefix: "redo") {
            redoStack.append(UndoEntry(url: redoURL, label: entry.label))
        }
        if applySnapshotFile(entry.url) {
            lastMessage = "Undo · \(entry.label) · \(undoStack.count) left"
        } else {
            lastMessage = orca_session_last_error(s).map { String(cString: $0) } ?? "undo failed"
            // Put entry back if restore failed
            undoStack.append(entry)
        }
        // Drop used undo file only after successful restore
        if lastMessage.hasPrefix("Undo") {
            try? FileManager.default.removeItem(at: entry.url)
        }
        refreshUndoFlags()
        #endif
    }

    func redo() {
        #if ORCA_LINKED
        guard let s = session, let entry = redoStack.popLast() else {
            lastMessage = "Nothing to redo"
            refreshUndoFlags()
            return
        }
        if hasModel, let undoURL = writeSnapshotFile(session: s, prefix: "undo") {
            undoStack.append(UndoEntry(url: undoURL, label: entry.label))
        }
        if applySnapshotFile(entry.url) {
            lastMessage = "Redo · \(entry.label)"
            try? FileManager.default.removeItem(at: entry.url)
        } else {
            lastMessage = orca_session_last_error(s).map { String(cString: $0) } ?? "redo failed"
            redoStack.append(entry)
        }
        refreshUndoFlags()
        #endif
    }

    @discardableResult
    func setObjectOption(index: Int, key: String, value: String) -> Bool {
        #if ORCA_LINKED
        guard let s = session, index >= 0 else { return false }
        pushUndoSnapshot(label: key)
        let rc = key.withCString { k in
            value.withCString { v in
                orca_session_set_object_option(s, Int32(index), k, v)
            }
        }
        if rc == 0 {
            lastMessage = "Object \(index + 1): \(key)=\(value)"
            return true
        }
        lastMessage = orca_session_last_error(s).map { String(cString: $0) } ?? "object option failed"
        return false
        #else
        return false
        #endif
    }

    func getObjectOption(index: Int, key: String) -> String? {
        #if ORCA_LINKED
        guard let s = session, index >= 0 else { return nil }
        var buf = [CChar](repeating: 0, count: 512)
        let rc = key.withCString { k in
            orca_session_get_object_option(s, Int32(index), k, &buf, buf.count)
        }
        guard rc == 0 else { return nil }
        return String(cString: buf)
        #else
        return nil
        #endif
    }

    func eraseObjectOption(index: Int, key: String) {
        #if ORCA_LINKED
        guard let s = session, index >= 0 else { return }
        _ = key.withCString { orca_session_erase_object_option(s, Int32(index), $0) }
        lastMessage = "Cleared object \(key)"
        #endif
    }

    func setObjectExtruder(index: Int, extruder1Based: Int) {
        #if ORCA_LINKED
        guard let s = session, index >= 0 else { return }
        pushUndoSnapshot(label: "extruder")
        let rc = orca_session_set_object_extruder(s, Int32(index), Int32(extruder1Based))
        lastMessage = rc == 0
            ? "Object \(index + 1) → extruder \(extruder1Based)"
            : (orca_session_last_error(s).map { String(cString: $0) } ?? "extruder failed")
        #endif
    }

    // MARK: - wx-parity W1: facet painting (support / seam / MMU / fuzzy)

    /// paint_kind mirrors C API: 0 support, 1 seam, 2 mmu, 3 fuzzy
    enum PaintKind: Int, CaseIterable {
        case support = 0
        case seam = 1
        case mmu = 2
        case fuzzy = 3

        var label: String {
            switch self {
            case .support: return "Support"
            case .seam: return "Seam"
            case .mmu: return "MMU"
            case .fuzzy: return "Fuzzy"
            }
        }
    }

    /// Brush at world hit (slic3r mm). state: 0 erase, 1 enforce/extruder1/fuzzy, 2 block (support/seam).
    @discardableResult
    func paintAt(
        x: Float, y: Float, z: Float,
        kind: PaintKind,
        state: Int,
        radiusMm: Float,
        recordUndo: Bool = false
    ) -> Int {
        #if ORCA_LINKED
        guard let s = session, hasModel else { return -1 }
        if recordUndo { pushUndoSnapshot(label: "paint-\(kind.label)") }
        let objIdx = selectedObjectIndex >= 0 ? Int32(selectedObjectIndex) : Int32(-1)
        let n = orca_session_paint_at(
            s, objIdx, x, y, z, Int32(kind.rawValue), Int32(state), radiusMm
        )
        lastPaintCount = max(0, Int(n))
        if n >= 0 {
            refreshPaintOverlay(kind: kind)
            refreshPaintStats(kind: kind)
            lastMessage = n > 0
                ? "Painted \(n) facet(s) · \(kind.label)"
                : "No facet near brush · \(kind.label)"
        } else {
            lastMessage = orca_session_last_error(s).map { String(cString: $0) } ?? "paint failed"
        }
        return Int(n)
        #else
        return -1
        #endif
    }

    @discardableResult
    func paintFill(kind: PaintKind, state: Int) -> Int {
        #if ORCA_LINKED
        guard let s = session, hasModel else { return -1 }
        let idx = selectedObjectIndex >= 0 ? selectedObjectIndex : 0
        pushUndoSnapshot(label: "paint-fill-\(kind.label)")
        let n = orca_session_paint_fill(s, Int32(idx), Int32(kind.rawValue), Int32(state))
        lastPaintCount = max(0, Int(n))
        if n >= 0 {
            refreshPaintOverlay(kind: kind)
            refreshPaintStats(kind: kind)
            lastMessage = "Fill \(kind.label) · \(n) facets"
        } else {
            lastMessage = orca_session_last_error(s).map { String(cString: $0) } ?? "paint fill failed"
        }
        return Int(n)
        #else
        return -1
        #endif
    }

    @discardableResult
    func paintClear(kind: PaintKind, allObjects: Bool = false) -> Bool {
        #if ORCA_LINKED
        guard let s = session, hasModel else { return false }
        pushUndoSnapshot(label: "paint-clear-\(kind.label)")
        let idx: Int32 = allObjects
            ? -1
            : Int32(selectedObjectIndex >= 0 ? selectedObjectIndex : 0)
        let rc = orca_session_paint_clear(s, idx, Int32(kind.rawValue))
        if rc == 0 {
            refreshPaintOverlay(kind: kind)
            refreshPaintStats(kind: kind)
            lastMessage = "Cleared \(kind.label) paint"
            return true
        }
        lastMessage = orca_session_last_error(s).map { String(cString: $0) } ?? "paint clear failed"
        return false
        #else
        return false
        #endif
    }

    func refreshPaintStats(kind: PaintKind) {
        #if ORCA_LINKED
        guard let s = session, hasModel else {
            paintStatsText = ""
            return
        }
        let idx = selectedObjectIndex >= 0 ? Int32(selectedObjectIndex) : Int32(-1)
        var count: Int32 = 0
        let rc = orca_session_paint_stats(s, idx, Int32(kind.rawValue), -1, &count)
        if rc == 0 {
            paintStatsText = "\(kind.label) · \(count) painted facet(s)"
        } else {
            paintStatsText = ""
        }
        #endif
    }

    /// Load world-space painted facets for SceneKit overlay (any non-NONE state).
    func refreshPaintOverlay(kind: PaintKind?) {
        #if ORCA_LINKED
        guard let s = session, hasModel, let kind else {
            paintOverlayMesh = nil
            return
        }
        let idx = selectedObjectIndex >= 0 ? Int32(selectedObjectIndex) : Int32(-1)
        var posPtr: UnsafeMutablePointer<Float>?
        var idxPtr: UnsafeMutablePointer<UInt32>?
        var vcount: Int = 0
        var icount: Int = 0
        let rc = orca_session_export_paint_mesh(
            s, idx, Int32(kind.rawValue), -1,
            &posPtr, &vcount, &idxPtr, &icount
        )
        defer {
            if let p = posPtr { orca_free(p) }
            if let i = idxPtr { orca_free(i) }
        }
        guard rc == 0, let posPtr, let idxPtr, vcount > 0, icount > 0 else {
            paintOverlayMesh = nil
            return
        }
        var positions = [Float](repeating: 0, count: vcount * 3)
        var indices = [UInt32](repeating: 0, count: icount)
        for i in 0..<(vcount * 3) { positions[i] = posPtr[i] }
        for i in 0..<icount { indices[i] = idxPtr[i] }
        var bmin = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var bmax = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for i in 0..<vcount {
            let p = SIMD3(positions[i * 3], positions[i * 3 + 1], positions[i * 3 + 2])
            bmin = min(bmin, p)
            bmax = max(bmax, p)
        }
        paintOverlayMesh = MeshGeometry(positions: positions, indices: indices, min: bmin, max: bmax)
        #else
        paintOverlayMesh = nil
        #endif
    }

    func clearPaintOverlay() {
        paintOverlayMesh = nil
        paintStatsText = ""
        lastPaintCount = 0
        brimEarCount = 0
    }

    // MARK: - wx-parity W1: brim ears (point markers → ModelObject::brim_points)

    /// Place a brim ear at world XY (desktop GLGizmoBrimEars). radiusMm ≤ 0 → auto.
    @discardableResult
    func brimEarAdd(x: Float, y: Float, radiusMm: Float = 0, recordUndo: Bool = true) -> Int {
        #if ORCA_LINKED
        guard let s = session, hasModel else { return -1 }
        if recordUndo { pushUndoSnapshot(label: "brim-ear-add") }
        let idx = selectedObjectIndex >= 0 ? selectedObjectIndex : 0
        let n = orca_session_brim_ear_add(s, Int32(idx), x, y, radiusMm)
        if n >= 0 {
            brimEarCount = Int(n)
            // Ensure process uses painted ears
            setOption("brim_type", value: "painted")
            refreshBrimEarOverlay()
            lastMessage = "Brim ear #\(n) @ (\(String(format: "%.1f", x)), \(String(format: "%.1f", y)))"
        } else {
            lastMessage = orca_session_last_error(s).map { String(cString: $0) } ?? "brim ear add failed"
        }
        return Int(n)
        #else
        return -1
        #endif
    }

    /// Remove nearest brim ear within maxDistMm of world XY.
    @discardableResult
    func brimEarRemoveNearest(x: Float, y: Float, maxDistMm: Float = 8, recordUndo: Bool = true) -> Int {
        #if ORCA_LINKED
        guard let s = session, hasModel else { return -1 }
        if recordUndo { pushUndoSnapshot(label: "brim-ear-remove") }
        let idx = selectedObjectIndex >= 0 ? selectedObjectIndex : 0
        let n = orca_session_brim_ear_remove_nearest(s, Int32(idx), x, y, maxDistMm)
        if n >= 0 {
            brimEarCount = Int(n)
            refreshBrimEarOverlay()
            lastMessage = "Brim ears remaining: \(n)"
        } else {
            lastMessage = orca_session_last_error(s).map { String(cString: $0) } ?? "brim ear remove failed"
        }
        return Int(n)
        #else
        return -1
        #endif
    }

    @discardableResult
    func brimEarClear(allObjects: Bool = false) -> Bool {
        #if ORCA_LINKED
        guard let s = session, hasModel else { return false }
        pushUndoSnapshot(label: "brim-ear-clear")
        let idx: Int32 = allObjects ? -1 : Int32(selectedObjectIndex >= 0 ? selectedObjectIndex : 0)
        let rc = orca_session_brim_ear_clear(s, idx)
        if rc == 0 {
            brimEarCount = 0
            paintOverlayMesh = nil
            lastMessage = "Cleared brim ears"
            return true
        }
        lastMessage = orca_session_last_error(s).map { String(cString: $0) } ?? "brim ear clear failed"
        return false
        #else
        return false
        #endif
    }

    func refreshBrimEarCount() {
        #if ORCA_LINKED
        guard let s = session, hasModel else {
            brimEarCount = 0
            return
        }
        let idx = selectedObjectIndex >= 0 ? Int32(selectedObjectIndex) : Int32(-1)
        var count: Int32 = 0
        if orca_session_brim_ear_count(s, idx, &count) == 0 {
            brimEarCount = Int(count)
            paintStatsText = "Brim ears · \(count) marker(s)"
        }
        #endif
    }

    func refreshBrimEarOverlay() {
        #if ORCA_LINKED
        guard let s = session, hasModel else {
            paintOverlayMesh = nil
            return
        }
        let idx = selectedObjectIndex >= 0 ? Int32(selectedObjectIndex) : Int32(-1)
        var posPtr: UnsafeMutablePointer<Float>?
        var idxPtr: UnsafeMutablePointer<UInt32>?
        var vcount: Int = 0
        var icount: Int = 0
        let rc = orca_session_export_brim_ear_mesh(
            s, idx, &posPtr, &vcount, &idxPtr, &icount
        )
        defer {
            if let p = posPtr { orca_free(p) }
            if let i = idxPtr { orca_free(i) }
        }
        refreshBrimEarCount()
        guard rc == 0, let posPtr, let idxPtr, vcount > 0, icount > 0 else {
            paintOverlayMesh = nil
            return
        }
        var positions = [Float](repeating: 0, count: vcount * 3)
        var indices = [UInt32](repeating: 0, count: icount)
        for i in 0..<(vcount * 3) { positions[i] = posPtr[i] }
        for i in 0..<icount { indices[i] = idxPtr[i] }
        var bmin = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var bmax = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for i in 0..<vcount {
            let p = SIMD3(positions[i * 3], positions[i * 3 + 1], positions[i * 3 + 2])
            bmin = min(bmin, p)
            bmax = max(bmax, p)
        }
        paintOverlayMesh = MeshGeometry(positions: positions, indices: indices, min: bmin, max: bmax)
        #else
        paintOverlayMesh = nil
        #endif
    }

    // MARK: - wx-parity W2: mesh boolean / simplify / plane cut

    /// op: 0=union, 1=difference (A−B), 2=intersection. Deletes B by default.
    @discardableResult
    func meshBoolean(objectA: Int? = nil, objectB: Int? = nil, op: Int, deleteB: Bool = true) -> Bool {
        #if ORCA_LINKED
        guard let s = session, hasModel, objectCount >= 2 else {
            lastMessage = "Boolean needs ≥2 objects"
            return false
        }
        let a = objectA ?? (selectedObjectIndex >= 0 ? selectedObjectIndex : 0)
        var b = objectB ?? booleanOtherObjectIndex
        if b < 0 || b == a {
            b = (a + 1) % objectCount
        }
        if b == a {
            lastMessage = "Boolean: pick a different second object"
            return false
        }
        pushUndoSnapshot(label: "mesh-boolean-\(op)")
        let rc = orca_session_mesh_boolean(s, Int32(a), Int32(b), Int32(op), deleteB ? 1 : 0)
        if rc != 0 {
            lastMessage = orca_session_last_error(s).map { String(cString: $0) } ?? "boolean failed"
            return false
        }
        selectedObjectIndex = min(a, objectCount - 2) // B deleted may shift indices
        refreshObjectList()
        refreshMesh()
        refreshBounds()
        refreshModelInfo()
        let opName = op == 0 ? "Union" : (op == 1 ? "Difference" : "Intersect")
        lastMessage = "\(opName) → \(objectCount) object(s)"
        return true
        #else
        return false
        #endif
    }

    /// Simplify selected object (targetFaces 0 = ~50%).
    @discardableResult
    func simplifyMesh(targetFaces: Int = 0) -> Bool {
        #if ORCA_LINKED
        guard let s = session, hasModel else { return false }
        let idx = selectedObjectIndex >= 0 ? selectedObjectIndex : 0
        pushUndoSnapshot(label: "simplify-mesh")
        let n = orca_session_simplify_mesh(s, Int32(idx), Int32(targetFaces))
        if n < 0 {
            lastMessage = orca_session_last_error(s).map { String(cString: $0) } ?? "simplify failed"
            return false
        }
        refreshMesh()
        refreshBounds()
        refreshModelInfo()
        _ = refreshMeshHealth()
        lastMessage = "Simplified → \(n) triangles"
        return true
        #else
        return false
        #endif
    }

    /// Plane cut with arbitrary normal (world mm). Default normal = +Z (horizontal).
    @discardableResult
    func cutObjectPlane(
        point: SIMD3<Float>,
        normal: SIMD3<Float> = SIMD3(0, 0, 1),
        keepUpper: Bool = true,
        keepLower: Bool = true
    ) -> Bool {
        #if ORCA_LINKED
        guard let s = session, hasModel else { return false }
        let idx = selectedObjectIndex >= 0 ? selectedObjectIndex : 0
        pushUndoSnapshot(label: "cut-plane")
        let rc = orca_session_cut_object_plane(
            s, Int32(idx),
            point.x, point.y, point.z,
            normal.x, normal.y, normal.z,
            keepUpper ? 1 : 0, keepLower ? 1 : 0
        )
        if rc < 0 {
            lastMessage = orca_session_last_error(s).map { String(cString: $0) } ?? "plane cut failed"
            return false
        }
        selectedObjectIndex = -1
        refreshObjectList()
        refreshMesh()
        refreshBounds()
        refreshModelInfo()
        lastMessage = String(
            format: "Plane cut n=(%.1f,%.1f,%.1f) → %d object(s)",
            normal.x, normal.y, normal.z, objectCount
        )
        return true
        #else
        return false
        #endif
    }

    // MARK: - wx-parity W2: assembly explode + text plate (box)

    /// Explode objects radially from bed center. factor 0 = collapse to saved layout.
    @discardableResult
    func explodeObjects(factor: Float, spacingMm: Float = 20) -> Bool {
        #if ORCA_LINKED
        guard let s = session, hasModel, objectCount >= 1 else {
            lastMessage = "Explode needs objects on plate"
            return false
        }
        pushUndoSnapshot(label: factor <= 0.001 ? "collapse" : "explode")
        let rc = orca_session_explode_objects(s, factor, spacingMm)
        if rc != 0 {
            lastMessage = orca_session_last_error(s).map { String(cString: $0) } ?? "explode failed"
            return false
        }
        explodeFactor = max(0, factor)
        refreshMesh()
        refreshBounds()
        refreshModelInfo()
        if factor <= 0.001 {
            lastMessage = "Collapsed assembly"
        } else {
            lastMessage = String(format: "Explode ×%.1f (spacing %.0f mm)", factor, spacingMm)
        }
        return true
        #else
        return false
        #endif
    }

    /// Emboss-lite: add a flat box volume named as a text plate (optional dimensions).
    @discardableResult
    func addTextPlate(
        name: String = "Text plate",
        sizeX: Float = 40,
        sizeY: Float = 10,
        sizeZ: Float = 2
    ) -> Bool {
        #if ORCA_LINKED
        guard let s = session else { return false }
        pushUndoSnapshot(label: "add-text-plate")
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = trimmed.isEmpty ? "Text plate" : trimmed
        let rc = label.withCString {
            orca_session_add_box(s, $0, sizeX, sizeY, sizeZ)
        }
        if rc < 0 {
            lastMessage = orca_session_last_error(s).map { String(cString: $0) } ?? "add_box failed"
            return false
        }
        selectedObjectIndex = Int(rc)
        explodeFactor = 0
        refreshObjectList()
        refreshMesh()
        refreshBounds()
        refreshModelInfo()
        hasModel = objectCount > 0
        lastMessage = "Added text plate \"\(label)\" \(String(format: "%.0f×%.0f×%.0f", sizeX, sizeY, sizeZ)) mm"
        return true
        #else
        lastMessage = "Engine not linked"
        return false
        #endif
    }

    // MARK: - W3: preset bundle zip + job history

    /// Documents/OrcaSlicer root
    var dataDirectoryURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return docs.appendingPathComponent("OrcaSlicer", isDirectory: true)
    }

    var userPresetsDirectoryURL: URL {
        dataDirectoryURL.appendingPathComponent("user_presets", isDirectory: true)
    }

    /// Zip Documents/OrcaSlicer/user_presets into a shareable archive (store-only ZIP).
    func exportPresetBundleZip() -> URL? {
        let src = userPresetsDirectoryURL
        let fm = FileManager.default
        try? fm.createDirectory(at: src, withIntermediateDirectories: true)
        // Collect files under user_presets
        guard let enumerator = fm.enumerator(at: src, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            lastMessage = "Cannot read user_presets"
            return nil
        }
        var files: [(relative: String, url: URL)] = []
        for case let url as URL in enumerator {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue {
                let rel = url.path.replacingOccurrences(of: src.path + "/", with: "")
                if rel != url.path {
                    files.append((rel, url))
                } else {
                    files.append((url.lastPathComponent, url))
                }
            }
        }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrcaSlicer_user_presets_\(stamp).zip")
        do {
            if fm.fileExists(atPath: out.path) { try fm.removeItem(at: out) }
            try OrcaZipWriter.writeStoreZip(files: files, to: out)
            lastMessage = files.isEmpty
                ? "Exported empty preset bundle (no user presets yet)"
                : "Exported preset bundle · \(files.count) file(s)"
            return out
        } catch {
            lastMessage = "Zip failed: \(error.localizedDescription)"
            return nil
        }
    }

    static func loadJobHistory() -> [JobHistoryEntry] {
        guard let data = UserDefaults.standard.data(forKey: prefsJobHistoryKey),
              let list = try? JSONDecoder().decode([JobHistoryEntry].self, from: data) else {
            return []
        }
        return list
    }

    func appendJobHistory(host: String, filename: String, hostType: String) {
        let df = ISO8601DateFormatter()
        let entry = JobHistoryEntry(
            host: host,
            filename: filename,
            date: df.string(from: Date()),
            hostType: hostType
        )
        var list = jobHistory
        list.insert(entry, at: 0)
        if list.count > 50 { list = Array(list.prefix(50)) }
        jobHistory = list
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: Self.prefsJobHistoryKey)
        }
    }

    func clearJobHistory() {
        jobHistory = []
        UserDefaults.standard.removeObject(forKey: Self.prefsJobHistoryKey)
    }
}

// MARK: - Minimal store-only ZIP writer (no compression) for preset bundle export

enum OrcaZipWriter {
    static func writeStoreZip(files: [(relative: String, url: URL)], to dest: URL) throws {
        var central: [UInt8] = []
        var local: [UInt8] = []
        var offsets: [UInt32] = []

        for (rel, url) in files {
            let nameData = Array(rel.replacingOccurrences(of: "\\", with: "/").utf8)
            let fileData = try Data(contentsOf: url)
            let crc = crc32(fileData)
            let size = UInt32(fileData.count)
            let localOffset = UInt32(local.count)

            // Local file header
            local += u32(0x04034b50) // signature
            local += u16(20) // version needed
            local += u16(0) // flags
            local += u16(0) // method store
            local += u16(0) // time
            local += u16(0) // date
            local += u32(crc)
            local += u32(size)
            local += u32(size)
            local += u16(UInt16(nameData.count))
            local += u16(0) // extra
            local += nameData
            local += [UInt8](fileData)

            offsets.append(localOffset)

            // Central directory header
            central += u32(0x02014b50)
            central += u16(20) // version made by
            central += u16(20) // version needed
            central += u16(0)
            central += u16(0)
            central += u16(0)
            central += u16(0)
            central += u32(crc)
            central += u32(size)
            central += u32(size)
            central += u16(UInt16(nameData.count))
            central += u16(0)
            central += u16(0) // comment
            central += u16(0) // disk
            central += u16(0) // int attr
            central += u32(0) // ext attr
            central += u32(localOffset)
            central += nameData
        }

        let centralOffset = UInt32(local.count)
        let centralSize = UInt32(central.count)
        var out = local + central
        // End of central directory
        out += u32(0x06054b50)
        out += u16(0)
        out += u16(0)
        out += u16(UInt16(files.count))
        out += u16(UInt16(files.count))
        out += u32(centralSize)
        out += u32(centralOffset)
        out += u16(0)
        try Data(out).write(to: dest)
    }

    private static func u16(_ v: UInt16) -> [UInt8] {
        [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)]
    }
    private static func u32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)]
    }

    /// CRC-32 (ISO 3309 / PNG / ZIP)
    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            let idx = Int((crc ^ UInt32(byte)) & 0xff)
            crc = (crc >> 8) ^ crcTable[idx]
        }
        return crc ^ 0xffff_ffff
    }

    private static let crcTable: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xedb88320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()
}
