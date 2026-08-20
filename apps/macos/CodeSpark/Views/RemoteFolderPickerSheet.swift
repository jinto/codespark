import SwiftUI

/// Walks a remote host's directories on behalf of `RemoteFolderPickerSheet`.
///
/// Every move is a round trip, so the model only ever trusts the path the host
/// reported back — a failed step leaves the browser exactly where it stood.
@MainActor
final class RemoteFolderPickerModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var path: String = ""
    @Published private(set) var entries: [RemoteDirectoryEntry] = []
    @Published var showsHiddenFolders = false {
        didSet { dropSelectionIfItWentOffScreen() }
    }
    @Published var newFolderName = ""
    @Published var selectedName: String?

    /// What "Choose" hands back: the folder highlighted in the list, or — with
    /// nothing highlighted — the one we are standing in.
    var chosenPath: String {
        guard let selectedName else { return path }
        return path == "/" ? "/" + selectedName : path + "/" + selectedName
    }

    private let source: RemoteDirectorySource
    private let startingPath: String?
    private var latestRequest = 0

    init(source: RemoteDirectorySource, startingAt startingPath: String?) {
        self.source = source
        self.startingPath = startingPath
    }

    var visibleEntries: [RemoteDirectoryEntry] {
        showsHiddenFolders ? entries : entries.filter { !$0.isHidden }
    }

    var canGoUp: Bool {
        !path.isEmpty && RemoteDirectoryLister.parentPath(of: path) != nil
    }

    /// A folder we actually stand in — an error banner does not take that away.
    var canChoose: Bool { !path.isEmpty && phase != .loading }

    /// Quiet while a round trip is out, so a second Create cannot start a mkdir
    /// that is only going to come back as "File exists".
    var canCreateFolder: Bool {
        !path.isEmpty && phase != .loading && RemoteDirectoryLister.isValidFolderName(newFolderName)
    }

    var errorMessage: String? {
        if case .failed(let message) = phase { return message }
        return nil
    }

    func load() async {
        await move(to: startingPath)
    }

    func open(_ name: String) async {
        guard !path.isEmpty else { return }
        await move(to: path == "/" ? "/" + name : path + "/" + name)
    }

    func goUp() async {
        guard let parent = RemoteDirectoryLister.parentPath(of: path) else { return }
        await move(to: parent)
    }

    /// Jumps to whatever the user typed into the path field.
    func open(typedPath: String) async {
        let trimmed = typedPath.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        await move(to: trimmed)
    }

    func createFolder() async {
        guard canCreateFolder else { return }
        let name = newFolderName
        let request = beginRequest()
        do {
            let created = try await source.createDirectory(in: path, named: name)
            // The folder is made either way; walking into it is only right if
            // the user is still standing where they asked for it.
            guard request == latestRequest else { return }
            newFolderName = ""
            await move(to: created)
        } catch {
            guard request == latestRequest else { return }
            phase = .failed(message(for: error))
        }
    }

    private func move(to target: String?) async {
        let request = beginRequest()
        do {
            let listing = try await source.listDirectory(at: target)
            guard request == latestRequest else { return }
            path = listing.path
            entries = listing.entries
            selectedName = nil
            phase = .loaded
        } catch {
            guard request == latestRequest else { return }
            // Keep the last good listing on screen; only the banner changes.
            phase = .failed(message(for: error))
        }
    }

    /// Claims the screen for one round trip. Every click starts its own task, so
    /// whoever asked last owns the answer — otherwise a slow reply lands after a
    /// newer one and walks the user back out of the folder they just opened.
    private func beginRequest() -> Int {
        latestRequest &+= 1
        phase = .loading
        return latestRequest
    }

    /// Hiding the dotfiles must not leave "Choose" pointing at one of them.
    private func dropSelectionIfItWentOffScreen() {
        guard let selectedName else { return }
        if !visibleEntries.contains(where: { $0.name == selectedName }) {
            self.selectedName = nil
        }
    }

    private func message(for error: Error) -> String {
        (error as? RemoteDirectoryError)?.errorDescription ?? error.localizedDescription
    }
}

struct RemoteFolderPickerSheet: View {
    let host: String
    @StateObject private var model: RemoteFolderPickerModel
    let onChoose: (String) -> Void
    let onCancel: () -> Void

    @State private var pathField = ""
    @State private var isNamingNewFolder = false
    @FocusState private var isNamingFieldFocused: Bool

    init(
        host: String,
        source: RemoteDirectorySource,
        startingAt startingPath: String?,
        onChoose: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.host = host
        self.onChoose = onChoose
        self.onCancel = onCancel
        _model = StateObject(
            wrappedValue: RemoteFolderPickerModel(source: source, startingAt: startingPath)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            pathBar
            folderList
            if let message = model.errorMessage { errorBanner(message) }
            if isNamingNewFolder { newFolderRow }
            footer
        }
        .padding(20)
        .frame(width: 460, height: 460)
        .task {
            await model.load()
            pathField = model.path
        }
        .onChange(of: model.path) { _, newPath in pathField = newPath }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Choose Remote Folder")
                .font(.headline)
            Text(host)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("remoteFolderPickerHost")
        }
    }

    private var pathBar: some View {
        HStack(spacing: 8) {
            Button {
                Task { await model.goUp() }
            } label: {
                Image(systemName: "arrow.up")
            }
            .disabled(!model.canGoUp)
            .help("Go to the enclosing folder")
            .accessibilityIdentifier("remoteFolderPickerUp")

            TextField("/home/user/project", text: $pathField)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .onSubmit { Task { await model.open(typedPath: pathField) } }
                .accessibilityIdentifier("remoteFolderPickerPath")
        }
    }

    private var folderList: some View {
        List(model.visibleEntries, selection: $model.selectedName) { entry in
            HStack(spacing: 6) {
                Image(systemName: entry.isGitRepository ? "shippingbox" : "folder")
                    .foregroundStyle(entry.isGitRepository ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                Text(entry.name)
                    .foregroundStyle(entry.isHidden ? .secondary : .primary)
            }
            .contentShape(Rectangle())
            // Click picks, double-click walks in — the open-panel bargain.
            .onTapGesture(count: 2) { Task { await model.open(entry.name) } }
            .onTapGesture { model.selectedName = entry.name }
        }
        .accessibilityIdentifier("remoteFolderPickerList")
        .overlay {
            if model.phase == .loading {
                ProgressView().controlSize(.small)
            } else if model.visibleEntries.isEmpty && model.errorMessage == nil {
                Text("No folders here")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
            Text(model.canChoose ? message : "\(message)\nEnter the path by hand instead.")
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .foregroundStyle(.orange)
        .accessibilityIdentifier("remoteFolderPickerError")
    }

    private var newFolderRow: some View {
        HStack(spacing: 8) {
            TextField("Folder name", text: $model.newFolderName)
                .textFieldStyle(.roundedBorder)
                .focused($isNamingFieldFocused)
                .onSubmit { create() }
                .accessibilityIdentifier("remoteFolderPickerNewFolderName")
            Button("Create", action: create)
                .disabled(!model.canCreateFolder)
        }
    }

    private var footer: some View {
        HStack {
            Toggle("Show hidden folders", isOn: $model.showsHiddenFolders)
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("remoteFolderPickerHiddenToggle")

            Button("New Folder") {
                isNamingNewFolder = true
                isNamingFieldFocused = true
            }
            .disabled(!model.canChoose)
            .accessibilityIdentifier("remoteFolderPickerNewFolder")

            Spacer()

            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button("Choose") { onChoose(model.chosenPath) }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canChoose)
                .accessibilityIdentifier("remoteFolderPickerChoose")
        }
    }

    private func create() {
        Task {
            await model.createFolder()
            isNamingNewFolder = false
        }
    }
}
