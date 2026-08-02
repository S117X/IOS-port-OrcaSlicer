// OrcaSlicer iOS host — links official libslic3r via orca_ios_api C ABI.
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
                Section("Engine") {
                    Text(engine.version)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Text(status)
                        .font(.footnote)
                }
                Section("Model") {
                    Button("Import STL / 3MF…") { showImporter = true }
                    if let name = engine.modelName {
                        Text("Loaded: \(name)")
                    }
                }
                Section("Process (DynamicPrintConfig)") {
                    HStack {
                        Text("layer_height")
                        TextField("0.20", text: $layerHeight)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .monospaced()
                    }
                    Button("Apply option") {
                        engine.setOption("layer_height", value: layerHeight)
                        status = engine.lastMessage
                    }
                }
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
                Section("Notes") {
                    Text("UI is SwiftUI. Slicing calls orca_session_* → Slic3r::Print::process / export_gcode in official source. AGPL-3.0.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("OrcaSlicer")
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [
                    UTType(filenameExtension: "stl") ?? .data,
                    UTType(filenameExtension: "3mf") ?? .data,
                    UTType(filenameExtension: "obj") ?? .data,
                ],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    status = engine.loadModel(url: url)
                case .failure(let err):
                    status = err.localizedDescription
                }
            }
        }
    }
}
