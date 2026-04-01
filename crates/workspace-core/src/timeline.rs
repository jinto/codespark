#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TimelineEventKind {
    WorkspaceCreated,
    SessionStarted,
    SnapshotFinalized,
    SessionClosed,
    SessionInterrupted,
    NoteUpdated,
}
