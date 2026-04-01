use std::sync::{Mutex, MutexGuard};

use workspace_core::Store;

#[derive(Debug, Clone)]
pub struct WorkspaceDetail {
    pub id: String,
    pub name: String,
    pub note_body: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum WorkspaceServiceError {
    #[error("workspace service operation failed")]
    OperationFailed,
    #[error("workspace service lock poisoned")]
    PoisonedState,
}

pub struct WorkspaceService {
    store: Mutex<Store>,
}

impl WorkspaceService {
    pub fn new() -> Result<Self, WorkspaceServiceError> {
        let store = Store::open(":memory:").map_err(|_| WorkspaceServiceError::OperationFailed)?;
        Ok(Self {
            store: Mutex::new(store),
        })
    }

    pub fn create_workspace(&self, name: String) -> Result<String, WorkspaceServiceError> {
        let store = self.store()?;
        store
            .create_workspace(&name)
            .map_err(|_| WorkspaceServiceError::OperationFailed)
    }

    pub fn update_workspace_note(
        &self,
        workspace_id: String,
        note_body: String,
    ) -> Result<(), WorkspaceServiceError> {
        let store = self.store()?;
        store
            .update_workspace_note(&workspace_id, &note_body)
            .map_err(|_| WorkspaceServiceError::OperationFailed)
    }

    pub fn workspace_detail(
        &self,
        workspace_id: String,
    ) -> Result<WorkspaceDetail, WorkspaceServiceError> {
        let store = self.store()?;
        store
            .workspace_detail(&workspace_id)
            .map(Into::into)
            .map_err(|_| WorkspaceServiceError::OperationFailed)
    }

    fn store(&self) -> Result<MutexGuard<'_, Store>, WorkspaceServiceError> {
        self.store
            .lock()
            .map_err(|_| WorkspaceServiceError::PoisonedState)
    }
}

impl From<workspace_core::WorkspaceDetail> for WorkspaceDetail {
    fn from(value: workspace_core::WorkspaceDetail) -> Self {
        Self {
            id: value.id,
            name: value.name,
            note_body: value.note_body,
        }
    }
}

uniffi::include_scaffolding!("api");
