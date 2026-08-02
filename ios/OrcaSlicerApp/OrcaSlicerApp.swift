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
    @State private var showProcess = false
    @State private var layerHeight = "0.20"
    @State private var infill = "15"
    @State private var walls = "2"
    @State private var status = "Drag to orbit · pinch to zoom · load a model then Slice."
    @State private var isSlicing = false
    @State private var mainTab: MainTab = .prepare
    @State private var didAutoSample = false

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
                            accent: UIColor(red: 0, green: 150 / 255, blue: 136 / 255, alpha: 1)
                        )
                        .overlay(alignment: .topLeading) {
                            hintOverlay
                                .padding(12)
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
        .onAppear {
            // Demo: load sample cube so plate shows real libslic3r mesh immediately
            guard !didAutoSample, !engine.hasModel else { return }
            didAutoSample = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                status = engine.loadBundledSampleCube()
            }
        }
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
                    Text(engine.isLinked ? "Official libslic3r linked" : "Engine not linked")
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
                    if tab == .preview && engine.gcodeURL == nil {
                        status = "Slice first to open G-code preview."
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
        VStack(alignment: .leading, spacing: 4) {
            Text(mainTab == .preview ? "Preview · drag orbit · pinch zoom" : "Prepare · drag orbit · pinch zoom")
                .font(.system(size: 11, weight: .semibold))
            if engine.hasModel {
                Text(engine.boundsText.isEmpty ? "1 object on plate" : engine.boundsText)
                    .font(.system(size: 11, design: .monospaced))
            }
            if let name = engine.modelName {
                Text(name)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(OrcaTheme.muted)
        .padding(10)
        .background(OrcaTheme.panel.opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @State private var printerHost = "http://192.168.1.100"
    @State private var printerStatus = "Not connected"
    @State private var isConnecting = false
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

                VStack(alignment: .leading, spacing: 8) {
                    Text("Moonraker / Klipper host")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(OrcaTheme.muted)
                    TextField("http://printer.local", text: $printerHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .font(.system(size: 15, design: .monospaced))
                        .foregroundStyle(OrcaTheme.text)
                        .padding(12)
                        .background(OrcaTheme.elevated)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                HStack(spacing: 10) {
                    Button {
                        Task { await connectMoonraker() }
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
                        Task { await uploadGCodeToMoonraker() }
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

                VStack(alignment: .leading, spacing: 8) {
                    Text("Quick temps (local config only until connected)")
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

                Text("Uses Moonraker HTTP API (server.info / server.files.upload). Full printer control (pause, resume, cam) is next.")
                    .font(.caption)
                    .foregroundStyle(OrcaTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OrcaTheme.bg.opacity(0.96))
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

    private func connectMoonraker() async {
        isConnecting = true
        defer { isConnecting = false }
        guard let base = URL(string: printerHost.trimmingCharacters(in: .whitespacesAndNewlines)) else {
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
                    printerStatus = "Connected · \(ver)"
                } else {
                    printerStatus = "Connected (HTTP \(code))"
                }
            } else {
                printerStatus = "HTTP \(code) from server.info"
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
        guard let base = URL(string: printerHost.trimmingCharacters(in: .whitespacesAndNewlines)) else {
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
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if (200...299).contains(code) {
                printerStatus = "Uploaded \(filename) → gcodes/"
            } else {
                printerStatus = "Upload failed HTTP \(code)"
            }
        } catch {
            printerStatus = "Upload error: \(error.localizedDescription)"
        }
    }

    private func controlsPanel(bottomInset: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(status)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(OrcaTheme.muted)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                actionButton(title: "Open", systemImage: "folder.fill") { showImporter = true }
                actionButton(title: "Sample", systemImage: "cube.fill") {
                    status = engine.loadBundledSampleCube()
                    mainTab = .prepare
                }
                actionButton(title: "Process", systemImage: "slider.horizontal.3") {
                    showProcess = true
                }
            }

            if engine.hasModel && mainTab == .prepare {
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

            if let gcode = engine.gcodeURL {
                HStack(spacing: 10) {
                    Button {
                        mainTab = .preview
                        status = "G-code path preview — orbit to inspect toolpaths."
                    } label: {
                        Label("Preview paths", systemImage: "eye")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                            .background(OrcaTheme.accent.opacity(0.18))
                            .foregroundStyle(OrcaTheme.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    ShareLink(item: gcode) {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                            .background(OrcaTheme.success.opacity(0.18))
                            .foregroundStyle(OrcaTheme.success)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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

    private var plateToolsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                toolChip("Center", "scope") { engine.centerOnBed(); status = engine.lastMessage }
                toolChip("Arrange", "square.grid.2x2") { engine.arrange(); status = engine.lastMessage }
                toolChip("↺ 45°", "rotate.left") { engine.rotateZ(degrees: -45); status = engine.lastMessage }
                toolChip("↻ 45°", "rotate.right") { engine.rotateZ(degrees: 45); status = engine.lastMessage }
                toolChip("×0.5", "minus.magnifyingglass") { engine.scale(factor: 0.5); status = engine.lastMessage }
                toolChip("×2", "plus.magnifyingglass") { engine.scale(factor: 2); status = engine.lastMessage }
                toolChip("←", "arrow.left") { engine.translate(dx: -10, dy: 0); status = engine.lastMessage }
                toolChip("→", "arrow.right") { engine.translate(dx: 10, dy: 0); status = engine.lastMessage }
                toolChip("↑", "arrow.up") { engine.translate(dx: 0, dy: 10); status = engine.lastMessage }
                toolChip("↓", "arrow.down") { engine.translate(dx: 0, dy: -10); status = engine.lastMessage }
            }
        }
    }

    private func toolChip(_ title: String, _ systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(OrcaTheme.elevated)
            .foregroundStyle(OrcaTheme.text)
            .clipShape(Capsule())
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
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(OrcaTheme.panel)
        .overlay(alignment: .top) {
            Rectangle().fill(OrcaTheme.border).frame(height: 1)
        }
    }

    @State private var topShells = "3"
    @State private var bottomShells = "3"
    @State private var supportOn = false
    @State private var ironingOn = false
    @State private var brimType = "no_brim"
    @State private var outerWallSpeed = "60"
    @State private var sparseSpeed = "100"

    private var processSheet: some View {
        NavigationStack {
            List {
                Section("Objects on plate") {
                    if engine.hasModel {
                        labeled("File", engine.modelName ?? "—")
                        labeled("Count", "\(engine.objectCount)")
                        if !engine.boundsText.isEmpty {
                            labeled("Bounds", engine.boundsText)
                        }
                        if let mesh = engine.mesh {
                            labeled("Mesh", "\(mesh.vertexCount) verts · \(mesh.indices.count / 3) tris")
                        }
                    } else {
                        Text("No model loaded")
                            .foregroundStyle(OrcaTheme.muted)
                            .listRowBackground(OrcaTheme.panel)
                    }
                }
                Section("Printer / plate") {
                    labeled("Bed", "\(Int(engine.bedSize.x)) × \(Int(engine.bedSize.y)) × 250 mm")
                    labeled("Nozzle", "0.4 mm")
                    labeled("Filament", "1.75 mm PLA")
                    labeled("Profile", "process_0.20mm_Standard")
                }
                Section {
                    processField(title: "layer_height", unit: "mm", text: $layerHeight) {
                        engine.setOption("layer_height", value: layerHeight)
                        status = engine.lastMessage
                    }
                    processField(title: "wall_loops", unit: "", text: $walls) {
                        engine.setOption("wall_loops", value: walls)
                        status = engine.lastMessage
                    }
                    processField(title: "sparse_infill_density", unit: "%", text: $infill) {
                        engine.setOption("sparse_infill_density", value: "\(infill)%")
                        status = engine.lastMessage
                    }
                    processField(title: "top_shell_layers", unit: "", text: $topShells) {
                        engine.setOption("top_shell_layers", value: topShells)
                        status = engine.lastMessage
                    }
                    processField(title: "bottom_shell_layers", unit: "", text: $bottomShells) {
                        engine.setOption("bottom_shell_layers", value: bottomShells)
                        status = engine.lastMessage
                    }
                } header: {
                    Text("Quality (DynamicPrintConfig)")
                }
                Section {
                    Toggle(isOn: $supportOn) {
                        Text("enable_support")
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                    }
                    .tint(OrcaTheme.accent)
                    .listRowBackground(OrcaTheme.panel)
                    .onChange(of: supportOn) { on in
                        engine.setOption("enable_support", value: on ? "1" : "0")
                        status = engine.lastMessage
                    }
                    processField(title: "brim_type", unit: "", text: $brimType) {
                        engine.setOption("brim_type", value: brimType)
                        status = engine.lastMessage
                    }
                } header: {
                    Text("Support / brim")
                } footer: {
                    Text("brim_type: no_brim · outer_only · inner_only · outer_and_inner")
                }
                Section {
                    processField(title: "outer_wall_speed", unit: "mm/s", text: $outerWallSpeed) {
                        engine.setOption("outer_wall_speed", value: outerWallSpeed)
                        status = engine.lastMessage
                    }
                    processField(title: "sparse_infill_speed", unit: "mm/s", text: $sparseSpeed) {
                        engine.setOption("sparse_infill_speed", value: sparseSpeed)
                        status = engine.lastMessage
                    }
                } header: {
                    Text("Speeds")
                }
                Section {
                    processField(title: "nozzle_temperature", unit: "°C", text: $nozzleTemp) {
                        engine.setOption("nozzle_temperature", value: nozzleTemp)
                        engine.setOption("nozzle_temperature_initial_layer", value: nozzleTemp)
                        status = engine.lastMessage
                    }
                    processField(title: "bed_temperature", unit: "°C", text: $bedTemp) {
                        engine.setOption("bed_temperature", value: bedTemp)
                        engine.setOption("bed_temperature_initial_layer", value: bedTemp)
                        status = engine.lastMessage
                    }
                    processField(title: "filament_diameter", unit: "mm", text: .constant("1.75")) {
                        engine.setOption("filament_diameter", value: "1.75")
                        status = engine.lastMessage
                    }
                } header: {
                    Text("Filament / temps")
                } footer: {
                    Text("Options map to DynamicPrintConfig keys used by official G-code export.")
                }
                Section {
                    Button {
                        engine.setOption("wall_generator", value: "arachne")
                        status = engine.lastMessage
                    } label: {
                        labeled("wall_generator", "Set Arachne")
                    }
                    Button {
                        engine.setOption("wall_generator", value: "classic")
                        status = engine.lastMessage
                    } label: {
                        labeled("wall_generator", "Set classic")
                    }
                    Button {
                        engine.setOption("seam_position", value: "aligned")
                        status = engine.lastMessage
                    } label: {
                        labeled("seam_position", "aligned")
                    }
                    Button {
                        engine.setOption("seam_position", value: "nearest")
                        status = engine.lastMessage
                    } label: {
                        labeled("seam_position", "nearest")
                    }
                    Toggle(isOn: $ironingOn) {
                        Text("ironing")
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                    }
                    .tint(OrcaTheme.accent)
                    .listRowBackground(OrcaTheme.panel)
                    .onChange(of: ironingOn) { on in
                        engine.setOption("ironing", value: on ? "1" : "0")
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
        }
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(OrcaTheme.muted)
            Spacer()
            Text(value).foregroundStyle(OrcaTheme.text).multilineTextAlignment(.trailing)
        }
        .listRowBackground(OrcaTheme.panel)
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
        status = "Slicing with official libslic3r…"
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
            status = engine.loadModel(url: url)
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
