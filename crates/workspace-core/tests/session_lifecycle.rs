use workspace_core::{CloseReason, NewSession, SessionTransport, Store};
use std::fs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

#[test]
fn closing_a_session_moves_it_to_recently_closed_and_persists_the_workspace_note() {
    let store = Store::open(":memory:").unwrap();
    let workspace_id = store.create_workspace("release").unwrap();

    store
        .update_workspace_note(&workspace_id, "check prod logs")
        .unwrap();
    let session_id = store
        .start_session(NewSession {
            workspace_id: workspace_id.clone(),
            transport: SessionTransport::Ssh,
            target_label: "prod".into(),
            title: "prod logs".into(),
            shell: "zsh".into(),
            initial_cwd: Some("/srv/app".into()),
        })
        .unwrap();

    store
        .close_session(
            &session_id,
            CloseReason::UserClosed,
            Some("/srv/app".into()),
            None,
        )
        .unwrap();

    let detail = store.workspace_detail(&workspace_id).unwrap();
    assert_eq!(detail.note_body, "check prod logs");
    assert_eq!(detail.live_sessions.len(), 0);
    assert_eq!(detail.closed_sessions.len(), 1);
    assert_eq!(detail.closed_sessions[0].title, "prod logs");
    assert_eq!(detail.closed_sessions[0].close_reason, CloseReason::UserClosed);
}

#[test]
fn file_backed_reopen_preserves_workspace_note_and_session_counts() {
    let path = unique_db_path();

    {
        let store = Store::open(path.to_str().unwrap()).unwrap();
        let workspace_id = store.create_workspace("release").unwrap();

        store
            .update_workspace_note(&workspace_id, "check prod logs")
            .unwrap();
        let session_id = store
            .start_session(NewSession {
                workspace_id: workspace_id.clone(),
                transport: SessionTransport::Ssh,
                target_label: "prod".into(),
                title: "prod logs".into(),
                shell: "zsh".into(),
                initial_cwd: Some("/srv/app".into()),
            })
            .unwrap();

        store
            .close_session(
                &session_id,
                CloseReason::UserClosed,
                Some("/srv/app".into()),
                None,
            )
            .unwrap();
    }

    let reopened = Store::open(path.to_str().unwrap()).unwrap();
    let summaries = reopened.list_workspace_summaries().unwrap();
    assert_eq!(summaries.len(), 1);
    assert_eq!(summaries[0].name, "release");
    assert_eq!(summaries[0].live_sessions, 0);
    assert_eq!(summaries[0].recently_closed_sessions, 1);
    assert!(!summaries[0].has_interrupted_sessions);

    let detail = reopened.workspace_detail(&summaries[0].id).unwrap();
    assert_eq!(detail.note_body, "check prod logs");
    assert_eq!(detail.live_sessions.len(), 0);
    assert_eq!(detail.closed_sessions.len(), 1);
    assert_eq!(detail.closed_sessions[0].title, "prod logs");

    let _ = fs::remove_file(path);
}

#[test]
fn closing_an_already_closed_session_keeps_existing_recovery_data() {
    let store = Store::open(":memory:").unwrap();
    let workspace_id = store.create_workspace("release").unwrap();

    let session_id = store
        .start_session(NewSession {
            workspace_id: workspace_id.clone(),
            transport: SessionTransport::Ssh,
            target_label: "prod".into(),
            title: "prod logs".into(),
            shell: "zsh".into(),
            initial_cwd: Some("/srv/app".into()),
        })
        .unwrap();

    store
        .close_session(
            &session_id,
            CloseReason::UserClosed,
            Some("/srv/app".into()),
            Some(0),
        )
        .unwrap();
    store
        .close_session(&session_id, CloseReason::AppCrashed, None, None)
        .unwrap();

    let detail = store.workspace_detail(&workspace_id).unwrap();
    assert_eq!(detail.closed_sessions.len(), 1);
    assert_eq!(detail.closed_sessions[0].close_reason, CloseReason::UserClosed);
    assert_eq!(detail.closed_sessions[0].last_cwd.as_deref(), Some("/srv/app"));
}

fn unique_db_path() -> PathBuf {
    static NEXT: AtomicU64 = AtomicU64::new(1);
    let stamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let suffix = NEXT.fetch_add(1, Ordering::Relaxed);
    std::env::temp_dir().join(format!("workspace-core-session-{stamp}-{suffix}.sqlite3"))
}
