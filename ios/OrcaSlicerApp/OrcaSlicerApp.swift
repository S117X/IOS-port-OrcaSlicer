// OrcaSlicer iOS shell — prepare + preview with SceneKit orbit and real mesh.
// Engine: official libslic3r via orca_ios_api (AGPL-3.0).

import SwiftUI
import UniformTypeIdentifiers
import SceneKit
#if canImport(UIKit)
import UIKit
#endif

@main
struct OrcaSlicerApp: App {
    var body: some Scene {
        WindowGroup {
            OrcaRootView()
                .preferredColorScheme(.dark)
        }
    }
}

// MARK: - Theme from StateColor.cpp dark map

private enum OrcaTheme {
    static let bg = Color(red: 0x2D / 255.0, green: 0x2D / 255.0, blue: 0x31 / 255.0)
    static let panel = Color(red: 0x36 / 255.0, green: 0x36 / 255.0, blue: 0x3C / 255.0)
    static let elevated = Color(red: 0x3E / 255.0, green: 0x3E / 255.0, blue: 0x45 / 255.0)
    static let field = Color(red: 0x2D / 255.0, green: 0x2D / 255.0, blue: 0x31 / 255.0)
    static let accent = Color(red: 0x00 / 255.0, green: 0x96 / 255.0, blue: 0x88 / 255.0)
    static let accentHover = Color(red: 0x26 / 255.0, green: 0xA6 / 255.0, blue: 0x9A / 255.0)
    static let accentDim = Color(red: 0x00 / 255.0, green: 0x67 / 255.0, blue: 0x5B / 255.0)
    static let muted = Color(red: 0xB3 / 255.0, green: 0xB3 / 255.0, blue: 0xB5 / 255.0)
    static let border = Color(red: 0x4A / 255.0, green: 0x4A / 255.0, blue: 0x51 / 255.0)
    static let success = Color(red: 0x00 / 255.0, green: 0x96 / 255.0, blue: 0x88 / 255.0)
    static let danger = Color(red: 0xBB / 255.0, green: 0x2A / 255.0, blue: 0x3A / 255.0)
    static let text = Color(red: 0xEF / 255.0, green: 0xEF / 255.0, blue: 0xF0 / 255.0)
}

// MARK: - Root

struct OrcaRootView: View {
    @StateObject private var engine = OrcaEngine()
    @State private var showImporter = false
    @State private var importAppend = false
    @State private var showProcess = false
    @State private var projectURL: URL?
    @State private var layerHeight = "0.20"
    @State private var infill = "15"
    @State private var walls = "2"
    @State private var status = ""
    @State private var isSlicing = false
    @State private var mainTab: MainTab = .prepare
    /// Prepare: pan on plate moves selection (disables camera orbit while on)
    @State private var moveMode = false

    enum MainTab: String, CaseIterable {
        case prepare = "Prepare"
        case preview = "Preview"
        case device = "Device"
    }

    var body: some View {
        GeometryReader { geo in
            let bottomPad = max(geo.safeAreaInsets.bottom, 8)
            ZStack {
                OrcaTheme.bg.ignoresSafeArea()
                VStack(spacing: 0) {
                    headerBar
                    tabBar
                    ZStack {
                        // 3D stage: real mesh + orbit; Preview shows G-code paths
                        PlateSceneView(
                            mesh: engine.mesh,
                            gcodeNode: engine.gcodePathNode,
                            showGCode: mainTab == .preview && engine.gcodePathNode != nil,
                            bedSize: engine.bedSize,
                            bedTexturePath: engine.bedTexturePath,
                            accent: UIColor(red: 0, green: 150 / 255, blue: 136 / 255, alpha: 1),
                            moveMode: moveMode && mainTab == .prepare && engine.hasModel,
                            onDragCommit: { dx, dy in
                                engine.translate(dx: dx, dy: dy)
                                status = engine.lastMessage
                            },
                            onDragLive: { dx, dy in
                                status = String(format: "Drag Δ%.1f, %.1f mm", dx, dy)
                            }
                        )
                        .overlay(alignment: .topLeading) {
                            hintOverlay
                                .padding(12)
                        }
                        .overlay(alignment: .topTrailing) {
                            if moveMode && mainTab == .prepare && engine.hasModel {
                                Text("Drag on plate · orbit off")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(OrcaTheme.accent)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(OrcaTheme.panel.opacity(0.95))
                                    .clipShape(Capsule())
                                    .padding(12)
                            }
                        }
                        .overlay {
                            if mainTab == .device {
                                devicePlaceholder
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if mainTab == .preview, engine.gcodeGeometry != nil {
                        layerScrubber
                    }
                    controlsPanel(bottomInset: bottomPad)
                }
            }
        }
        .sheet(isPresented: $showProcess) {
            processSheet
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .preferredColorScheme(.dark)
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: modelTypes,
            allowsMultipleSelection: false
        ) { handleImport($0) }
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            OrcaLogoMark()
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("OrcaSlicer")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(OrcaTheme.text)
                HStack(spacing: 6) {
                    Circle()
                        .fill(engine.isLinked ? OrcaTheme.success : OrcaTheme.danger)
                        .frame(width: 7, height: 7)
                    Text(engine.isLinked ? "Ready" : "Engine offline")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(engine.isLinked ? OrcaTheme.success : OrcaTheme.danger)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            Spacer(minLength: 8)
            Button { showProcess = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(OrcaTheme.text)
                    .frame(width: 44, height: 44)
                    .background(OrcaTheme.elevated)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(OrcaTheme.panel)
        .overlay(alignment: .bottom) {
            Rectangle().fill(OrcaTheme.border).frame(height: 1)
        }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(MainTab.allCases, id: \.self) { tab in
                Button {
                    mainTab = tab
                    if tab != .prepare { moveMode = false }
                    if tab == .preview && engine.gcodeURL == nil {
                        status = "Slice to preview toolpaths."
                    }
                } label: {
                    Text(tab.rawValue)
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .foregroundStyle(mainTab == tab ? OrcaTheme.accent : OrcaTheme.muted)
                        .background(mainTab == tab ? OrcaTheme.accent.opacity(0.12) : Color.clear)
                }
                .buttonStyle(.plain)
            }
        }
        .background(OrcaTheme.panel)
    }

    private var hintOverlay: some View {
        // Model / bed facts only — no tutorial tip copy
        Group {
            if engine.hasModel || !engine.boundsText.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    if let name = engine.modelName {
                        Text(name)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                    }
                    if !engine.boundsText.isEmpty {
                        Text(engine.boundsText)
                            .font(.system(size: 11, design: .monospaced))
                    }
                    Text(String(format: "%.0f × %.0f × %.0f mm", engine.bedSize.x, engine.bedSize.y, engine.bedHeight))
                        .font(.system(size: 11, design: .monospaced))
                    if !engine.selectedPrinter.isEmpty {
                        Text(engine.selectedPrinter)
                            .font(.system(size: 10, design: .monospaced))
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(OrcaTheme.muted)
                .padding(10)
                .background(OrcaTheme.panel.opacity(0.92))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    enum PrinterHostType: String, CaseIterable, Identifiable {
        case moonraker = "Moonraker"
        case octoprint = "OctoPrint"
        case prusalink = "PrusaLink"
        var id: String { rawValue }
    }

    @State private var hostType: PrinterHostType = .moonraker
    @State private var printerHost = "http://192.168.1.100"
    @State private var octoApiKey = ""
    @State private var printerStatus = "Not connected"
    @State private var isConnecting = false
    @State private var isJobBusy = false
    @State private var lastUploadedFilename: String?
    @State private var jobState = ""
    @State private var jobProgress: Double = 0
    @State private var jobMessage = ""
    @State private var statusPollTask: Task<Void, Never>?
    @State private var nozzleTemp = "210"
    @State private var bedTemp = "60"

    private var devicePlaceholder: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Image(systemName: "printer.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(OrcaTheme.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Device")
                            .font(.headline)
                            .foregroundStyle(OrcaTheme.text)
                        Text(printerStatus)
                            .font(.subheadline)
                            .foregroundStyle(OrcaTheme.muted)
                    }
                    Spacer()
                }

                Picker("Host type", selection: $hostType) {
                    ForEach(PrinterHostType.allCases) { t in
                        Text(t.rawValue).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: hostType) { _ in
                    printerStatus = "Not connected"
                    jobState = ""
                    jobMessage = ""
                    lastUploadedFilename = nil
                    statusPollTask?.cancel()
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(
                        hostType == .moonraker ? "Moonraker / Klipper host"
                            : hostType == .prusalink ? "PrusaLink host"
                            : "OctoPrint host"
                    )
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(OrcaTheme.muted)
                    TextField(
                        hostType == .moonraker ? "http://printer.local"
                            : hostType == .prusalink ? "http://prusa.local"
                            : "http://octopi.local",
                        text: $printerHost
                    )
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .font(.system(size: 15, design: .monospaced))
                        .foregroundStyle(OrcaTheme.text)
                        .padding(12)
                        .background(OrcaTheme.elevated)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    if hostType == .octoprint || hostType == .prusalink {
                        SecureField(
                            hostType == .prusalink ? "API key (PrusaLink)" : "API key (OctoPrint)",
                            text: $octoApiKey
                        )
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundStyle(OrcaTheme.text)
                            .padding(12)
                            .background(OrcaTheme.elevated)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        Task { await connectPrinterHost() }
                    } label: {
                        HStack {
                            if isConnecting { ProgressView().tint(.white) }
                            Text(isConnecting ? "Connecting…" : "Connect")
                                .fontWeight(.bold)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(OrcaTheme.accent)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .disabled(isConnecting)
                    .buttonStyle(.plain)

                    Button {
                        Task { await uploadGCodeToHost() }
                    } label: {
                        Text("Upload G-code")
                            .fontWeight(.bold)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(engine.gcodeURL != nil ? OrcaTheme.elevated : OrcaTheme.elevated.opacity(0.5))
                            .foregroundStyle(engine.gcodeURL != nil ? OrcaTheme.accent : OrcaTheme.muted)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .disabled(engine.gcodeURL == nil || isConnecting)
                    .buttonStyle(.plain)
                }

                // Start / status / cancel
                VStack(alignment: .leading, spacing: 10) {
                    Text("Job")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(OrcaTheme.muted)
                    if !jobState.isEmpty {
                        HStack {
                            Text(jobState)
                                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                                .foregroundStyle(OrcaTheme.text)
                            Spacer()
                            Text(String(format: "%.0f%%", jobProgress * 100))
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(OrcaTheme.accent)
                        }
                        ProgressView(value: min(max(jobProgress, 0), 1))
                            .tint(OrcaTheme.accent)
                        if !jobMessage.isEmpty {
                            Text(jobMessage)
                                .font(.system(size: 11))
                                .foregroundStyle(OrcaTheme.muted)
                        }
                    } else if let name = lastUploadedFilename {
                        Text("Ready: \(name)")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(OrcaTheme.muted)
                    }
                    HStack(spacing: 10) {
                        Button {
                            Task { await startHostPrint() }
                        } label: {
                            HStack {
                                if isJobBusy { ProgressView().tint(.white) }
                                Text("Start print")
                                    .fontWeight(.bold)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(canStartPrint ? OrcaTheme.accent : OrcaTheme.elevated.opacity(0.5))
                            .foregroundStyle(canStartPrint ? .white : OrcaTheme.muted)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .disabled(!canStartPrint || isJobBusy)
                        .buttonStyle(.plain)

                        Button {
                            Task { await cancelHostPrint() }
                        } label: {
                            Text("Cancel")
                                .fontWeight(.bold)
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                                .background(OrcaTheme.danger.opacity(0.2))
                                .foregroundStyle(OrcaTheme.danger)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .disabled(isJobBusy)
                        .buttonStyle(.plain)

                        Button {
                            Task { await refreshHostJobStatus() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 16, weight: .semibold))
                                .frame(width: 44, height: 44)
                                .background(OrcaTheme.elevated)
                                .foregroundStyle(OrcaTheme.accent)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Print temps")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(OrcaTheme.muted)
                    HStack(spacing: 10) {
                        tempField("Nozzle °C", text: $nozzleTemp) {
                            engine.setOption("nozzle_temperature", value: nozzleTemp)
                            engine.setOption("nozzle_temperature_initial_layer", value: nozzleTemp)
                            status = engine.lastMessage
                        }
                        tempField("Bed °C", text: $bedTemp) {
                            engine.setOption("bed_temperature", value: bedTemp)
                            engine.setOption("bed_temperature_initial_layer", value: bedTemp)
                            status = engine.lastMessage
                        }
                    }
                }


            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OrcaTheme.bg.opacity(0.96))
    }

    private var canStartPrint: Bool {
        lastUploadedFilename != nil || engine.gcodeURL != nil
    }

    private func tempField(_ title: String, text: Binding<String>, apply: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(OrcaTheme.muted)
            HStack {
                TextField(title, text: text)
                    .keyboardType(.numberPad)
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundStyle(OrcaTheme.text)
                Button("Set", action: apply)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(OrcaTheme.accent)
            }
            .padding(10)
            .background(OrcaTheme.elevated)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .frame(maxWidth: .infinity)
    }

    private func printerBaseURL() -> URL? {
        URL(string: printerHost.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func moonrakerBaseURL() -> URL? { printerBaseURL() }

    private func connectPrinterHost() async {
        switch hostType {
        case .moonraker: await connectMoonraker()
        case .octoprint, .prusalink: await connectOctoPrint() // PrusaLink speaks OctoPrint-compatible API
        }
    }

    private func uploadGCodeToHost() async {
        switch hostType {
        case .moonraker: await uploadGCodeToMoonraker()
        case .octoprint, .prusalink: await uploadGCodeToOctoPrint()
        }
    }

    private func startHostPrint() async {
        switch hostType {
        case .moonraker: await startMoonrakerPrint()
        case .octoprint, .prusalink: await startOctoPrint()
        }
    }

    private func cancelHostPrint() async {
        switch hostType {
        case .moonraker: await cancelMoonrakerPrint()
        case .octoprint, .prusalink: await cancelOctoPrint()
        }
    }

    private func refreshHostJobStatus() async {
        switch hostType {
        case .moonraker: await refreshMoonrakerJobStatus()
        case .octoprint, .prusalink: await refreshOctoPrintJobStatus()
        }
    }

    private func octoHeaders(for req: inout URLRequest) {
        let key = octoApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            req.setValue(key, forHTTPHeaderField: "X-Api-Key")
        }
    }

    private func connectMoonraker() async {
        isConnecting = true
        defer { isConnecting = false }
        guard let base = printerBaseURL() else {
            printerStatus = "Invalid URL"
            return
        }
        let info = base.appendingPathComponent("server/info")
        var req = URLRequest(url: info)
        req.timeoutInterval = 5
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let result = json["result"] as? [String: Any] {
                    let ver = result["klippy_state"] as? String
                        ?? result["moonraker_version"] as? String
                        ?? "ok"
                    printerStatus = "Moonraker · \(ver)"
                } else {
                    printerStatus = "Moonraker connected (HTTP \(code))"
                }
            } else {
                printerStatus = "HTTP \(code) from server.info"
            }
        } catch {
            printerStatus = "Unreachable: \(error.localizedDescription)"
        }
    }

    /// GET /api/version — OctoPrint handshake
    private func connectOctoPrint() async {
        isConnecting = true
        defer { isConnecting = false }
        guard let base = printerBaseURL() else {
            printerStatus = "Invalid URL"
            return
        }
        var req = URLRequest(url: base.appendingPathComponent("api/version"))
        req.timeoutInterval = 5
        octoHeaders(for: &req)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let ver = (json["server"] as? String)
                        ?? (json["api"] as? String)
                        ?? "ok"
                    printerStatus = "OctoPrint · \(ver)"
                } else {
                    printerStatus = "OctoPrint connected"
                }
            } else if code == 403 {
                printerStatus = "OctoPrint 403 — check API key"
            } else {
                printerStatus = "OctoPrint HTTP \(code)"
            }
        } catch {
            printerStatus = "Unreachable: \(error.localizedDescription)"
        }
    }

    private func uploadGCodeToMoonraker() async {
        guard let gcode = engine.gcodeURL else {
            printerStatus = "Slice first to produce G-code"
            return
        }
        guard let base = moonrakerBaseURL() else {
            printerStatus = "Invalid host URL"
            return
        }
        isConnecting = true
        defer { isConnecting = false }
        // Moonraker multipart upload: POST /server/files/upload
        let uploadURL = base.appendingPathComponent("server/files/upload")
        let boundary = "OrcaBoundary\(UUID().uuidString)"
        var req = URLRequest(url: uploadURL)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 60
        guard let fileData = try? Data(contentsOf: gcode) else {
            printerStatus = "Could not read G-code file"
            return
        }
        var body = Data()
        let filename = gcode.lastPathComponent
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"root\"\r\n\r\n".data(using: .utf8)!)
        body.append("gcodes\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if (200...299).contains(code) {
                // Prefer path returned by Moonraker; fall back to filename in gcodes/
                var remoteName = filename
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let result = json["result"] as? [String: Any],
                   let item = result["item"] as? [String: Any],
                   let path = item["path"] as? String, !path.isEmpty {
                    remoteName = path
                }
                lastUploadedFilename = remoteName
                printerStatus = "Uploaded \(remoteName)"
                jobMessage = "Upload OK — Start print when ready"
            } else {
                printerStatus = "Upload failed HTTP \(code)"
            }
        } catch {
            printerStatus = "Upload error: \(error.localizedDescription)"
        }
    }

    /// POST /printer/print/start?filename=
    private func startMoonrakerPrint() async {
        guard let base = moonrakerBaseURL() else {
            printerStatus = "Invalid host URL"
            return
        }
        var filename = lastUploadedFilename
        if filename == nil, let gcode = engine.gcodeURL {
            // Auto-upload then start
            await uploadGCodeToMoonraker()
            filename = lastUploadedFilename ?? gcode.lastPathComponent
        }
        guard let filename, !filename.isEmpty else {
            printerStatus = "Upload G-code first"
            return
        }
        isJobBusy = true
        defer { isJobBusy = false }
        var comps = URLComponents(
            url: base.appendingPathComponent("printer/print/start"),
            resolvingAgainstBaseURL: false
        )
        comps?.queryItems = [URLQueryItem(name: "filename", value: filename)]
        guard let url = comps?.url else {
            printerStatus = "Bad start URL"
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if (200...299).contains(code) {
                jobState = "printing"
                jobProgress = 0
                jobMessage = "Started \(filename)"
                printerStatus = "Print started · \(filename)"
                startJobStatusPolling()
            } else {
                let errBody = String(data: data, encoding: .utf8) ?? ""
                printerStatus = "Start failed HTTP \(code)"
                jobMessage = errBody.isEmpty ? "HTTP \(code)" : String(errBody.prefix(160))
            }
        } catch {
            printerStatus = "Start error: \(error.localizedDescription)"
        }
    }

    /// POST /printer/print/cancel
    private func cancelMoonrakerPrint() async {
        guard let base = moonrakerBaseURL() else {
            printerStatus = "Invalid host URL"
            return
        }
        isJobBusy = true
        defer { isJobBusy = false }
        var req = URLRequest(url: base.appendingPathComponent("printer/print/cancel"))
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if (200...299).contains(code) {
                jobState = "cancelled"
                jobMessage = "Print cancelled"
                printerStatus = "Print cancelled"
                statusPollTask?.cancel()
                statusPollTask = nil
            } else {
                printerStatus = "Cancel failed HTTP \(code)"
            }
        } catch {
            printerStatus = "Cancel error: \(error.localizedDescription)"
        }
    }

    /// GET /printer/objects/query?print_stats&display_status
    private func refreshMoonrakerJobStatus() async {
        guard let base = moonrakerBaseURL() else { return }
        var comps = URLComponents(
            url: base.appendingPathComponent("printer/objects/query"),
            resolvingAgainstBaseURL: false
        )
        // Moonraker accepts object names as query keys
        comps?.queryItems = [
            URLQueryItem(name: "print_stats", value: nil),
            URLQueryItem(name: "display_status", value: nil),
        ]
        guard let url = comps?.url else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(code),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = json["result"] as? [String: Any],
                  let statusObj = result["status"] as? [String: Any]
            else {
                if code != 0 { jobMessage = "Status HTTP \(code)" }
                return
            }
            if let ps = statusObj["print_stats"] as? [String: Any] {
                let state = (ps["state"] as? String) ?? ""
                let fn = (ps["filename"] as? String) ?? ""
                if !state.isEmpty { jobState = state }
                if !fn.isEmpty { jobMessage = fn }
            }
            if let ds = statusObj["display_status"] as? [String: Any] {
                if let p = ds["progress"] as? Double {
                    jobProgress = p
                } else if let p = ds["progress"] as? Int {
                    jobProgress = Double(p)
                }
                if let msg = ds["message"] as? String, !msg.isEmpty {
                    jobMessage = msg
                }
            }
            if !jobState.isEmpty {
                printerStatus = "Job · \(jobState) · \(String(format: "%.0f%%", jobProgress * 100))"
            }
        } catch {
            jobMessage = error.localizedDescription
        }
    }

    private func startJobStatusPolling() {
        statusPollTask?.cancel()
        statusPollTask = Task {
            for _ in 0..<120 { // ~10 min at 5s
                if Task.isCancelled { return }
                await refreshHostJobStatus()
                let s = jobState.lowercased()
                let done = [
                    "complete", "completed", "cancelled", "canceled",
                    "error", "standby", "ready", "operational", "offline"
                ].contains(s)
                if done { return }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    // MARK: OctoPrint REST

    /// POST /api/files/local multipart upload
    private func uploadGCodeToOctoPrint() async {
        guard let gcode = engine.gcodeURL else {
            printerStatus = "Slice first to produce G-code"
            return
        }
        guard let base = printerBaseURL() else {
            printerStatus = "Invalid host URL"
            return
        }
        isConnecting = true
        defer { isConnecting = false }
        let uploadURL = base.appendingPathComponent("api/files/local")
        let boundary = "OrcaBoundary\(UUID().uuidString)"
        var req = URLRequest(url: uploadURL)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        octoHeaders(for: &req)
        req.timeoutInterval = 90
        guard let fileData = try? Data(contentsOf: gcode) else {
            printerStatus = "Could not read G-code file"
            return
        }
        let filename = gcode.lastPathComponent
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append(
            "Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n"
                .data(using: .utf8)!
        )
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"select\"\r\n\r\n".data(using: .utf8)!)
        body.append("true\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if (200...299).contains(code) {
                var remoteName = filename
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let files = json["files"] as? [String: Any],
                   let local = files["local"] as? [String: Any],
                   let name = local["name"] as? String {
                    remoteName = name
                }
                lastUploadedFilename = remoteName
                printerStatus = "OctoPrint uploaded \(remoteName)"
                jobMessage = "Upload OK — Start print when ready"
            } else if code == 403 {
                printerStatus = "Upload 403 — check API key"
            } else {
                printerStatus = "OctoPrint upload HTTP \(code)"
            }
        } catch {
            printerStatus = "Upload error: \(error.localizedDescription)"
        }
    }

    /// POST /api/job { "command": "start" } — file must be selected
    private func startOctoPrint() async {
        guard let base = printerBaseURL() else {
            printerStatus = "Invalid host URL"
            return
        }
        if lastUploadedFilename == nil, engine.gcodeURL != nil {
            await uploadGCodeToOctoPrint()
        }
        guard lastUploadedFilename != nil || engine.gcodeURL != nil else {
            printerStatus = "Upload G-code first"
            return
        }
        isJobBusy = true
        defer { isJobBusy = false }
        var req = URLRequest(url: base.appendingPathComponent("api/job"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        octoHeaders(for: &req)
        req.timeoutInterval = 15
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["command": "start"])
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if (200...299).contains(code) {
                jobState = "Printing"
                jobProgress = 0
                jobMessage = lastUploadedFilename ?? "job"
                printerStatus = "OctoPrint print started"
                startJobStatusPolling()
            } else {
                let errBody = String(data: data, encoding: .utf8) ?? ""
                printerStatus = "Start failed HTTP \(code)"
                jobMessage = errBody.isEmpty ? "HTTP \(code)" : String(errBody.prefix(160))
            }
        } catch {
            printerStatus = "Start error: \(error.localizedDescription)"
        }
    }

    /// POST /api/job { "command": "cancel" }
    private func cancelOctoPrint() async {
        guard let base = printerBaseURL() else {
            printerStatus = "Invalid host URL"
            return
        }
        isJobBusy = true
        defer { isJobBusy = false }
        var req = URLRequest(url: base.appendingPathComponent("api/job"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        octoHeaders(for: &req)
        req.timeoutInterval = 10
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["command": "cancel"])
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if (200...299).contains(code) {
                jobState = "cancelled"
                jobMessage = "Print cancelled"
                printerStatus = "OctoPrint cancelled"
                statusPollTask?.cancel()
                statusPollTask = nil
            } else {
                printerStatus = "Cancel failed HTTP \(code)"
            }
        } catch {
            printerStatus = "Cancel error: \(error.localizedDescription)"
        }
    }

    /// GET /api/job
    private func refreshOctoPrintJobStatus() async {
        guard let base = printerBaseURL() else { return }
        var req = URLRequest(url: base.appendingPathComponent("api/job"))
        req.timeoutInterval = 8
        octoHeaders(for: &req)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(code),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                if code != 0 { jobMessage = "Status HTTP \(code)" }
                return
            }
            if let state = json["state"] as? String, !state.isEmpty {
                jobState = state
            }
            if let progress = json["progress"] as? [String: Any] {
                if let completion = progress["completion"] as? Double {
                    jobProgress = completion / 100.0
                } else if let completion = progress["completion"] as? Int {
                    jobProgress = Double(completion) / 100.0
                }
            }
            if let job = json["job"] as? [String: Any],
               let file = job["file"] as? [String: Any],
               let name = file["name"] as? String {
                jobMessage = name
            }
            if !jobState.isEmpty {
                printerStatus = "Octo · \(jobState) · \(String(format: "%.0f%%", jobProgress * 100))"
            }
        } catch {
            jobMessage = error.localizedDescription
        }
    }

    private func controlsPanel(bottomInset: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !status.isEmpty {
                Text(status)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(OrcaTheme.muted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                actionButton(title: "Open", systemImage: "folder.fill") {
                    importAppend = false
                    showImporter = true
                }
                actionButton(title: "Add", systemImage: "plus.rectangle.on.folder") {
                    importAppend = true
                    showImporter = true
                }
                actionButton(title: "Process", systemImage: "slider.horizontal.3") {
                    showProcess = true
                }
            }

            if mainTab == .prepare {
                plateTabsRow
            }
            if engine.hasModel && mainTab == .prepare {
                objectPickerRow
                plateToolsRow
            }

            Button(action: sliceNow) {
                HStack(spacing: 10) {
                    if isSlicing {
                        ProgressView().controlSize(.regular).tint(.white)
                        Text("\(engine.slicePercent)% · \(engine.slicePhase.isEmpty ? "Slicing…" : engine.slicePhase)")
                            .font(.system(size: 15, weight: .bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    } else {
                        Image(systemName: "square.3.layers.3d.down.right")
                            .font(.system(size: 17, weight: .bold))
                        Text("Slice plate")
                            .font(.system(size: 17, weight: .bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(engine.hasModel && !isSlicing ? OrcaTheme.accent : OrcaTheme.accentDim.opacity(0.55))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!engine.hasModel || isSlicing)

            if !engine.lastSliceStatsText.isEmpty {
                Text(engine.lastSliceStatsText)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(OrcaTheme.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let gcode = engine.gcodeURL {
                HStack(spacing: 10) {
                    Button {
                        mainTab = .preview
                        status = ""
                    } label: {
                        Label("Preview", systemImage: "eye")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                            .background(OrcaTheme.accent.opacity(0.18))
                            .foregroundStyle(OrcaTheme.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    ShareLink(item: gcode) {
                        Label("G-code", systemImage: "square.and.arrow.up")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                            .background(OrcaTheme.success.opacity(0.18))
                            .foregroundStyle(OrcaTheme.success)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            }

            if engine.hasModel {
                HStack(spacing: 10) {
                    Button {
                        if let url = engine.saveProject3MF() {
                            projectURL = url
                            status = engine.lastMessage
                        } else {
                            status = engine.lastMessage
                        }
                    } label: {
                        Label("Save 3MF", systemImage: "doc.badge.arrow.up")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 42)
                            .background(OrcaTheme.elevated)
                            .foregroundStyle(OrcaTheme.text)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    if let projectURL {
                        ShareLink(item: projectURL) {
                            Label("Share project", systemImage: "square.and.arrow.up")
                                .font(.system(size: 13, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .frame(height: 42)
                                .background(OrcaTheme.accent.opacity(0.18))
                                .foregroundStyle(OrcaTheme.accent)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, bottomInset + 10)
        .background(OrcaTheme.panel)
        .overlay(alignment: .top) {
            Rectangle().fill(OrcaTheme.border).frame(height: 1)
        }
    }

    private func actionButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(OrcaTheme.elevated)
            .foregroundStyle(OrcaTheme.text)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var objectPickerRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                objectChip(title: "All", selected: engine.selectedObjectIndex < 0) {
                    engine.selectedObjectIndex = -1
                }
                ForEach(Array(engine.objectNames.enumerated()), id: \.offset) { i, name in
                    objectChip(title: name, selected: engine.selectedObjectIndex == i) {
                        engine.selectedObjectIndex = i
                    }
                }
                toolChip("Duplicate", "plus.square.on.square") {
                    engine.duplicateSelected(); status = engine.lastMessage
                }
                toolChip("Delete", "trash") {
                    engine.deleteSelected(); status = engine.lastMessage
                }
                toolChip("Clear", "xmark.rectangle") {
                    engine.clearPlate(); status = engine.lastMessage
                }
            }
        }
    }

    private func objectChip(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(selected ? OrcaTheme.accent.opacity(0.25) : OrcaTheme.elevated)
                .foregroundStyle(selected ? OrcaTheme.accent : OrcaTheme.text)
                .clipShape(Capsule())
                .overlay(
                    Capsule().stroke(selected ? OrcaTheme.accent : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private var plateTabsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(0..<engine.plateCount, id: \.self) { i in
                    Button {
                        engine.selectPlate(i)
                        status = engine.lastMessage
                        moveMode = false
                    } label: {
                        Text("Plate \(i + 1)")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                engine.currentPlateIndex == i
                                    ? OrcaTheme.accent.opacity(0.25)
                                    : OrcaTheme.elevated
                            )
                            .foregroundStyle(
                                engine.currentPlateIndex == i ? OrcaTheme.accent : OrcaTheme.text
                            )
                            .clipShape(Capsule())
                            .overlay(
                                Capsule().stroke(
                                    engine.currentPlateIndex == i ? OrcaTheme.accent : Color.clear,
                                    lineWidth: 1
                                )
                            )
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    engine.addPlate()
                    status = engine.lastMessage
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                        .padding(8)
                        .background(OrcaTheme.elevated)
                        .foregroundStyle(OrcaTheme.accent)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                if engine.plateCount > 1 {
                    Button {
                        engine.removeCurrentPlate()
                        status = engine.lastMessage
                    } label: {
                        Image(systemName: "minus")
                            .font(.system(size: 12, weight: .bold))
                            .padding(8)
                            .background(OrcaTheme.elevated)
                            .foregroundStyle(OrcaTheme.danger)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var plateToolsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                toolChip(
                    "Drag",
                    "hand.draw",
                    selected: moveMode
                ) {
                    moveMode.toggle()
                    status = moveMode
                        ? "Move mode: drag on plate (orbit off)"
                        : "Orbit camera"
                }
                toolChip("Center", "scope") { engine.centerOnBed(); status = engine.lastMessage }
                toolChip("Arrange", "square.grid.2x2") { engine.arrange(); status = engine.lastMessage }
                toolChip("Orient", "arrow.up.and.down.and.arrow.left.and.right") {
                    engine.autoOrient(); status = engine.lastMessage
                }
                toolChip("Fit bed", "arrow.down.right.and.arrow.up.left") {
                    engine.scaleToFit(); status = engine.lastMessage
                }
                toolChip("↺ Z", "rotate.left") { engine.rotateZ(degrees: -45); status = engine.lastMessage }
                toolChip("↻ Z", "rotate.right") { engine.rotateZ(degrees: 45); status = engine.lastMessage }
                toolChip("↺ X", "rotate.3d") { engine.rotate(axis: 0, degrees: -45); status = engine.lastMessage }
                toolChip("↻ Y", "rotate.3d") { engine.rotate(axis: 1, degrees: 45); status = engine.lastMessage }
                toolChip("Mirror X", "arrow.left.and.right.righttriangle.left.righttriangle.right") {
                    engine.mirror(axis: 0); status = engine.lastMessage
                }
                toolChip("Mirror Y", "arrow.up.and.down.righttriangle.up.righttriangle.down") {
                    engine.mirror(axis: 1); status = engine.lastMessage
                }
                toolChip("×0.5", "minus.magnifyingglass") { engine.scale(factor: 0.5); status = engine.lastMessage }
                toolChip("×2", "plus.magnifyingglass") { engine.scale(factor: 2); status = engine.lastMessage }
                toolChip("←", "arrow.left") { engine.translate(dx: -10, dy: 0); status = engine.lastMessage }
                toolChip("→", "arrow.right") { engine.translate(dx: 10, dy: 0); status = engine.lastMessage }
                toolChip("↑", "arrow.up") { engine.translate(dx: 0, dy: 10); status = engine.lastMessage }
                toolChip("↓", "arrow.down") { engine.translate(dx: 0, dy: -10); status = engine.lastMessage }
            }
        }
    }

    private func toolChip(
        _ title: String,
        _ systemImage: String,
        selected: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(selected ? OrcaTheme.accent.opacity(0.25) : OrcaTheme.elevated)
            .foregroundStyle(selected ? OrcaTheme.accent : OrcaTheme.text)
            .clipShape(Capsule())
            .overlay(
                Capsule().stroke(selected ? OrcaTheme.accent : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var layerScrubber: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Layer Z")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(OrcaTheme.muted)
                Spacer()
                Text(String(format: "%.2f / %.2f mm", engine.previewMaxZ, engine.gcodeZMax))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(OrcaTheme.accent)
            }
            Slider(
                value: Binding(
                    get: { Double(engine.previewMaxZ) },
                    set: { v in
                        engine.previewMaxZ = Float(v)
                        engine.applyPreviewLayer()
                    }
                ),
                in: Double(engine.gcodeZMin)...Double(max(engine.gcodeZMax, engine.gcodeZMin + 0.05))
            )
            .tint(OrcaTheme.accent)

            // Feature-type toggles (G5) — filter ;TYPE: groups + travel moves
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    featureToggle("Wall", isOn: $engine.previewShowWall)
                    featureToggle("Infill", isOn: $engine.previewShowInfill)
                    featureToggle("Support", isOn: $engine.previewShowSupport)
                    featureToggle("Travel", isOn: $engine.previewShowTravel)
                    featureToggle("Other", isOn: $engine.previewShowOther)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(OrcaTheme.panel)
        .overlay(alignment: .top) {
            Rectangle().fill(OrcaTheme.border).frame(height: 1)
        }
    }

    private func featureToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
            engine.applyPreviewLayer()
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(isOn.wrappedValue ? OrcaTheme.accent.opacity(0.28) : OrcaTheme.elevated)
                .foregroundStyle(isOn.wrappedValue ? OrcaTheme.accent : OrcaTheme.muted)
                .clipShape(Capsule())
                .overlay(
                    Capsule().stroke(isOn.wrappedValue ? OrcaTheme.accent : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    @State private var topShells = "3"
    @State private var bottomShells = "3"
    @State private var supportOn = false
    @State private var brimType = "auto_brim"
    @State private var brimWidth = "5"
    @State private var supportType = "normal(auto)"
    @State private var wallGenerator = "arachne"
    @State private var seamPosition = "aligned"
    @State private var ironingType = "no ironing"
    @State private var infillPattern = "grid"
    @State private var outerWallSpeed = "60"
    @State private var sparseSpeed = "100"
    @State private var filamentDiameter = "1.75"
    @State private var printerSearch = ""
    @State private var processSearch = ""
    @State private var filamentSearch = ""
    @State private var vendorFilter = ""
    @State private var showPrinterPicker = false
    @State private var showProcessPicker = false
    @State private var showFilamentPicker = false
    @State private var filamentSlotForPicker = 0
    @State private var showAllSettings = false
    @State private var userProcessName = ""

    private var processSheet: some View {
        NavigationStack {
            List {
                Section {
                    if engine.presetsLoading {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Installing system profiles…")
                                .foregroundStyle(OrcaTheme.muted)
                        }
                        .listRowBackground(OrcaTheme.panel)
                    } else if engine.presetsLoaded {
                        labeled(
                            "Catalog",
                            "\(engine.printerNames.count) printers · \(engine.processNames.count) process · \(engine.filamentNames.count) filament"
                        )
                        Toggle(isOn: Binding(
                            get: { engine.compatibleOnly },
                            set: { engine.setCompatibleOnly($0) }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Compatible only")
                                    .foregroundStyle(OrcaTheme.text)
                                Text("Filter process & filament for selected printer")
                                    .font(.system(size: 11))
                                    .foregroundStyle(OrcaTheme.muted)
                            }
                        }
                        .tint(OrcaTheme.accent)
                        .listRowBackground(OrcaTheme.panel)
                    } else {
                        Button {
                            Task { await engine.loadAllSystemPresets() }
                        } label: {
                            Text("Load all system profiles")
                                .foregroundStyle(OrcaTheme.accent)
                        }
                        .listRowBackground(OrcaTheme.panel)
                    }
                    Button {
                        showPrinterPicker = true
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Printer")
                                    .font(.system(size: 12))
                                    .foregroundStyle(OrcaTheme.muted)
                                Text(engine.selectedPrinter.isEmpty ? "Select printer…" : engine.selectedPrinter)
                                    .foregroundStyle(OrcaTheme.text)
                                    .lineLimit(2)
                            }
                            Spacer()
                            if let path = engine.printerCoverPath, let ui = UIImage(contentsOfFile: path) {
                                Image(uiImage: ui)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 44, height: 44)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            Image(systemName: "chevron.right")
                                .foregroundStyle(OrcaTheme.muted)
                        }
                    }
                    .listRowBackground(OrcaTheme.panel)

                    Button {
                        showProcessPicker = true
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Process")
                                    .font(.system(size: 12))
                                    .foregroundStyle(OrcaTheme.muted)
                                Text(engine.selectedProcess.isEmpty ? engine.activeProcessProfile : engine.selectedProcess)
                                    .foregroundStyle(OrcaTheme.text)
                                    .lineLimit(2)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(OrcaTheme.muted)
                        }
                    }
                    .listRowBackground(OrcaTheme.panel)

                    Button {
                        filamentSlotForPicker = 0
                        showFilamentPicker = true
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Filament")
                                    .font(.system(size: 12))
                                    .foregroundStyle(OrcaTheme.muted)
                                Text(engine.selectedFilament.isEmpty ? "Select filament…" : engine.selectedFilament)
                                    .foregroundStyle(OrcaTheme.text)
                                    .lineLimit(2)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(OrcaTheme.muted)
                        }
                    }
                    .listRowBackground(OrcaTheme.panel)

                    // Multi-extruder filament slots (when printer has >1 nozzle)
                    if engine.extruderCount > 1 {
                        ForEach(0..<engine.extruderCount, id: \.self) { slot in
                            Button {
                                filamentSlotForPicker = slot
                                showFilamentPicker = true
                            } label: {
                                HStack {
                                    Text("Extruder \(slot + 1)")
                                        .foregroundStyle(OrcaTheme.muted)
                                    Spacer()
                                    Text(slotFilamentLabel(slot))
                                    .foregroundStyle(OrcaTheme.text)
                                    .lineLimit(1)
                                    Image(systemName: "chevron.right")
                                        .foregroundStyle(OrcaTheme.muted)
                                }
                            }
                            .listRowBackground(OrcaTheme.panel)
                        }
                    }
                } header: {
                    Text("System profiles")
                }

                if !engine.recentModelPaths.isEmpty {
                    Section("Recent models") {
                        ForEach(engine.recentModelPaths.prefix(8), id: \.self) { path in
                            Button {
                                let url = URL(fileURLWithPath: path)
                                guard FileManager.default.fileExists(atPath: path) else {
                                    status = "Missing: \(URL(fileURLWithPath: path).lastPathComponent)"
                                    return
                                }
                                status = engine.loadModel(url: url)
                                syncProcessFieldsFromEngine()
                                showProcess = false
                            } label: {
                                Text(URL(fileURLWithPath: path).lastPathComponent)
                                    .foregroundStyle(OrcaTheme.accent)
                                    .lineLimit(1)
                            }
                            .listRowBackground(OrcaTheme.panel)
                        }
                    }
                }

                Section {
                    TextField("Name (e.g. My PLA Fine)", text: $userProcessName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(size: 15, design: .monospaced))
                        .foregroundStyle(OrcaTheme.text)
                        .listRowBackground(OrcaTheme.panel)
                    Button {
                        let name = userProcessName.trimmingCharacters(in: .whitespacesAndNewlines)
                        if engine.saveUserProcess(name: name.isEmpty ? "My Process" : name) {
                            status = engine.lastMessage
                            if userProcessName.isEmpty { userProcessName = "My Process" }
                        } else {
                            status = engine.lastMessage
                        }
                    } label: {
                        Text("Save current settings as user process")
                            .foregroundStyle(OrcaTheme.accent)
                    }
                    .listRowBackground(OrcaTheme.panel)
                    if !engine.userProcessNames.isEmpty {
                        Text("Saved: \(engine.userProcessNames.joined(separator: ", "))")
                            .font(.system(size: 11))
                            .foregroundStyle(OrcaTheme.muted)
                            .listRowBackground(OrcaTheme.panel)
                    }
                } header: {
                    Text("User process (persists)")
                }

                if !engine.presetsLoaded {
                    Section("Bundled process (fallback)") {
                        ForEach(OrcaEngine.bundledProcessProfiles, id: \.id) { profile in
                            Button {
                                if engine.loadProcessProfile(profile.id) {
                                    syncProcessFieldsFromEngine()
                                    status = engine.lastMessage
                                } else {
                                    status = engine.lastMessage
                                }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(profile.title)
                                            .foregroundStyle(OrcaTheme.text)
                                        Text(profile.id + ".json")
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(OrcaTheme.muted)
                                    }
                                    Spacer()
                                    if engine.activeProcessProfile == profile.id {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(OrcaTheme.accent)
                                    }
                                }
                            }
                            .listRowBackground(OrcaTheme.panel)
                        }
                    }
                }

                Section("Objects on plate") {
                    if engine.hasModel {
                        labeled("File", engine.modelName ?? "—")
                        labeled("Count", "\(engine.objectCount)")
                        if !engine.boundsText.isEmpty {
                            labeled("Bounds", engine.boundsText)
                        }
                        if engine.modelVolumeMm3 > 0 {
                            labeled("Volume", String(format: "%.1f mm³", engine.modelVolumeMm3))
                        }
                        if let mesh = engine.mesh {
                            labeled("Mesh", "\(mesh.vertexCount) verts · \(mesh.indices.count / 3) tris")
                        }
                        // Selectable object list
                        ForEach(Array(engine.objectNames.enumerated()), id: \.offset) { idx, name in
                            Button {
                                engine.selectedObjectIndex = idx
                                status = "Selected \(name)"
                            } label: {
                                HStack {
                                    Image(systemName: engine.selectedObjectIndex == idx
                                          ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(OrcaTheme.accent)
                                    Text(name)
                                        .foregroundStyle(OrcaTheme.text)
                                    Spacer()
                                }
                            }
                            .listRowBackground(OrcaTheme.panel)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    engine.deleteObject(at: idx)
                                    status = engine.lastMessage
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                Button {
                                    engine.duplicateObject(at: idx)
                                    status = engine.lastMessage
                                } label: {
                                    Label("Duplicate", systemImage: "plus.square.on.square")
                                }
                                .tint(OrcaTheme.accent)
                            }
                        }
                        HStack(spacing: 8) {
                            Button("Duplicate selected") {
                                engine.duplicateSelected()
                                status = engine.lastMessage
                            }
                            .disabled(engine.selectedObjectIndex < 0)
                            Spacer()
                            Button("Delete selected", role: .destructive) {
                                engine.deleteSelected()
                                status = engine.lastMessage
                            }
                            .disabled(engine.selectedObjectIndex < 0)
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .listRowBackground(OrcaTheme.panel)
                    } else {
                        Text("No model loaded")
                            .foregroundStyle(OrcaTheme.muted)
                            .listRowBackground(OrcaTheme.panel)
                    }
                }
                Section("Printer / plate") {
                    labeled(
                        "Bed",
                        String(
                            format: "%.0f × %.0f × %.0f mm",
                            engine.bedSize.x, engine.bedSize.y, engine.bedHeight
                        )
                    )
                    labeled("Nozzle", engine.getOption("nozzle_diameter").map { "\($0) mm" } ?? "0.4 mm")
                    labeled("Filament Ø", engine.getOption("filament_diameter").map { "\($0) mm" } ?? "1.75 mm")
                    labeled("Active process", engine.activeProcessProfile)
                    HStack(spacing: 8) {
                        bedPreset("220²", 220, 220)
                        bedPreset("256²", 256, 256)
                        bedPreset("300²", 300, 300)
                        bedPreset("350²", 350, 350)
                    }
                    .listRowBackground(OrcaTheme.panel)
                }
                Section {
                    Button {
                        showAllSettings = true
                    } label: {
                        HStack {
                            Image(systemName: "slider.horizontal.3")
                                .foregroundStyle(OrcaTheme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("All settings")
                                    .foregroundStyle(OrcaTheme.text)
                                Text("Searchable full process / machine / filament keys")
                                    .font(.system(size: 11))
                                    .foregroundStyle(OrcaTheme.muted)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(OrcaTheme.muted)
                        }
                    }
                    .listRowBackground(OrcaTheme.panel)
                } header: {
                    Text("Full browser")
                }
                Section {
                    processField(title: "layer_height", unit: "mm", text: $layerHeight) {
                        engine.setOptionScalar("layer_height", value: layerHeight)
                        status = engine.lastMessage
                    }
                    processField(title: "wall_loops", unit: "", text: $walls) {
                        engine.setOptionScalar("wall_loops", value: walls)
                        status = engine.lastMessage
                    }
                    processField(title: "sparse_infill_density", unit: "%", text: $infill) {
                        engine.setOptionPercent("sparse_infill_density", value: infill)
                        status = engine.lastMessage
                    }
                    enumPicker(
                        title: "sparse_infill_pattern",
                        selection: $infillPattern,
                        choices: ProcessOptionCatalog.infillPattern
                    ) { key in
                        engine.setOptionScalar("sparse_infill_pattern", value: key)
                        status = engine.lastMessage
                    }
                    processField(title: "top_shell_layers", unit: "", text: $topShells) {
                        engine.setOptionScalar("top_shell_layers", value: topShells)
                        status = engine.lastMessage
                    }
                    processField(title: "bottom_shell_layers", unit: "", text: $bottomShells) {
                        engine.setOptionScalar("bottom_shell_layers", value: bottomShells)
                        status = engine.lastMessage
                    }
                } header: {
                    Text("Quality")
                }
                Section {
                    Toggle(isOn: $supportOn) {
                        Text("enable_support")
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                    }
                    .tint(OrcaTheme.accent)
                    .listRowBackground(OrcaTheme.panel)
                    .onChange(of: supportOn) { on in
                        engine.setOptionBool("enable_support", value: on)
                        status = engine.lastMessage
                    }
                    if supportOn {
                        enumPicker(
                            title: "support_type",
                            selection: $supportType,
                            choices: ProcessOptionCatalog.supportType
                        ) { key in
                            engine.setOptionScalar("support_type", value: key)
                            status = engine.lastMessage
                        }
                    }
                    enumPicker(
                        title: "brim_type",
                        selection: $brimType,
                        choices: ProcessOptionCatalog.brimType
                    ) { key in
                        engine.setOptionScalar("brim_type", value: key)
                        status = engine.lastMessage
                    }
                    if brimType != "no_brim" && brimType != "auto_brim" && brimType != "painted" {
                        processField(title: "brim_width", unit: "mm", text: $brimWidth) {
                            engine.setOptionScalar("brim_width", value: brimWidth)
                            status = engine.lastMessage
                        }
                    }
                } header: {
                    Text("Support / brim")
                }
                Section {
                    processField(title: "outer_wall_speed", unit: "mm/s", text: $outerWallSpeed) {
                        engine.setOptionScalar("outer_wall_speed", value: outerWallSpeed)
                        status = engine.lastMessage
                    }
                    processField(title: "sparse_infill_speed", unit: "mm/s", text: $sparseSpeed) {
                        engine.setOptionScalar("sparse_infill_speed", value: sparseSpeed)
                        status = engine.lastMessage
                    }
                } header: {
                    Text("Speeds")
                }
                Section {
                    processField(title: "nozzle_temperature", unit: "°C", text: $nozzleTemp) {
                        // Multi-extruder options accept a single value or comma list
                        engine.setOptionScalar("nozzle_temperature", value: nozzleTemp)
                        engine.setOptionScalar("nozzle_temperature_initial_layer", value: nozzleTemp)
                        status = engine.lastMessage
                    }
                    processField(title: "bed_temperature", unit: "°C", text: $bedTemp) {
                        // Orca may use bed_temperature or hot_plate_temp depending on machine
                        engine.setOptionScalar("bed_temperature", value: bedTemp)
                        engine.setOptionScalar("bed_temperature_initial_layer", value: bedTemp)
                        engine.setOptionScalar("hot_plate_temp", value: bedTemp)
                        engine.setOptionScalar("hot_plate_temp_initial_layer", value: bedTemp)
                        status = engine.lastMessage
                    }
                    processField(title: "filament_diameter", unit: "mm", text: $filamentDiameter) {
                        engine.setOptionScalar("filament_diameter", value: filamentDiameter)
                        status = engine.lastMessage
                    }
                } header: {
                    Text("Filament / temps")
                }
                Section {
                    enumPicker(
                        title: "wall_generator",
                        selection: $wallGenerator,
                        choices: ProcessOptionCatalog.wallGenerator
                    ) { key in
                        engine.setOptionScalar("wall_generator", value: key)
                        status = engine.lastMessage
                    }
                    enumPicker(
                        title: "seam_position",
                        selection: $seamPosition,
                        choices: ProcessOptionCatalog.seamPosition
                    ) { key in
                        engine.setOptionScalar("seam_position", value: key)
                        status = engine.lastMessage
                    }
                    enumPicker(
                        title: "ironing_type",
                        selection: $ironingType,
                        choices: ProcessOptionCatalog.ironingType
                    ) { key in
                        // Official key is ironing_type (not a bool "ironing")
                        engine.setOptionScalar("ironing_type", value: key)
                        status = engine.lastMessage
                    }
                } header: {
                    Text("Walls / seam / ironing")
                }
                Section("Engine") {
                    Text(engine.version)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(OrcaTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(engine.lastMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(OrcaTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .listRowBackground(OrcaTheme.panel)
                }
            }
            .scrollContentBackground(.hidden)
            .background(OrcaTheme.bg)
            .navigationTitle("Process")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showProcess = false }
                        .fontWeight(.semibold)
                        .foregroundStyle(OrcaTheme.accent)
                }
            }
            .onAppear {
                engine.refreshBedSize()
                syncProcessFieldsFromEngine()
            }
            .sheet(isPresented: $showPrinterPicker) {
                presetPickerSheet(
                    title: "Printer",
                    search: $printerSearch,
                    items: engine.filteredPrinters(
                        vendor: vendorFilter.isEmpty ? nil : vendorFilter,
                        search: printerSearch
                    ),
                    selected: engine.selectedPrinter,
                    vendorChips: engine.vendorList,
                    vendorFilter: $vendorFilter
                ) { name in
                    if engine.selectPrinter(name) {
                        syncProcessFieldsFromEngine()
                        status = engine.lastMessage
                    }
                    showPrinterPicker = false
                }
            }
            .sheet(isPresented: $showProcessPicker) {
                presetPickerSheet(
                    title: "Process",
                    search: $processSearch,
                    items: engine.filteredProcesses(search: processSearch),
                    selected: engine.selectedProcess.isEmpty ? engine.activeProcessProfile : engine.selectedProcess,
                    vendorChips: [],
                    vendorFilter: .constant("")
                ) { name in
                    if engine.presetsLoaded {
                        _ = engine.selectProcess(name)
                    } else {
                        _ = engine.loadProcessProfile(name)
                    }
                    syncProcessFieldsFromEngine()
                    status = engine.lastMessage
                    showProcessPicker = false
                }
            }
            .sheet(isPresented: $showFilamentPicker) {
                presetPickerSheet(
                    title: filamentSlotForPicker == 0
                        ? "Filament"
                        : "Filament · extruder \(filamentSlotForPicker + 1)",
                    search: $filamentSearch,
                    items: engine.filteredFilaments(search: filamentSearch),
                    selected: filamentSlotForPicker == 0
                        ? engine.selectedFilament
                        : engine.filamentSlotName(filamentSlotForPicker),
                    vendorChips: [],
                    vendorFilter: .constant("")
                ) { name in
                    if filamentSlotForPicker == 0 {
                        _ = engine.selectFilament(name)
                    } else {
                        _ = engine.setFilamentSlot(filamentSlotForPicker, name: name)
                    }
                    syncProcessFieldsFromEngine()
                    status = engine.lastMessage
                    showFilamentPicker = false
                }
            }
            .sheet(isPresented: $showAllSettings) {
                ProcessSettingsBrowser(engine: engine) {
                    syncProcessFieldsFromEngine()
                    status = engine.lastMessage
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .preferredColorScheme(.dark)
            }
        }
    }

    /// Searchable list of system presets (printer / process / filament).
    private func presetPickerSheet(
        title: String,
        search: Binding<String>,
        items: [String],
        selected: String,
        vendorChips: [String],
        vendorFilter: Binding<String>,
        onPick: @escaping (String) -> Void
    ) -> some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !vendorChips.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            vendorChip("All", selected: vendorFilter.wrappedValue.isEmpty) {
                                vendorFilter.wrappedValue = ""
                            }
                            ForEach(vendorChips, id: \.self) { v in
                                vendorChip(v, selected: vendorFilter.wrappedValue == v) {
                                    vendorFilter.wrappedValue = v
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                    .background(OrcaTheme.panel)
                }
                List {
                    if items.isEmpty {
                        Text(engine.presetsLoaded ? "No matches" : "Profiles not loaded")
                            .foregroundStyle(OrcaTheme.muted)
                            .listRowBackground(OrcaTheme.panel)
                    } else {
                        ForEach(items.prefix(800), id: \.self) { name in
                            Button {
                                onPick(name)
                            } label: {
                                HStack {
                                    Text(name)
                                        .foregroundStyle(OrcaTheme.text)
                                        .multilineTextAlignment(.leading)
                                    Spacer()
                                    if name == selected {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(OrcaTheme.accent)
                                    }
                                }
                            }
                            .listRowBackground(OrcaTheme.panel)
                        }
                        if items.count > 800 {
                            Text("Showing 800 of \(items.count) — refine search")
                                .font(.caption)
                                .foregroundStyle(OrcaTheme.muted)
                                .listRowBackground(OrcaTheme.panel)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .background(OrcaTheme.bg)
            .searchable(text: search, prompt: "Search \(title.lowercased())")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        showPrinterPicker = false
                        showProcessPicker = false
                        showFilamentPicker = false
                    }
                    .foregroundStyle(OrcaTheme.accent)
                }
            }
            .preferredColorScheme(.dark)
        }
        .presentationDetents([.medium, .large])
    }

    private func slotFilamentLabel(_ slot: Int) -> String {
        let n = engine.filamentSlotName(slot)
        return n.isEmpty ? "—" : n
    }

    private func vendorChip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(selected ? OrcaTheme.accent.opacity(0.25) : OrcaTheme.elevated)
                .foregroundStyle(selected ? OrcaTheme.accent : OrcaTheme.muted)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Pull key process options into sheet fields after profile load / open.
    private func syncProcessFieldsFromEngine() {
        if let v = engine.getOptionFirst("layer_height") { layerHeight = v }
        if let v = engine.getOptionFirst("wall_loops") { walls = v }
        if let v = engine.getOptionPercent("sparse_infill_density") { infill = v }
        if let v = engine.getOptionFirst("top_shell_layers") { topShells = v }
        if let v = engine.getOptionFirst("bottom_shell_layers") { bottomShells = v }
        if let v = engine.getOptionFirst("brim_width") { brimWidth = v }
        if let v = engine.getOptionFirst("outer_wall_speed") { outerWallSpeed = v }
        if let v = engine.getOptionFirst("sparse_infill_speed") { sparseSpeed = v }
        supportOn = engine.getOptionBool("enable_support")
        brimType = ProcessOptionCatalog.match(
            engine.getOptionFirst("brim_type"),
            in: ProcessOptionCatalog.brimType,
            fallback: "auto_brim"
        )
        supportType = ProcessOptionCatalog.match(
            engine.getOptionFirst("support_type"),
            in: ProcessOptionCatalog.supportType,
            fallback: "normal(auto)"
        )
        wallGenerator = ProcessOptionCatalog.match(
            engine.getOptionFirst("wall_generator"),
            in: ProcessOptionCatalog.wallGenerator,
            fallback: "arachne"
        )
        seamPosition = ProcessOptionCatalog.match(
            engine.getOptionFirst("seam_position"),
            in: ProcessOptionCatalog.seamPosition,
            fallback: "aligned"
        )
        ironingType = ProcessOptionCatalog.match(
            engine.getOptionFirst("ironing_type"),
            in: ProcessOptionCatalog.ironingType,
            fallback: "no ironing"
        )
        infillPattern = ProcessOptionCatalog.match(
            engine.getOptionFirst("sparse_infill_pattern"),
            in: ProcessOptionCatalog.infillPattern,
            fallback: "grid"
        )
        if let v = engine.getOptionFirst("nozzle_temperature") { nozzleTemp = v }
        // Bed temp: try both legacy and Bambu-style keys
        if let v = engine.getOptionFirst("bed_temperature") ?? engine.getOptionFirst("hot_plate_temp") {
            bedTemp = v
        }
        if let v = engine.getOptionFirst("filament_diameter") { filamentDiameter = v }
    }

    /// Official enum dropdown (Picker) for process options like brim_type.
    private func enumPicker(
        title: String,
        selection: Binding<String>,
        choices: [ProcessEnumChoice],
        onChange: @escaping (String) -> Void
    ) -> some View {
        // Write-through binding so pickers apply immediately without fragile onChange paths
        let live = Binding<String>(
            get: { selection.wrappedValue },
            set: { newVal in
                selection.wrappedValue = newVal
                onChange(newVal)
            }
        )
        return VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(OrcaTheme.muted)
            Picker(title, selection: live) {
                ForEach(choices) { c in
                    Text(c.label).tag(c.key)
                }
            }
            .pickerStyle(.menu)
            .tint(OrcaTheme.accent)
        }
        .listRowBackground(OrcaTheme.panel)
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(OrcaTheme.muted)
            Spacer()
            Text(value).foregroundStyle(OrcaTheme.text).multilineTextAlignment(.trailing)
        }
        .listRowBackground(OrcaTheme.panel)
    }

    private func bedPreset(_ title: String, _ w: Float, _ d: Float) -> some View {
        Button {
            engine.setBedSize(width: w, depth: d, height: engine.bedHeight)
            engine.refreshBedSize()
            status = engine.lastMessage
        } label: {
            Text(title)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    abs(engine.bedSize.x - w) < 0.5 && abs(engine.bedSize.y - d) < 0.5
                        ? OrcaTheme.accent.opacity(0.25)
                        : OrcaTheme.elevated
                )
                .foregroundStyle(OrcaTheme.accent)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func processField(title: String, unit: String, text: Binding<String>, apply: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(OrcaTheme.muted)
            HStack(spacing: 10) {
                TextField(title, text: text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.decimalPad)
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundStyle(OrcaTheme.text)
                    .padding(10)
                    .background(OrcaTheme.field)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                if !unit.isEmpty {
                    Text(unit).font(.system(size: 13)).foregroundStyle(OrcaTheme.muted).frame(width: 28)
                }
                Button("Apply", action: apply)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(OrcaTheme.accent)
            }
        }
        .listRowBackground(OrcaTheme.panel)
    }

    private var modelTypes: [UTType] {
        var types: [UTType] = [.data]
        if let stl = UTType(filenameExtension: "stl") { types.append(stl) }
        if let m3 = UTType(filenameExtension: "3mf") { types.append(m3) }
        if let obj = UTType(filenameExtension: "obj") { types.append(obj) }
        return types
    }

    private func sliceNow() {
        status = ""
        isSlicing = true
        Task {
            let msg = await engine.slice()
            await MainActor.run {
                status = msg
                isSlicing = false
                if engine.gcodeURL != nil {
                    mainTab = .preview
                }
            }
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            if importAppend {
                status = engine.addModel(url: url)
            } else {
                status = engine.loadModel(url: url)
            }
            engine.rememberRecent(url: url)
            // 3MF / profile-bearing loads refresh process sheet fields (config applied in engine)
            syncProcessFieldsFromEngine()
            mainTab = .prepare
        case .failure(let err):
            status = err.localizedDescription
        }
    }
}

private struct OrcaLogoMark: View {
    var body: some View {
        Group {
            #if canImport(UIKit)
            if let ui = UIImage(named: "OrcaSlicerLogo") {
                Image(uiImage: ui)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: "seal.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(OrcaTheme.accent)
            }
            #else
            Image("OrcaSlicerLogo").resizable().scaledToFit()
            #endif
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityLabel("OrcaSlicer")
    }
}

#Preview {
    OrcaRootView().preferredColorScheme(.dark)
}
