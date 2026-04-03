use std::sync::{Mutex, MutexGuard};

use workspace_core::Store;

// FFI boundary types: these mirror workspace_core types intentionally.
// UniFFI requires owned types defined in the FFI crate for code generation.
// Changes to core types must be reflected here and in api.udl.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SessionTransport {
    Local,
    Ssh,
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
pub struct TerminalGrid {
    pub cols: u16,
    pub rows: u16,
    pub lines: Vec<String>,
}

#[derive(Debug, Clone)]
pub struct RestoreRecipe {
    pub launch_command: String,
}

#[derive(Debug, Clone)]
pub struct WorkspaceSessionSummary {
    pub id: String,
    pub title: String,
    pub transport: SessionTransport,
    pub target_label: String,
    pub last_cwd: Option<String>,
    pub close_reason: CloseReason,
}

#[derive(Debug, Clone)]
pub struct WorkspaceClosedSessionSummary {
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
pub struct WorkspaceSummary {
    pub id: String,
    pub name: String,
    pub live_sessions: i64,
    pub recently_closed_sessions: i64,
    pub has_interrupted_sessions: bool,
    pub updated_at: i64,
}

#[derive(Debug, Clone)]
pub struct WorkspaceDetail {
    pub id: String,
    pub name: String,
    pub note_body: String,
    pub live_sessions: Vec<WorkspaceSessionSummary>,
    pub closed_sessions: Vec<WorkspaceClosedSessionSummary>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum WorkspaceServiceError {
    #[error("workspace service failed to open the store")]
    OpenStoreFailed,
    #[error("workspace service failed to create a workspace")]
    CreateWorkspaceFailed,
    #[error("workspace service failed to update the workspace note")]
    UpdateWorkspaceNoteFailed,
    #[error("workspace service failed to load workspace detail")]
    WorkspaceDetailFailed,
    #[error("workspace service lock poisoned")]
    PoisonedState,
    #[error("workspace service failed to list workspaces")]
    ListWorkspacesFailed,
    #[error("workspace service failed to reconcile interrupted sessions")]
    ReconcileInterruptedFailed,
}

pub struct WorkspaceService {
    store: Mutex<Store>,
}

impl WorkspaceService {
    pub fn new(store_path: String) -> Result<Self, WorkspaceServiceError> {
        let store = Store::open(&store_path).map_err(|_| WorkspaceServiceError::OpenStoreFailed)?;
        Ok(Self {
            store: Mutex::new(store),
        })
    }

    pub fn reconcile_interrupted_sessions(&self) -> Result<(), WorkspaceServiceError> {
        let store = self.store()?;
        store
            .reconcile_interrupted_sessions()
            .map_err(|_| WorkspaceServiceError::ReconcileInterruptedFailed)
    }

    pub fn list_workspace_summaries(&self) -> Result<Vec<WorkspaceSummary>, WorkspaceServiceError> {
        let store = self.store()?;
        store
            .list_workspace_summaries()
            .map(|v| v.into_iter().map(Into::into).collect())
            .map_err(|_| WorkspaceServiceError::ListWorkspacesFailed)
    }

    pub fn create_workspace(&self, name: String) -> Result<String, WorkspaceServiceError> {
        let store = self.store()?;
        store
            .create_workspace(&name)
            .map_err(|_| WorkspaceServiceError::CreateWorkspaceFailed)
    }

    pub fn update_workspace_note(
        &self,
        workspace_id: String,
        note_body: String,
    ) -> Result<(), WorkspaceServiceError> {
        let store = self.store()?;
        store
            .update_workspace_note(&workspace_id, &note_body)
            .map_err(|_| WorkspaceServiceError::UpdateWorkspaceNoteFailed)
    }

    pub fn workspace_detail(
        &self,
        workspace_id: String,
    ) -> Result<WorkspaceDetail, WorkspaceServiceError> {
        let store = self.store()?;
        store
            .workspace_detail(&workspace_id)
            .map(Into::into)
            .map_err(|_| WorkspaceServiceError::WorkspaceDetailFailed)
    }

    fn store(&self) -> Result<MutexGuard<'_, Store>, WorkspaceServiceError> {
        self.store
            .lock()
            .map_err(|_| WorkspaceServiceError::PoisonedState)
    }
}

impl From<workspace_core::WorkspaceSummary> for WorkspaceSummary {
    fn from(value: workspace_core::WorkspaceSummary) -> Self {
        Self {
            id: value.id,
            name: value.name,
            live_sessions: value.live_sessions,
            recently_closed_sessions: value.recently_closed_sessions,
            has_interrupted_sessions: value.has_interrupted_sessions,
            updated_at: value.updated_at,
        }
    }
}

impl From<workspace_core::SessionTransport> for SessionTransport {
    fn from(value: workspace_core::SessionTransport) -> Self {
        match value {
            workspace_core::SessionTransport::Local => Self::Local,
            workspace_core::SessionTransport::Ssh => Self::Ssh,
        }
    }
}

impl From<workspace_core::CloseReason> for CloseReason {
    fn from(value: workspace_core::CloseReason) -> Self {
        match value {
            workspace_core::CloseReason::UserClosed => Self::UserClosed,
            workspace_core::CloseReason::ProcessExited => Self::ProcessExited,
            workspace_core::CloseReason::SshDisconnected => Self::SshDisconnected,
            workspace_core::CloseReason::AppCrashed => Self::AppCrashed,
            workspace_core::CloseReason::HostQuit => Self::HostQuit,
        }
    }
}

impl From<workspace_core::TerminalGrid> for TerminalGrid {
    fn from(value: workspace_core::TerminalGrid) -> Self {
        Self {
            cols: value.cols,
            rows: value.rows,
            lines: value.lines,
        }
    }
}

impl From<workspace_core::RestoreRecipe> for RestoreRecipe {
    fn from(value: workspace_core::RestoreRecipe) -> Self {
        Self {
            launch_command: value.launch_command,
        }
    }
}

impl From<workspace_core::SessionSummary> for WorkspaceSessionSummary {
    fn from(value: workspace_core::SessionSummary) -> Self {
        Self {
            id: value.id,
            title: value.title,
            transport: value.transport.into(),
            target_label: value.target_label,
            last_cwd: value.last_cwd,
            close_reason: value.close_reason.into(),
        }
    }
}

impl From<workspace_core::ClosedSessionSummary> for WorkspaceClosedSessionSummary {
    fn from(value: workspace_core::ClosedSessionSummary) -> Self {
        Self {
            id: value.id,
            title: value.title,
            transport: value.transport.into(),
            target_label: value.target_label,
            last_cwd: value.last_cwd,
            close_reason: value.close_reason.into(),
            snapshot_preview: value.snapshot_preview.into(),
            restore_recipe: value.restore_recipe.into(),
        }
    }
}

impl From<workspace_core::WorkspaceDetail> for WorkspaceDetail {
    fn from(value: workspace_core::WorkspaceDetail) -> Self {
        Self {
            id: value.id,
            name: value.name,
            note_body: value.note_body,
            live_sessions: value.live_sessions.into_iter().map(Into::into).collect(),
            closed_sessions: value.closed_sessions.into_iter().map(Into::into).collect(),
        }
    }
}

uniffi::include_scaffolding!("api");
