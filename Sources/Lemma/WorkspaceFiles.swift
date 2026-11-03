import AppKit
import LemmaCore
import Observation

/// One buffer per file across windows, so a later save cannot replace another window's edits.
@MainActor @Observable
final class WorkspaceFileBuffer: Identifiable {
    let id: String
    var text: String
    var savedText: String
    var saveError: String?
    @ObservationIgnored var saveTask: Task<Void, Never>?
    var isDirty: Bool { text != savedText }
    var isMarkdown: Bool { (id as NSString).pathExtension.lowercased() == "md" }
    var icon: String { isMarkdown ? "markdown" : "file-text" }

    init(name: String, text: String) { id = name; self.text = text; savedText = text }

    @discardableResult
    func save(in repository: WorkspaceFileRepository) -> Bool {
        saveTask?.cancel(); saveTask = nil
        guard isDirty else { return true }
        do {
            try repository.save(text, name: id)
            savedText = text; saveError = nil
            return true
        } catch {
            saveError = "Could not save “\(id)”: \(error.localizedDescription) Your edits are still open. Try Save again."
            return false
        }
    }
}

@MainActor
extension StudyStore {
    var workspaceFileRepository: WorkspaceFileRepository { app.workspaceFileRepository }
    var workspaceFiles: [String] { app.workspaceFiles }
    var activeFile: WorkspaceFileBuffer? { activeFileName.flatMap { app.fileBuffers[$0] } }
    var activeDocumentTitle: String { activeFileName ?? workspace?.title ?? "Lemma" }
    static func fileTabID(_ name: String) -> String { "file:\(name)" }

    func refreshWorkspaceFiles() {
        do { app.workspaceFiles = try workspaceFileRepository.list() }
        catch { self.error = "Could not read Workspace Files: \(error.localizedDescription)" }
    }

    func beginNewFile() { palette = nil; showNewFile = true }

    @discardableResult
    func createWorkspaceFile(name: String, kind: WorkspaceFileKind) throws -> String {
        let name = try workspaceFileRepository.create(name: name, kind: kind)
        refreshWorkspaceFiles()
        openWorkspaceFile(name)
        reveal(.library); paneExpanded[ExplorerPane.files.id] = true
        return name
    }

    func openWorkspaceFile(_ name: String) {
        do {
            if app.fileBuffers[name] == nil {
                app.fileBuffers[name] = WorkspaceFileBuffer(name: name, text: try workspaceFileRepository.read(name))
            }
            if activeFileName == nil, activeSpecial == nil, workspace != nil { captureViewport(); scheduleViewportSave() }
            if !fileTabs.contains(name) { fileTabs.append(name) }
            activeSpecial = nil; activeFileName = name; palette = nil
            find.hide()
            saveWorkbench()
        } catch { self.error = "Could not open “\(name)”: \(error.localizedDescription)" }
    }

    func updateWorkspaceFile(_ file: WorkspaceFileBuffer, text: String) {
        guard file.text != text else { return }
        file.text = text
        file.saveTask?.cancel()
        let repository = workspaceFileRepository
        file.saveTask = Task { @MainActor [weak file] in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            file?.save(in: repository)
        }
    }

    func saveActiveFile() { _ = activeFile?.save(in: workspaceFileRepository) }

    @discardableResult
    func closeWorkspaceFile(_ name: String) -> Bool {
        guard let index = fileTabs.firstIndex(of: name) else { return true }
        if let file = app.fileBuffers[name], !file.save(in: workspaceFileRepository) {
            error = file.saveError; return false
        }
        fileTabs.remove(at: index)
        if activeFileName == name {
            activeFileName = nil
            if !fileTabs.isEmpty { openWorkspaceFile(fileTabs[min(index, fileTabs.count - 1)]) }
            else if workspace == nil { activeSpecial = specialTabs.last }
        }
        if !app.windows.contains(where: { $0.fileTabs.contains(name) }) { app.fileBuffers[name] = nil }
        saveWorkbench()
        return true
    }

    func revealWorkspaceFiles() {
        do {
            try FileManager.default.createDirectory(at: workspaceFileRepository.directory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(workspaceFileRepository.directory)
        } catch { self.error = "Could not open Workspace Files: \(error.localizedDescription)" }
    }
}
