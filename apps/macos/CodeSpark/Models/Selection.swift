import Foundation

/// Which project is on screen — as one value.
///
/// It used to be two. `selectedProjectID` moved the instant a row was clicked
/// or a digit pressed; `selectedProject` arrived a git round trip later, and
/// over ssh that could be twenty seconds. Every one of those windows was a
/// window in which the two disagreed, and the app spent it filing a new tab
/// under the project you were leaving, stamping one project's session list onto
/// another's sidebar row, and opening a local shell recorded against a remote
/// project.
///
/// The answer is not another guard. Four sites guarded correctly, one carried a
/// ten-line comment explaining why — and three were missed. A convention that
/// is 43% unapplied is not carelessness, it is the wrong mechanism. So
/// `(id: B, detail: A)` is simply not a value that can be built here: the id
/// travels *inside* `.loaded`, and the borrowed detail is reachable only under
/// a name that says what it is.
enum Selection: Equatable {
    case none

    /// Picked, and its detail is still on the way.
    ///
    /// `onScreen` is the project the model's live state — `liveSessions`,
    /// `workspaces`, `activeWorkspacePath` — still belongs to. It is held so
    /// that switching projects does not blink the pane empty for the length of
    /// a round trip, and it is emphatically not this project's detail.
    case pending(id: String, onScreen: ProjectDetailViewData?)

    case loaded(ProjectDetailViewData)

    /// The project the user chose, landed or not. What a click, a digit, or a
    /// restored launch named.
    var id: String? {
        switch self {
        case .none: nil
        case .pending(let id, _): id
        case .loaded(let detail): detail.id
        }
    }

    /// Chosen *and* landed. Everything that acts on behalf of the selected
    /// project — starting a session, adding a worktree, writing to the store —
    /// comes through here, because this is nil for exactly the window in which
    /// the other detail would be a different project's.
    var detail: ProjectDetailViewData? {
        if case .loaded(let detail) = self { return detail }
        return nil
    }

    /// The project the live state currently describes.
    ///
    /// Not merely "for display": `liveSessions`, `workspaces` and
    /// `activeWorkspacePath` are one matched set, and anything reading them
    /// alongside a project has to read the project they belong to or it pairs a
    /// path with the wrong host, a grouping with the wrong repo. During a
    /// switch that is still the project being left — which is why it must never
    /// be what a write is aimed at.
    var onScreen: ProjectDetailViewData? {
        switch self {
        case .none: nil
        case .pending(_, let onScreen): onScreen
        case .loaded(let detail): detail
        }
    }

    /// Rewrites the detail of one project wherever it is being held, landed or
    /// borrowed. Renaming a project must not depend on whether a round trip
    /// happens to be in flight.
    mutating func updateDetail(
        id: String,
        _ transform: (ProjectDetailViewData) -> ProjectDetailViewData
    ) {
        switch self {
        case .none:
            break
        case .pending(let pendingID, let onScreen):
            guard let onScreen, onScreen.id == id else { return }
            self = .pending(id: pendingID, onScreen: transform(onScreen))
        case .loaded(let detail):
            guard detail.id == id else { return }
            self = .loaded(transform(detail))
        }
    }

    /// The live state this named the owner of has been emptied, so nothing is on
    /// screen any more. The *choice* survives: a detail that failed to load
    /// leaves the project picked and the pane blank, which is what the user did.
    mutating func dropDetail() {
        self = id.map { Selection.pending(id: $0, onScreen: nil) } ?? .none
    }
}
