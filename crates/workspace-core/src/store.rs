use std::collections::HashMap;
use std::io;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

use crate::WorkspaceSummary;

static NEXT_SEQUENCE: AtomicU64 = AtomicU64::new(1);
static DATABASES: OnceLock<Mutex<HashMap<String, Vec<WorkspaceRecord>>>> = OnceLock::new();

#[derive(Clone)]
struct WorkspaceRecord {
    id: String,
    name: String,
    sequence: u64,
    updated_at: i64,
}

pub struct Store {
    path: String,
}

impl Store {
    pub fn open(path: &str) -> io::Result<Self> {
        let databases = DATABASES.get_or_init(|| Mutex::new(HashMap::new()));
        let mut databases = databases
            .lock()
            .map_err(|_| io::Error::new(io::ErrorKind::Other, "store lock poisoned"))?;
        databases.entry(path.to_string()).or_default();

        Ok(Self {
            path: path.to_string(),
        })
    }

    pub fn create_workspace(&self, name: &str) -> io::Result<String> {
        let sequence = NEXT_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        let id = format!("workspace-{}", sequence);
        let updated_at = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|_| io::Error::new(io::ErrorKind::Other, "system clock before epoch"))?
            .as_secs() as i64;
        let record = WorkspaceRecord {
            id: id.clone(),
            name: name.to_string(),
            sequence,
            updated_at,
        };

        let databases = DATABASES.get_or_init(|| Mutex::new(HashMap::new()));
        let mut databases = databases
            .lock()
            .map_err(|_| io::Error::new(io::ErrorKind::Other, "store lock poisoned"))?;
        let workspace = databases.entry(self.path.clone()).or_default();
        workspace.push(record);

        Ok(id)
    }

    pub fn list_workspace_summaries(&self) -> io::Result<Vec<WorkspaceSummary>> {
        let databases = DATABASES.get_or_init(|| Mutex::new(HashMap::new()));
        let databases = databases
            .lock()
            .map_err(|_| io::Error::new(io::ErrorKind::Other, "store lock poisoned"))?;
        let mut records = databases.get(&self.path).cloned().unwrap_or_default();
        records.sort_by(|left, right| {
            right
                .updated_at
                .cmp(&left.updated_at)
                .then_with(|| right.sequence.cmp(&left.sequence))
        });

        let summaries = records
            .into_iter()
            .map(|record| WorkspaceSummary {
                id: record.id,
                name: record.name,
                live_sessions: 0,
                recently_closed_sessions: 0,
                has_interrupted_sessions: false,
                updated_at: record.updated_at,
            })
            .collect();

        Ok(summaries)
    }
}
