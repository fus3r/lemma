import SwiftUI
import AppKit
import LemmaCore

struct NewWorkspaceFileSheet: View {
    @Bindable var store: StudyStore
    @Environment(\.theme) private var theme
    @State private var name = ""
    @State private var kind: WorkspaceFileKind = .markdown
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkbenchSheetHeader(codicon: "new-file", symbol: "doc.badge.plus", title: "Add New File") {
                EmptyView()
            } actions: { EmptyView() }
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("File name").font(.ui(13, weight: .medium))
                    WorkbenchTextField(placeholder: "Notes", text: $name, accessibilityLabel: "New file name", onSubmit: create)
                }
                Picker("File type", selection: $kind) {
                    ForEach(WorkspaceFileKind.allCases) { kind in Text(kind.label).tag(kind) }
                }.pickerStyle(.segmented).accessibilityLabel("File type")
                Text("Saved in Workspace Files. Changes save automatically as you write.")
                    .font(.ui(12)).foregroundStyle(theme[.descriptionForeground]).fixedSize(horizontal: false, vertical: true)
                if let failure { Text(failure).font(.ui(12)).foregroundStyle(theme[.errorForeground]).fixedSize(horizontal: false, vertical: true) }
                HStack(spacing: 8) {
                    Spacer()
                    Button("Cancel") { store.showNewFile = false }.keyboardShortcut(.cancelAction).workbenchButton()
                    Button("Create File", action: create).keyboardShortcut(.defaultAction).workbenchButton(.primary)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(20)
        }
        .foregroundStyle(theme[.foreground]).background(theme[.editorBackground]).frame(width: 460)
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

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                FileIcon(kind: file.icon)
                Text("Workspace Files").foregroundStyle(theme[.descriptionForeground])
                WorkbenchGlyph(codicon: "chevron-right", symbol: "chevron.right", size: 12)
                Text(file.id).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Text(file.saveError != nil ? "Not saved" : file.isDirty ? "Saving…" : "Saved")
                    .foregroundStyle(theme[file.saveError == nil ? .descriptionForeground : .errorForeground])
                    .accessibilityLabel("File status: \(file.saveError != nil ? "Not saved" : file.isDirty ? "Saving" : "Saved")")
                if file.isMarkdown {
                    Button(preview ? "Edit" : "Preview") { preview.toggle() }.workbenchButton(compact: true)
                }
                Button("Save") { store.saveActiveFile() }.workbenchButton(compact: true).disabled(!file.isDirty)
                Button { if let url = try? store.workspaceFileRepository.url(for: file.id) { NSWorkspace.shared.activateFileViewerSelecting([url]) } } label: {
                    WorkbenchGlyph(codicon: "folder-opened", symbol: "folder", size: 14)
                }.buttonStyle(.plain).help("Reveal File in Finder").accessibilityLabel("Reveal File in Finder")
            }
            .font(.ui(12)).padding(.horizontal, 14).frame(height: 36)
            .background(theme[.breadcrumbBackground])
            if let failure = file.saveError {
                Text(failure).font(.ui(12)).foregroundStyle(theme[.errorForeground])
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            if preview {
                ScrollView { MathPreview(text: file.text).padding(24) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TextEditor(text: Binding(get: { file.text }, set: { store.updateWorkspaceFile(file, text: $0) }))
                    .font(.system(size: 14, design: .monospaced)).foregroundStyle(theme[.editorForeground])
                    .scrollContentBackground(.hidden).tint(theme[.editorCursorForeground])
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .accessibilityLabel("\(file.id) editor")
            }
        }
        .foregroundStyle(theme[.editorForeground]).background(theme[.editorBackground])
        .id(file.id)
    }
}

struct WorkspaceFilesList: View {
    @Bindable var store: StudyStore
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if store.workspaceFiles.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Keep text and Markdown files in your workspace.").font(.ui(12)).foregroundStyle(theme[.descriptionForeground])
                        Button("Add New File…") { store.beginNewFile() }.workbenchButton(compact: true)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(store.workspaceFiles, id: \.self) { name in
                    VSRow(selected: store.activeFileName == name, depth: 0, action: { store.openWorkspaceFile(name) }) {
                        FileIcon(kind: (name as NSString).pathExtension.lowercased() == "md" ? "markdown" : "file-text").padding(.trailing, 6)
                        Text(name).font(.ui(13)).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .help(name).accessibilityLabel(name)
                    .contextMenu {
                        Button("Open") { store.openWorkspaceFile(name) }
                        Button("Reveal in Finder") {
                            if let url = try? store.workspaceFileRepository.url(for: name) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        }
                    }
                }
            }
        }.onAppear { store.refreshWorkspaceFiles() }
    }
}
