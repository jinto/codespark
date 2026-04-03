mod common;

use rusqlite::Connection;
use std::fs;
use workspace_core::{CloseReason, NewSession, SessionTransport, Store};

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
    let path = common::unique_db_path("session-lifecycle");

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

#[test]
fn session_activity_updates_workspace_list_recency() {
    let path = common::unique_db_path("session-lifecycle");

    {
        let store = Store::open(path.to_str().unwrap()).unwrap();
        let alpha_id = store.create_workspace("alpha").unwrap();
        let beta_id = store.create_workspace("beta").unwrap();

        let after_create = store.list_workspace_summaries().unwrap();
        assert_eq!(after_create[0].id, beta_id);
        assert_eq!(after_create[1].id, alpha_id);

        let session_id = store
            .start_session(NewSession {
                workspace_id: alpha_id.clone(),
                transport: SessionTransport::Local,
                target_label: "local".into(),
                title: "alpha session".into(),
                shell: "zsh".into(),
                initial_cwd: None,
            })
            .unwrap();

        let after_start = store.list_workspace_summaries().unwrap();
        assert_eq!(after_start[0].id, alpha_id);

        let gamma_id = store.create_workspace("gamma").unwrap();
        let after_gamma = store.list_workspace_summaries().unwrap();
        assert_eq!(after_gamma[0].id, gamma_id);

        store
            .close_session(
                &session_id,
                CloseReason::UserClosed,
                Some("/tmp".into()),
                None,
            )
            .unwrap();

        let after_close = store.list_workspace_summaries().unwrap();
        assert_eq!(after_close[0].id, alpha_id);
    }

    let _ = fs::remove_file(path);
}

#[test]
fn start_session_rejects_missing_workspace_without_creating_orphan_row() {
    let path = common::unique_db_path("session-lifecycle");
    let store = Store::open(path.to_str().unwrap()).unwrap();

    let result = store.start_session(NewSession {
        workspace_id: "missing-workspace".into(),
        transport: SessionTransport::Local,
        target_label: "local".into(),
        title: "orphan".into(),
        shell: "zsh".into(),
        initial_cwd: None,
    });

    assert!(result.is_err());

    let conn = Connection::open(path.to_str().unwrap()).unwrap();
    let session_count: i64 = conn
        .query_row("select count(*) from sessions", [], |row| row.get(0))
        .unwrap();
    assert_eq!(session_count, 0);

    let _ = fs::remove_file(path);
}

