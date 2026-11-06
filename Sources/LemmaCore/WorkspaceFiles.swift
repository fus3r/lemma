import Foundation

public enum WorkspaceFileKind: String, CaseIterable, Identifiable, Sendable {
    case markdown, text
    public var id: String { rawValue }
    public var fileExtension: String { self == .markdown ? "md" : "txt" }
    public var label: String { self == .markdown ? "Markdown (.md)" : "Plain Text (.txt)" }
}

/// Standalone UTF-8 files live beside the book workspaces, independently of any PDF.
public struct WorkspaceFileRepository: Sendable {
    public let directory: URL
    public init(root: URL) { directory = root.appendingPathComponent("Files", isDirectory: true) }

    public func filename(_ proposed: String, kind: WorkspaceFileKind) throws -> String {
        let name = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.hasPrefix("."),
              name.rangeOfCharacter(from: .controlCharacters) == nil,
              !name.contains(where: { "/\\:".contains($0) }) else {
            throw FileError.invalidName
        }
        let ext = (name as NSString).pathExtension.lowercased()
        guard ext.isEmpty || ["md", "txt"].contains(ext) else { throw FileError.unsupportedType }
        return ext.isEmpty ? "\(name).\(kind.fileExtension)" : name
    }

    public func url(for name: String) throws -> URL {
        guard try filename(name, kind: .text) == name,
              ["md", "txt"].contains((name as NSString).pathExtension.lowercased()) else { throw FileError.invalidName }
        return directory.appendingPathComponent(name)
    }

    public func list() throws -> [String] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        var names: [String] = []
        for url in urls where ["txt", "md"].contains(url.pathExtension.lowercased()) {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true { names.append(url.lastPathComponent) }
        }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    @discardableResult
    public func create(name: String, kind: WorkspaceFileKind) throws -> String {
        let name = try filename(name, kind: kind)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Creation must never replace an existing file, including on a case-insensitive volume.
        try Data().write(to: url(for: name), options: .withoutOverwriting)
        return name
    }

    public func read(_ name: String) throws -> String { try String(contentsOf: url(for: name), encoding: .utf8) }
    public func save(_ text: String, name: String) throws { try text.write(to: url(for: name), atomically: true, encoding: .utf8) }
    public func rename(_ name: String, to renamed: String) throws {
        try FileManager.default.moveItem(at: url(for: name), to: url(for: renamed))
    }

    public enum FileError: LocalizedError {
        case invalidName, unsupportedType
        public var errorDescription: String? {
            switch self {
            case .invalidName: "Enter a filename without slashes, colons or a leading dot."
            case .unsupportedType: "Use .txt for plain text or .md for Markdown."
            }
        }
    }
}
