// OrcaSlicer host — links official libslic3r via orca_ios_api C ABI.
// Source engine: https://github.com/OrcaSlicer/OrcaSlicer (AGPL-3.0)
// This file is UI only; slicing is performed by C++ libslic3r.

import SwiftUI
import UniformTypeIdentifiers

@main
struct OrcaSlicerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @StateObject private var engine = OrcaEngine()
    @State private var showImporter = false
    @State private var layerHeight = "0.20"
    @State private var status = "Ready — load an STL/3MF, then Slice (libslic3r)."

    var body: some View {
        NavigationStack {
            Form {
                engineSection
                modelSection
                processSection
                sliceSection
                notesSection
            }
            .navigationTitle("OrcaSlicer")
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: modelTypes,
                allowsMultipleSelection: false
            ) { result in
                handleImport(result)
            }
        }
    }

    private var modelTypes: [UTType] {
        var types: [UTType] = [.data]
        if let stl = UTType(filenameExtension: "stl") { types.append(stl) }
        if let m3 = UTType(filenameExtension: "3mf") { types.append(m3) }
        if let obj = UTType(filenameExtension: "obj") { types.append(obj) }
        return types
    }

    private var engineSection: some View {
        Section("Engine") {
            Text(engine.version)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Text(status)
                .font(.footnote)
        }
    }

    private var modelSection: some View {
        Section("Model") {
            Button("Load sample cube (20 mm)") {
                status = engine.loadBundledSampleCube()
            }
            Button("Import STL / 3MF…") { showImporter = true }
            if let name = engine.modelName {
                Text("Loaded: \(name)")
            }
        }
    }

    private var processSection: some View {
        Section("Process (DynamicPrintConfig)") {
            HStack {
                Text("layer_height")
                TextField("0.20", text: $layerHeight)
                    .multilineTextAlignment(.trailing)
                    .font(.body.monospaced())
            }
            Button("Apply option") {
                engine.setOption("layer_height", value: layerHeight)
                status = engine.lastMessage
            }
        }
    }

    private var sliceSection: some View {
        Section("Slice") {
            Button("Slice with libslic3r → G-code") {
                status = "Slicing…"
                Task {
                    let msg = await engine.slice()
                    status = msg
                }
            }
            .disabled(!engine.hasModel)
            if let gcode = engine.gcodeURL {
                ShareLink("Share G-code", item: gcode)
            }
        }
    }

    private var notesSection: some View {
        Section("Notes") {
            Text("UI is SwiftUI. Slicing calls orca_session_* → Slic3r::Print::process / export_gcode in official source. AGPL-3.0.")
                .font(.caption2)
                .foregroundStyle(.secondary)
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
