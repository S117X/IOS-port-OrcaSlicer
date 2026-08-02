// Bridges SwiftUI to official orca_ios_api (libslic3r).

import Foundation
import Combine

#if canImport(OrcaCAPI)
import OrcaCAPI
#endif

/// Thin ObservableObject around C ABI in `src/ios/orca_slice_c_api.h`.
final class OrcaEngine: ObservableObject {
    @Published var modelName: String?
    @Published var hasModel = false
    @Published var gcodeURL: URL?
    @Published var lastMessage = ""

    private var session: OpaquePointer?

    var version: String {
        #if ORCA_LINKED
        if let c = orca_version_string() {
            return String(cString: c)
        }
        #endif
        return "OrcaSlicer iOS host (link orca_ios_api + libslic3r to enable slice)"
    }

    init() {
        #if ORCA_LINKED
        let res = Bundle.main.resourcePath
        session = orca_session_create(res)
        if session == nil {
            lastMessage = "orca_session_create failed"
        }
        #else
        lastMessage = "Build with ORCA_LINKED + static libs from cmake -DORCA_IOS_API=ON"
        #endif
    }

    deinit {
        #if ORCA_LINKED
        if let s = session { orca_session_destroy(s) }
        #endif
    }

    func loadModel(url: URL) -> String {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        // Copy into sandbox tmp (libslic3r needs a stable path)
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
            return lastMessage
        }
        modelName = url.lastPathComponent
        hasModel = true
        lastMessage = "Loaded \(url.lastPathComponent) via Model::read_from_file"
        return lastMessage
        #else
        modelName = url.lastPathComponent + " (path only — engine not linked)"
        hasModel = false
        lastMessage = "Engine not linked. Open PORT_IOS.md / scripts/build_ios.sh"
        return lastMessage
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

    func slice() async -> String {
        #if ORCA_LINKED
        guard let s = session else { return "No session" }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("plate_1.gcode")
        let rc = await Task.detached {
            out.path.withCString { orca_session_slice_to_gcode(s, $0) }
        }.value
        if rc != 0 {
            let err = orca_session_last_error(s).map { String(cString: $0) } ?? "slice failed"
            return "slice rc=\(rc): \(err)"
        }
        await MainActor.run { self.gcodeURL = out }
        return "G-code written: \(out.lastPathComponent) (Print::export_gcode)"
        #else
        return "Link orca_ios_api + libslic3r (cmake ORCA_IOS_API=ON) to slice"
        #endif
    }
}
