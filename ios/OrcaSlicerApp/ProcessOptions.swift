// Official OrcaSlicer process option enums (keys match PrintConfig.cpp).
// Used by process sheet pickers so values always serialize correctly.

import Foundation

/// One selectable enum option: official serialize key + human label.
struct ProcessEnumChoice: Identifiable, Hashable {
    var id: String { key }
    let key: String
    let label: String
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
