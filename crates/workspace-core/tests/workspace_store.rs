use std::fs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};
use workspace_core::Store;

#[test]
fn creates_and_lists_workspaces_in_recent_order() {
    let store = Store::open(":memory:").unwrap();
    store.create_workspace("spark3").unwrap();
    store.create_workspace("release").unwrap();

    let summaries = store.list_workspace_summaries().unwrap();
    let names: Vec<_> = summaries.iter().map(|item| item.name.as_str()).collect();

    assert_eq!(names, vec!["release", "spark3"]);
    assert_eq!(summaries[0].live_sessions, 0);
    assert_eq!(summaries[0].recently_closed_sessions, 0);
    assert!(!summaries[0].has_interrupted_sessions);
}

#[test]
fn memory_databases_do_not_share_state_across_connections() {
    let first = Store::open(":memory:").unwrap();
    first.create_workspace("spark3").unwrap();

    let second = Store::open(":memory:").unwrap();
    let summaries = second.list_workspace_summaries().unwrap();

    assert!(summaries.is_empty());
}

#[test]
fn file_backed_databases_persist_across_reopen() {
    let path = unique_db_path();

    {
        let store = Store::open(path.to_str().unwrap()).unwrap();
        store.create_workspace("spark3").unwrap();
    }

    let reopened = Store::open(path.to_str().unwrap()).unwrap();
    let summaries = reopened.list_workspace_summaries().unwrap();

    assert_eq!(summaries.len(), 1);
    assert_eq!(summaries[0].name, "spark3");

    let _ = fs::remove_file(path);
}

fn unique_db_path() -> PathBuf {
    static NEXT: AtomicU64 = AtomicU64::new(1);
    let stamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let suffix = NEXT.fetch_add(1, Ordering::Relaxed);
    std::env::temp_dir().join(format!("workspace-core-{stamp}-{suffix}.sqlite3"))
}
