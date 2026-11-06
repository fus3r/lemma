import AppKit
import LemmaCore
import Observation

/// Palette entries are preferences; every saved mark keeps its own color, even after a palette entry changes.
struct HighlightSwatch: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var color: HighlightColor
    var hex: String?
    var shortcut: HighlightShortcut?

    init(_ preset: HighlightColor) {
        id = preset.rawValue; name = preset.label; color = preset
    }

    static func newColor() -> HighlightSwatch {
        var swatch = HighlightSwatch(.rose)
        swatch.id = UUID().uuidString; swatch.name = "New Color"; swatch.hex = "#9B59B6"
        return swatch
    }

    var nativeColor: NSColor { NSColor.highlightHex(hex) ?? color.nativeColor }

    mutating func setColor(_ value: NSColor) {
        guard let rgb = value.usingColorSpace(.sRGB) else { return }
        hex = String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()),
                     Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
        // An older Lemma ignores colorHex and still opens the book with the nearest built-in color.
        color = HighlightColor.allCases.min { left, right in
            func distance(_ preset: HighlightColor) -> CGFloat {
                let c = preset.nativeColor
                return pow(c.redComponent - rgb.redComponent, 2) + pow(c.greenComponent - rgb.greenComponent, 2) + pow(c.blueComponent - rgb.blueComponent, 2)
            }
            return distance(left) < distance(right)
        } ?? .yellow
    }
}

@MainActor @Observable
final class HighlightPalette {
    struct Settings: Codable, Equatable {
        var colors = HighlightColor.allCases.map(HighlightSwatch.init)
        var highlightID = HighlightColor.yellow.rawValue
        var underlineID = HighlightColor.blue.rawValue

        mutating func removeColor(id: String) {
            guard colors.count > 1 else { return }
            colors.removeAll { $0.id == id }
            if highlightID == id { highlightID = colors[0].id }
            if underlineID == id { underlineID = colors[0].id }
        }
    }

    private(set) var settings = Settings()
    private(set) var loadError: String?
    private let url: URL

    init(url: URL) {
        self.url = url
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let saved = try JSONDecoder().decode(Settings.self, from: Data(contentsOf: url))
            guard !saved.colors.isEmpty else { throw CocoaError(.coderReadCorrupt) }
            settings = saved
        } catch { loadError = "Could not read the saved colors. The saved file has been kept: \(error.localizedDescription)" }
    }

    func defaultColor(for style: HighlightStyle) -> HighlightSwatch {
        let id = style == .highlight ? settings.highlightID : settings.underlineID
        return settings.colors.first { $0.id == id } ?? HighlightSwatch(style == .highlight ? .yellow : .blue)
    }

    func save(_ draft: Settings) throws {
        guard !draft.colors.isEmpty else { return }
        var shortcuts = Set<HighlightShortcut>()
        for swatch in draft.colors {
            if let shortcut = swatch.shortcut, !shortcuts.insert(shortcut).inserted {
                throw PaletteError.duplicateShortcut(shortcut.label)
            }
        }
        var saved = draft
        for index in saved.colors.indices {
            let name = saved.colors[index].name.trimmingCharacters(in: .whitespacesAndNewlines)
            saved.colors[index].name = name.isEmpty ? saved.colors[index].hex ?? saved.colors[index].color.label : name
        }
        if !saved.colors.contains(where: { $0.id == saved.highlightID }) { saved.highlightID = saved.colors[0].id }
        if !saved.colors.contains(where: { $0.id == saved.underlineID }) { saved.underlineID = saved.colors[0].id }
        let data = try WorkspaceRepository.encoder.encode(saved)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        settings = saved; loadError = nil
    }

    func setDefault(_ id: String, for style: HighlightStyle) throws {
        var draft = settings
        if style == .highlight { draft.highlightID = id } else { draft.underlineID = id }
        try save(draft)
    }

    enum PaletteError: LocalizedError {
        case duplicateShortcut(String)
        var errorDescription: String? {
            switch self { case .duplicateShortcut(let keys): "\(keys) is assigned to more than one color. Choose a different shortcut." }
        }
    }
}

extension NSColor {
    static func highlightHex(_ hex: String?) -> NSColor? {
        guard let hex, hex.count == 7, hex.first == "#", let rgb = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
                       blue: CGFloat(rgb & 255) / 255, alpha: 0.4)
    }
}

extension StudyHighlight {
    var nativeColor: NSColor { NSColor.highlightHex(colorHex) ?? color.nativeColor }
}
