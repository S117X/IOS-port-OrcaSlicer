// OrcaSlicer iOS shell — prepare layout inspired by desktop Orca.
// Slicing: official libslic3r (every engine .cpp is compiled into liborca_engine.a).
// Desktop wxWidgets GUI is not runnable on iOS; this SwiftUI shell drives the same engine.

import SwiftUI
import UniformTypeIdentifiers
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

// MARK: - Theme from official desktop StateColor.cpp (dark mode)
// ORCA brand: #009688 → dark #00675b | hover #26A69A → #008172
// Secondary: #FF6F00 → #D15B00 | window bg #2D2D31 | panel #36363C / #242428

private enum OrcaTheme {
    /// Window background — StateColor dark map for #FFFFFF
    static let bg = Color(red: 0x2D / 255.0, green: 0x2D / 255.0, blue: 0x31 / 255.0)
    /// Sidebar / titlebar — #36363C
    static let panel = Color(red: 0x36 / 255.0, green: 0x36 / 255.0, blue: 0x3C / 255.0)
    /// Elevated controls — #3E3E45 button bg
    static let elevated = Color(red: 0x3E / 255.0, green: 0x3E / 255.0, blue: 0x45 / 255.0)
    /// Fields / inputs — slightly darker
    static let field = Color(red: 0x2D / 255.0, green: 0x2D / 255.0, blue: 0x31 / 255.0)
    /// Primary ORCA brand (light #009688 → dark-mode accent #00675b, use mid-teal for buttons)
    static let accent = Color(red: 0x00 / 255.0, green: 0x96 / 255.0, blue: 0x88 / 255.0)
    static let accentHover = Color(red: 0x26 / 255.0, green: 0xA6 / 255.0, blue: 0x9A / 255.0)
    static let accentDim = Color(red: 0x00 / 255.0, green: 0x67 / 255.0, blue: 0x5B / 255.0)
    /// Secondary brand orange from StateColor
    static let secondary = Color(red: 0xFF / 255.0, green: 0x6F / 255.0, blue: 0x00 / 255.0)
    static let bed = Color(red: 0x33 / 255.0, green: 0x33 / 255.0, blue: 0x37 / 255.0)
    static let grid = Color.white.opacity(0.14)
    static let muted = Color(red: 0xB3 / 255.0, green: 0xB3 / 255.0, blue: 0xB5 / 255.0)
    static let faint = Color(red: 0x81 / 255.0, green: 0x81 / 255.0, blue: 0x83 / 255.0)
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
    @State private var status = "Ready — load Sample or Open an STL/3MF, then Slice."
    @State private var isSlicing = false

    var body: some View {
        GeometryReader { geo in
            let bottomPad = max(geo.safeAreaInsets.bottom, 8)
            ZStack {
                OrcaTheme.bg.ignoresSafeArea()
                VStack(spacing: 0) {
                    headerBar
                    plateStage
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    controlsPanel(bottomInset: bottomPad)
                }
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)
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

    // MARK: Header — keep text horizontal and fully visible

    private var headerBar: some View {
        HStack(alignment: .center, spacing: 12) {
            OrcaLogoMark()
                .frame(width: 36, height: 36)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("OrcaSlicer")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(OrcaTheme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
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

            Button {
                showProcess = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(OrcaTheme.text)
                    .frame(width: 44, height: 44)
                    .background(OrcaTheme.elevated)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .accessibilityLabel("Process settings")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(OrcaTheme.panel)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(OrcaTheme.border)
                .frame(height: 1)
        }
    }

    // MARK: Plate

    private var plateStage: some View {
        ZStack {
            RadialGradient(
                colors: [
                    Color(red: 0.17, green: 0.18, blue: 0.22),
                    OrcaTheme.bg
                ],
                center: .center,
                startRadius: 8,
                endRadius: 420
            )

            GeometryReader { geo in
                let w = min(geo.size.width - 48, 340)
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [OrcaTheme.bed, OrcaTheme.bed.opacity(0.72)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: w, height: w * 0.80)
                        .overlay(BedGridView())
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(OrcaTheme.accent.opacity(0.45), lineWidth: 1.5)
                        )
                        .shadow(color: .black.opacity(0.55), radius: 30, y: 18)
                        .rotation3DEffect(.degrees(56), axis: (x: 1, y: 0, z: 0))
                        .rotationEffect(.degrees(-20))

                    if engine.hasModel {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [OrcaTheme.accentHover, OrcaTheme.accent],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(width: w * 0.22, height: w * 0.22)
                            .overlay(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .stroke(Color.white.opacity(0.35), lineWidth: 1)
                            )
                            .shadow(color: OrcaTheme.accent.opacity(0.55), radius: 16)
                            .offset(y: -w * 0.04)
                            .rotation3DEffect(.degrees(56), axis: (x: 1, y: 0, z: 0))
                            .rotationEffect(.degrees(-20))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Text(engine.hasModel ? "Prepare · 1 object" : "Prepare")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(OrcaTheme.muted)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(OrcaTheme.panel.opacity(0.95))
                        .clipShape(Capsule())
                        .padding(14)
                }
                Spacer()
                if let name = engine.modelName {
                    Text(name)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(OrcaTheme.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(OrcaTheme.panel.opacity(0.95))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .padding(.bottom, 14)
                } else {
                    Text("Open STL/3MF or load Sample cube")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(OrcaTheme.muted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 18)
                }
            }
        }
    }

    // MARK: Bottom controls — fixed heights so labels never clip

    private func controlsPanel(bottomInset: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(status)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(OrcaTheme.muted)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                actionButton(title: "Open", systemImage: "folder.fill") {
                    showImporter = true
                }
                actionButton(title: "Sample", systemImage: "cube.fill") {
                    status = engine.loadBundledSampleCube()
                }
                actionButton(title: "Process", systemImage: "slider.horizontal.3") {
                    showProcess = true
                }
            }

            Button(action: sliceNow) {
                HStack(spacing: 10) {
                    if isSlicing {
                        ProgressView()
                            .controlSize(.regular)
                            .tint(.white)
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
                ShareLink(item: gcode) {
                    HStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.up")
                        Text("Share G-code")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(OrcaTheme.success.opacity(0.18))
                    .foregroundStyle(OrcaTheme.success)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, bottomInset + 10)
        .background(OrcaTheme.panel)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(OrcaTheme.border)
                .frame(height: 1)
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

    // MARK: Process sheet

    private var processSheet: some View {
        NavigationStack {
            List {
                Section {
                    labeled("Bed", "220 × 220 × 250 mm")
                    labeled("Nozzle", "0.4 mm")
                    labeled("Filament", "1.75 mm PLA")
                } header: {
                    Text("Printer / plate")
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
                } header: {
                    Text("Process (DynamicPrintConfig)")
                } footer: {
                    Text("These options call official DynamicPrintConfig in libslic3r.")
                        .font(.footnote)
                }

                Section("Engine") {
                    Text(engine.version)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(OrcaTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .listStyle(.insetGrouped)
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
            Text(title)
                .foregroundStyle(OrcaTheme.muted)
            Spacer()
            Text(value)
                .foregroundStyle(OrcaTheme.text)
                .multilineTextAlignment(.trailing)
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
                    Text(unit)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(OrcaTheme.muted)
                        .frame(width: 28, alignment: .leading)
                }
                Button("Apply", action: apply)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(OrcaTheme.accent)
            }
        }
        .listRowBackground(OrcaTheme.panel)
    }

    // MARK: Actions

    private var modelTypes: [UTType] {
        var types: [UTType] = [.data]
        if let stl = UTType(filenameExtension: "stl") { types.append(stl) }
        if let m3 = UTType(filenameExtension: "3mf") { types.append(m3) }
        if let obj = UTType(filenameExtension: "obj") { types.append(obj) }
        return types
    }

    private func sliceNow() {
        status = "Slicing with official libslic3r (full engine binary)…"
        isSlicing = true
        Task {
            let msg = await engine.slice()
            await MainActor.run {
                status = msg
                isSlicing = false
            }
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            status = engine.loadModel(url: url)
        case .failure(let err):
            status = err.localizedDescription
        }
    }
}

// MARK: - Plate grid

private struct BedGridView: View {
    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 15
            var path = Path()
            for x in stride(from: 0, through: size.width, by: step) {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }
            for y in stride(from: 0, through: size.height, by: step) {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(path, with: .color(OrcaTheme.grid), lineWidth: 0.7)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Official logo from resources/images (Assets.xcassets OrcaSlicerLogo + loose PNG fallback)
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
            Image("OrcaSlicerLogo")
                .resizable()
                .scaledToFit()
            #endif
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityLabel("OrcaSlicer")
    }
}

#Preview {
    OrcaRootView()
        .preferredColorScheme(.dark)
}
