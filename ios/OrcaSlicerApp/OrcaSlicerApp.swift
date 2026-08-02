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

    private var devicePlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "printer.fill")
                .font(.system(size: 40))
                .foregroundStyle(OrcaTheme.accent)
            Text("Device / send to printer")
                .font(.headline)
                .foregroundStyle(OrcaTheme.text)
            Text("Moonraker · OctoPrint · network send — porting next.")
                .font(.subheadline)
                .foregroundStyle(OrcaTheme.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OrcaTheme.bg.opacity(0.92))
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

            Button(action: sliceNow) {
                HStack(spacing: 10) {
                    if isSlicing {
                        ProgressView().controlSize(.regular).tint(.white)
                    } else {
                        Image(systemName: "square.3.layers.3d.down.right")
                            .font(.system(size: 17, weight: .bold))
                    }
                    Text(isSlicing ? "Slicing with libslic3r…" : "Slice plate")
                        .font(.system(size: 17, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
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

    @State private var topShells = "3"
    @State private var bottomShells = "3"
    @State private var supportOn = false
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
