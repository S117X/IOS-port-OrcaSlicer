// Official OrcaSlicer process option enums (keys match PrintConfig.cpp).
// Used by process sheet pickers so values always serialize correctly.
// Also: searchable full settings browser over DynamicPrintConfig keys.

import Foundation
import SwiftUI

/// One selectable enum option: official serialize key + human label.
struct ProcessEnumChoice: Identifiable, Hashable {
    var id: String { key }
    let key: String
    let label: String
}

/// One row in the full settings browser (from orca_session_option_*).
struct ConfigOptionEntry: Identifiable, Hashable {
    enum Kind: Int, Hashable {
        case bool = 0
        case int = 1
        case float = 2
        case percent = 3
        case string = 4
        case `enum` = 5
        case other = 6
    }

    var id: String { key }
    let key: String
    let label: String
    let category: String
    let sidetext: String
    let type: Kind
    var value: String
    let enumChoices: [ProcessEnumChoice]

    var displayCategory: String {
        category.isEmpty ? "Other" : category
    }
}

enum ProcessOptionCatalog {
    /// brim_type — s_keys_map_BrimType
    static let brimType: [ProcessEnumChoice] = [
        .init(key: "auto_brim", label: "Auto brim"),
        .init(key: "brim_ears", label: "Brim ears"),
        .init(key: "outer_only", label: "Outer only"),
        .init(key: "inner_only", label: "Inner only"),
        .init(key: "outer_and_inner", label: "Outer + inner"),
        .init(key: "painted", label: "Painted"),
        .init(key: "no_brim", label: "No brim"),
    ]

    /// support_type — s_keys_map_SupportType
    static let supportType: [ProcessEnumChoice] = [
        .init(key: "normal(auto)", label: "Normal (auto)"),
        .init(key: "tree(auto)", label: "Tree (auto)"),
        .init(key: "normal(manual)", label: "Normal (manual)"),
        .init(key: "tree(manual)", label: "Tree (manual)"),
    ]

    /// wall_generator — PerimeterGeneratorType
    static let wallGenerator: [ProcessEnumChoice] = [
        .init(key: "arachne", label: "Arachne"),
        .init(key: "classic", label: "Classic"),
    ]

    /// seam_position — s_keys_map_SeamPosition
    static let seamPosition: [ProcessEnumChoice] = [
        .init(key: "aligned", label: "Aligned"),
        .init(key: "aligned_back", label: "Aligned back"),
        .init(key: "nearest", label: "Nearest"),
        .init(key: "back", label: "Back"),
        .init(key: "random", label: "Random"),
    ]

    /// ironing_type — NOT a bool; key is ironing_type
    static let ironingType: [ProcessEnumChoice] = [
        .init(key: "no ironing", label: "No ironing"),
        .init(key: "top", label: "Top surfaces"),
        .init(key: "topmost", label: "Topmost only"),
        .init(key: "solid", label: "All solid"),
    ]

    /// sparse_infill_pattern (common subset)
    static let infillPattern: [ProcessEnumChoice] = [
        .init(key: "grid", label: "Grid"),
        .init(key: "line", label: "Line"),
        .init(key: "triangles", label: "Triangles"),
        .init(key: "trihexagon", label: "Tri-hexagon"),
        .init(key: "cubic", label: "Cubic"),
        .init(key: "adaptivecubic", label: "Adaptive cubic"),
        .init(key: "quartercubic", label: "Quarter cubic"),
        .init(key: "supportcubic", label: "Support cubic"),
        .init(key: "lightning", label: "Lightning"),
        .init(key: "gyroid", label: "Gyroid"),
        .init(key: "honeycomb", label: "Honeycomb"),
        .init(key: "3dhoneycomb", label: "3D honeycomb"),
        .init(key: "hilbertcurve", label: "Hilbert curve"),
        .init(key: "archimedeanchords", label: "Archimedean chords"),
        .init(key: "octagramspiral", label: "Octagram spiral"),
        .init(key: "crosshatch", label: "Cross hatch"),
    ]

    static func label(for key: String, in choices: [ProcessEnumChoice]) -> String {
        choices.first { $0.key == key }?.label ?? key
    }

    /// Match engine value to a known choice key (handles spacing / case quirks).
    static func match(_ raw: String?, in choices: [ProcessEnumChoice], fallback: String) -> String {
        guard let raw, !raw.isEmpty else { return fallback }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if choices.contains(where: { $0.key == t }) { return t }
        if let hit = choices.first(where: { $0.key.caseInsensitiveCompare(t) == .orderedSame }) {
            return hit.key
        }
        // Sometimes serialized with underscores vs spaces
        let norm = t.replacingOccurrences(of: "_", with: " ")
        if let hit = choices.first(where: { $0.key == norm }) { return hit.key }
        return fallback
    }
}

extension OrcaEngine {
    /// First scalar of a multi-value option (temps, diameters often "210,210").
    func getOptionFirst(_ key: String) -> String? {
        guard let v = getOption(key) else { return nil }
        let first = v.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? v
        return first.isEmpty ? nil : first
    }

    /// Percent options may serialize as "15%" — strip for text fields.
    func getOptionPercent(_ key: String) -> String? {
        guard let v = getOptionFirst(key) else { return nil }
        return v.replacingOccurrences(of: "%", with: "")
    }

    /// Bool option: true for 1/true/yes.
    func getOptionBool(_ key: String) -> Bool {
        guard let v = getOptionFirst(key)?.lowercased() else { return false }
        return v == "1" || v == "true" || v == "yes" || v == "on"
    }

    /// Set a scalar; for multi-value filament keys write a single-element string.
    func setOptionScalar(_ key: String, value: String) {
        setOption(key, value: value)
    }

    /// Set percent option (accepts "15" or "15%").
    func setOptionPercent(_ key: String, value: String) {
        var v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !v.hasSuffix("%") { v += "%" }
        setOption(key, value: v)
    }

    func setOptionBool(_ key: String, value: Bool) {
        setOption(key, value: value ? "1" : "0")
    }
}

// MARK: - Searchable full settings browser

/// Browse / edit every DynamicPrintConfig key via official serialize strings.
struct ProcessSettingsBrowser: View {
    @ObservedObject var engine: OrcaEngine
    var onChanged: (() -> Void)?

    @State private var entries: [ConfigOptionEntry] = []
    @State private var search = ""
    @State private var categoryFilter = ""
    @State private var draftValues: [String: String] = [:]
    @State private var applyError: String?
    @State private var isLoading = true

    private let themeBg = Color(red: 0x2D / 255.0, green: 0x2D / 255.0, blue: 0x31 / 255.0)
    private let themePanel = Color(red: 0x36 / 255.0, green: 0x36 / 255.0, blue: 0x3C / 255.0)
    private let themeAccent = Color(red: 0x00 / 255.0, green: 0x96 / 255.0, blue: 0x88 / 255.0)
    private let themeMuted = Color(red: 0xB3 / 255.0, green: 0xB3 / 255.0, blue: 0xB5 / 255.0)
    private let themeText = Color(red: 0xEF / 255.0, green: 0xEF / 255.0, blue: 0xF0 / 255.0)
    private let themeField = Color(red: 0x2D / 255.0, green: 0x2D / 255.0, blue: 0x31 / 255.0)

    private var categories: [String] {
        let set = Set(entries.map(\.displayCategory))
        return set.sorted()
    }

    private var filtered: [ConfigOptionEntry] {
        var list = entries
        if !categoryFilter.isEmpty {
            list = list.filter { $0.displayCategory == categoryFilter }
        }
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !q.isEmpty {
            list = list.filter {
                $0.key.lowercased().contains(q)
                    || $0.label.lowercased().contains(q)
                    || $0.category.lowercased().contains(q)
                    || $0.value.lowercased().contains(q)
            }
        }
        return list
    }

    private var grouped: [(String, [ConfigOptionEntry])] {
        let groups = Dictionary(grouping: filtered, by: \.displayCategory)
        return groups.keys.sorted().map { ($0, groups[$0]!.sorted { $0.key < $1.key }) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if isLoading {
                    ProgressView("Loading options…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .foregroundStyle(themeMuted)
                } else {
                    if !categories.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                catChip("All", selected: categoryFilter.isEmpty) {
                                    categoryFilter = ""
                                }
                                ForEach(categories, id: \.self) { c in
                                    catChip(c, selected: categoryFilter == c) {
                                        categoryFilter = c
                                    }
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                        }
                        .background(themePanel)
                    }
                    if let applyError {
                        Text(applyError)
                            .font(.system(size: 12))
                            .foregroundStyle(Color(red: 0xBB / 255.0, green: 0x2A / 255.0, blue: 0x3A / 255.0))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(themePanel)
                    }
                    List {
                        Text("\(filtered.count) of \(entries.count) options")
                            .font(.caption)
                            .foregroundStyle(themeMuted)
                            .listRowBackground(themePanel)
                        ForEach(grouped, id: \.0) { cat, rows in
                            Section(cat) {
                                ForEach(rows) { entry in
                                    optionRow(entry)
                                }
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .background(themeBg)
            .searchable(text: $search, prompt: "Search key, label, value")
            .navigationTitle("All settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Reload") { reload() }
                        .foregroundStyle(themeAccent)
                }
            }
            .preferredColorScheme(.dark)
            .onAppear { reload() }
        }
    }

    private func catChip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(selected ? themeAccent.opacity(0.25) : themeField)
                .foregroundStyle(selected ? themeAccent : themeMuted)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func optionRow(_ entry: ConfigOptionEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.label)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(themeText)
                    .lineLimit(2)
                Spacer()
                if !entry.sidetext.isEmpty {
                    Text(entry.sidetext)
                        .font(.system(size: 11))
                        .foregroundStyle(themeMuted)
                }
            }
            Text(entry.key)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(themeMuted)
                .lineLimit(1)

            switch entry.type {
            case .bool:
                Toggle(isOn: Binding(
                    get: {
                        let v = (draftValues[entry.key] ?? entry.value).lowercased()
                        return v == "1" || v == "true" || v == "yes" || v == "on"
                    },
                    set: { on in
                        apply(entry.key, value: on ? "1" : "0")
                    }
                )) {
                    Text("enabled").font(.system(size: 12)).foregroundStyle(themeMuted)
                }
                .tint(themeAccent)

            case .enum:
                // Lazy enum lists: filled on first display via engine.enumChoices
                let choices: [ProcessEnumChoice] = {
                    if !entry.enumChoices.isEmpty { return entry.enumChoices }
                    return engine.enumChoices(for: entry.key)
                }()
                if !choices.isEmpty {
                    let current = draftValues[entry.key] ?? entry.value
                    let matched = ProcessOptionCatalog.match(
                        current, in: choices, fallback: choices[0].key
                    )
                    Picker(entry.key, selection: Binding(
                        get: { matched },
                        set: { apply(entry.key, value: $0) }
                    )) {
                        ForEach(choices) { c in
                            Text(c.label).tag(c.key)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(themeAccent)
                } else {
                    scalarEditor(entry)
                }

            default:
                scalarEditor(entry)
            }
        }
        .padding(.vertical, 4)
        .listRowBackground(themePanel)
    }

    private func scalarEditor(_ entry: ConfigOptionEntry) -> some View {
        let draft = Binding<String>(
            get: { draftValues[entry.key] ?? entry.value },
            set: { draftValues[entry.key] = $0 }
        )
        return HStack(spacing: 8) {
            TextField(entry.key, text: draft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(themeText)
                .padding(8)
                .background(themeField)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            Button("Apply") {
                apply(entry.key, value: draftValues[entry.key] ?? entry.value)
            }
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(themeAccent)
        }
    }

    private func apply(_ key: String, value: String) {
        let ok = engine.applyConfigOption(key: key, value: value)
        if ok {
            applyError = nil
            draftValues[key] = value
            if let idx = entries.firstIndex(where: { $0.key == key }) {
                entries[idx].value = value
            }
            onChanged?()
        } else {
            applyError = engine.lastMessage
        }
    }

    private func reload() {
        isLoading = true
        applyError = nil
        // Session C ABI is not thread-safe; snapshot on main (hundreds of keys is fine).
        let snap = engine.allConfigOptions()
        var drafts: [String: String] = [:]
        for e in snap { drafts[e.key] = e.value }
        entries = snap
        draftValues = drafts
        isLoading = false
    }
}
