use crate::{RestoreRecipe, TerminalGrid};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SessionTransport {
    Local,
    Ssh,
}

/// Session states that may appear in the database.
/// `Exited`, `Lost`, and `Crashed` are not set by Store methods directly
/// but may be written by external processes or future session-lifecycle code.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SessionState {
    Live,
    Closed,
    Exited,
    Lost,
    Crashed,
    Interrupted,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CloseReason {
    UserClosed,
    ProcessExited,
    SshDisconnected,
    AppCrashed,
    HostQuit,
}

#[derive(Debug, Clone)]
pub struct NewSession {
    pub workspace_id: String,
    pub transport: SessionTransport,
    pub target_label: String,
    pub title: String,
    pub shell: String,
    pub initial_cwd: Option<String>,
}

#[derive(Debug, Clone)]
pub struct SessionSummary {
    pub id: String,
    pub title: String,
    pub transport: SessionTransport,
    pub target_label: String,
    pub last_cwd: Option<String>,
    pub close_reason: CloseReason,
}

#[derive(Debug, Clone)]
pub struct ClosedSessionSummary {
    pub id: String,
    pub title: String,
    pub transport: SessionTransport,
    pub target_label: String,
    pub last_cwd: Option<String>,
    pub close_reason: CloseReason,
    pub snapshot_preview: TerminalGrid,
    pub restore_recipe: RestoreRecipe,
}

#[derive(Debug, Clone)]
pub struct WorkspaceDetail {
    pub id: String,
    pub name: String,
    pub note_body: String,
    pub live_sessions: Vec<SessionSummary>,
    pub closed_sessions: Vec<ClosedSessionSummary>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkspaceSummary {
    pub id: String,
    pub name: String,
    pub live_sessions: i64,
    pub recently_closed_sessions: i64,
    pub has_interrupted_sessions: bool,
    pub updated_at: i64,
}
