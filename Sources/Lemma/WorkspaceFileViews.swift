import SwiftUI
import AppKit
import LemmaCore

struct NewWorkspaceFileSheet: View {
    @Bindable var store: StudyStore
    @Environment(\.theme) private var theme
    @State private var name = ""
    @State private var kind: WorkspaceFileKind = .markdown
    @State private var failure: String?
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkbenchSheetHeader(codicon: "new-file", symbol: "doc.badge.plus", title: "New File") {
                EmptyView()
            } actions: { EmptyView() }
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("File name").font(.ui(13, weight: .medium))
                    WorkbenchTextField(placeholder: "Untitled.\(kind.fileExtension)", text: $name, accessibilityLabel: "New file name", onSubmit: create)
                        .focused($nameFocused)
                }
                Picker("File type", selection: $kind) {
                    ForEach(WorkspaceFileKind.allCases) { kind in Text(kind.label).tag(kind) }
                }.pickerStyle(.segmented).accessibilityLabel("File type")
                HStack(spacing: 6) {
                    WorkbenchGlyph(codicon: "folder", symbol: "folder", size: 13)
                    Text("Workspace Files")
                    WorkbenchGlyph(codicon: "chevron-right", symbol: "chevron.right", size: 11)
                    Text((try? store.workspaceFileRepository.filename(name, kind: kind)) ?? "Untitled.\(kind.fileExtension)")
                        .lineLimit(1).truncationMode(.middle)
                }.font(.ui(12)).foregroundStyle(theme[.descriptionForeground])
                if let failure { Text(failure).font(.ui(12)).foregroundStyle(theme[.errorForeground]).fixedSize(horizontal: false, vertical: true) }
                HStack(spacing: 8) {
                    Spacer()
                    Button("Cancel") { store.showNewFile = false }.keyboardShortcut(.cancelAction).workbenchButton()
                    Button("Create File", action: create).keyboardShortcut(.defaultAction).workbenchButton(.primary)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(20)
        }
        .foregroundStyle(theme[.foreground]).background(theme[.editorBackground]).frame(width: 500)
        .onAppear { nameFocused = true }
    }

    private func create() {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do { try store.createWorkspaceFile(name: name, kind: kind); store.showNewFile = false }
        catch { failure = error.localizedDescription }
    }
}

struct WorkspaceFileEditor: View {
    @Bindable var store: StudyStore
    @Bindable var file: WorkspaceFileBuffer
    @Environment(\.theme) private var theme
    @State private var preview = false
    @State private var wrapsLines = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                WorkbenchGlyph(codicon: "folder", symbol: "folder", size: 13)
                Button("Workspace Files") { store.reveal(.library); store.paneExpanded[ExplorerPane.files.id] = true }
                    .buttonStyle(.plain).foregroundStyle(theme[.descriptionForeground])
                WorkbenchGlyph(codicon: "chevron-right", symbol: "chevron.right", size: 12)
                FileIcon(kind: file.icon)
                Text(file.id).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Text(file.saveError != nil ? "Not saved" : file.isDirty ? "Saving…" : "All changes saved")
                    .font(.ui(11))
                    .foregroundStyle(theme[file.saveError == nil ? .descriptionForeground : .errorForeground])
                    .accessibilityLabel("File status: \(file.saveError != nil ? "Not saved" : file.isDirty ? "Saving" : "Saved")")
                VSIconButton(icon: "word-wrap", help: wrapsLines ? "Turn Word Wrap Off" : "Turn Word Wrap On", size: 15, toggled: wrapsLines) { wrapsLines.toggle() }
                if file.isMarkdown {
                    VSIconButton(icon: "open-preview", help: preview ? "Close Preview" : "Open Preview to the Side", size: 15, toggled: preview) { preview.toggle() }
                }
                VSMenuButton(icon: "ellipsis", help: "File Actions") {
                    [.action("Save", enabled: file.isDirty, shortcut: "⌘S") { store.saveActiveFile() },
                     .action("Find in File…", shortcut: "⌘F") { store.findInWorkspaceFile() },
                     .separator,
                     .action("Reveal in Finder") { if let url = try? store.workspaceFileRepository.url(for: file.id) { NSWorkspace.shared.activateFileViewerSelecting([url]) } }]
                }
            }
            .font(.ui(12)).padding(.leading, 14).padding(.trailing, 6).frame(height: 30)
            .background(theme[.breadcrumbBackground])
            if let failure = file.saveError {
                Text(failure).font(.ui(12)).foregroundStyle(theme[.errorForeground])
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            HSplitView {
                WorkspaceTextEditor(store: store, file: file, wrapsLines: wrapsLines)
                    .frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity)
                if preview && file.isMarkdown {
                    VStack(spacing: 0) {
                        HStack(spacing: 6) {
                            FileIcon(kind: "markdown")
                            Text("Preview · \(file.id)").lineLimit(1)
                            Spacer()
                            VSIconButton(icon: "close", help: "Close Preview", size: 14) { preview = false }
                        }.font(.ui(12)).padding(.horizontal, 12).frame(height: 30).background(theme[.sideBarBackground])
                        ScrollView { MathPreview(text: file.text).padding(24).frame(maxWidth: 780) }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }.frame(minWidth: 240)
                }
            }
        }
        .foregroundStyle(theme[.editorForeground]).background(theme[.editorBackground])
        .id(file.id)
    }
}

struct WorkspaceFilesList: View {
    @Bindable var store: StudyStore
    @Environment(\.theme) private var theme
    @State private var query = ""
    @State private var renaming: String?
    @State private var newName = ""
    @State private var renameFailure: String?
    @FocusState private var renamingFocused: Bool

    private var names: [String] { store.workspaceFiles.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) } }

    var body: some View {
        VStack(spacing: 0) {
            if store.workspaceFiles.count > 6 || !query.isEmpty {
                VSTextField(placeholder: "Filter files", text: $query, icon: "filter").padding(.horizontal, 12).padding(.vertical, 6)
            }
            ScrollView {
            LazyVStack(spacing: 0) {
                if store.workspaceFiles.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("No text files yet.").font(.ui(12)).foregroundStyle(theme[.descriptionForeground])
                        Button("New File…") { store.beginNewFile() }.buttonStyle(.plain).workbenchLinkStyle()
                    }.padding(.horizontal, 16).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(names, id: \.self) { name in
                    if renaming == name {
                        HStack(spacing: 6) {
                            FileIcon(kind: (name as NSString).pathExtension.lowercased() == "md" ? "markdown" : "file-text")
                            TextField("File name", text: $newName).textFieldStyle(.plain).workbenchInputBox()
                                .focused($renamingFocused).onSubmit { commitRename(name) }
                                .onExitCommand { renaming = nil; renameFailure = nil }
                                .accessibilityLabel("Rename \(name)")
                        }.padding(.leading, 20).padding(.trailing, 8).frame(height: 30)
                        if let renameFailure { Text(renameFailure).font(.ui(11)).foregroundStyle(theme[.errorForeground]).padding(.horizontal, 16) }
                    } else {
                    VSRow(selected: store.activeFileName == name, depth: 0, action: { store.openWorkspaceFile(name) }) {
                        FileIcon(kind: (name as NSString).pathExtension.lowercased() == "md" ? "markdown" : "file-text").padding(.trailing, 6)
                        Text(name).font(.ui(13)).lineLimit(1)
                        Spacer(minLength: 0)
                        if store.app.fileBuffers[name]?.isDirty == true {
                            Circle().fill(theme[.foreground]).frame(width: 6, height: 6).help("Unsaved changes")
                        }
                    }
                    .help(name).accessibilityLabel(name)
                    .contextMenu {
                        Button("Open") { store.openWorkspaceFile(name) }
                        Button("Rename…") { newName = name; renaming = name; renameFailure = nil; renamingFocused = true }
                        Button("Reveal in Finder") {
                            if let url = try? store.workspaceFileRepository.url(for: name) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        }
                        Divider()
                        Button("Move to Trash", role: .destructive) { store.trashWorkspaceFile(name) }
                    }
                    }
                }
                if !query.isEmpty && names.isEmpty {
                    Text("No matching files").font(.ui(12)).foregroundStyle(theme[.descriptionForeground]).padding(12)
                }
            }
            }
        }.onAppear { store.refreshWorkspaceFiles() }
    }

    private func commitRename(_ name: String) {
        do { try store.renameWorkspaceFile(name, to: newName); renaming = nil; renameFailure = nil }
        catch { renameFailure = error.localizedDescription }
    }
}
