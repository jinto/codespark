use crate::{RestoreRecipe, TerminalGrid};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SessionTransport {
    Local,
    Ssh,
}

impl SessionTransport {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Local => "local",
            Self::Ssh => "ssh",
        }
    }

    pub fn from_sql_str(value: &str) -> rusqlite::Result<Self> {
        match value {
            "local" => Ok(Self::Local),
            "ssh" => Ok(Self::Ssh),
            other => Err(rusqlite::Error::FromSqlConversionFailure(
                0,
                rusqlite::types::Type::Text,
                format!("unknown session transport: {other}").into(),
            )),
        }
    }
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

impl SessionState {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Live => "live",
            Self::Closed => "closed",
            Self::Exited => "exited",
            Self::Lost => "lost",
            Self::Crashed => "crashed",
            Self::Interrupted => "interrupted",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CloseReason {
    UserClosed,
    ProcessExited,
    SshDisconnected,
    AppCrashed,
    HostQuit,
}

impl CloseReason {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::UserClosed => "user_closed",
            Self::ProcessExited => "process_exited",
            Self::SshDisconnected => "ssh_disconnected",
            Self::AppCrashed => "app_crashed",
            Self::HostQuit => "host_quit",
        }
    }

    pub fn from_sql_str(value: &str) -> rusqlite::Result<Self> {
        match value {
            "user_closed" => Ok(Self::UserClosed),
            "process_exited" => Ok(Self::ProcessExited),
            "ssh_disconnected" => Ok(Self::SshDisconnected),
            "app_crashed" => Ok(Self::AppCrashed),
            "host_quit" => Ok(Self::HostQuit),
            other => Err(rusqlite::Error::FromSqlConversionFailure(
                0,
                rusqlite::types::Type::Text,
                format!("unknown close reason: {other}").into(),
            )),
        }
    }
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
