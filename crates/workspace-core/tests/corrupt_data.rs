mod common;

use rusqlite::{params, Connection};
use workspace_core::{
    CloseReason, NewSession, NewSnapshot, SessionTransport, SnapshotKind, Store, TerminalGrid,
};

#[test]
fn corrupt_transport_returns_error_instead_of_panic() {
    let path = common::unique_db_path("corrupt-transport");
    let store = Store::open(path.to_str().unwrap()).unwrap();
    let ws_id = store.create_workspace("test").unwrap();
    let session_id = store
        .start_session(NewSession {
            workspace_id: ws_id.clone(),
            transport: SessionTransport::Local,
            target_label: "local".into(),
            title: "shell".into(),
            shell: "zsh".into(),
            initial_cwd: None,
        })
        .unwrap();
    drop(store);

    // Corrupt via a second connection
    let conn = Connection::open(path.to_str().unwrap()).unwrap();
    conn.execute(
        "update sessions set transport = 'telepathy' where id = ?1",
        params![session_id],
    )
    .unwrap();
    drop(conn);

    let store = Store::open(path.to_str().unwrap()).unwrap();
    let result = store.workspace_detail(&ws_id);
    assert!(result.is_err(), "expected Err for unknown transport, got Ok");

    let _ = std::fs::remove_file(&path);
}

#[test]
fn corrupt_close_reason_returns_error_instead_of_panic() {
    let path = common::unique_db_path("corrupt-reason");
    let store = Store::open(path.to_str().unwrap()).unwrap();
    let ws_id = store.create_workspace("test").unwrap();
    let session_id = store
        .start_session(NewSession {
            workspace_id: ws_id.clone(),
            transport: SessionTransport::Local,
            target_label: "local".into(),
            title: "shell".into(),
            shell: "zsh".into(),
            initial_cwd: None,
        })
        .unwrap();

    store
        .close_session(&session_id, CloseReason::UserClosed, None, None)
        .unwrap();
    drop(store);

    let conn = Connection::open(path.to_str().unwrap()).unwrap();
    conn.execute(
        "update sessions set close_reason = 'alien_abduction' where id = ?1",
        params![session_id],
    )
    .unwrap();
    drop(conn);

    let store = Store::open(path.to_str().unwrap()).unwrap();
    let result = store.workspace_detail(&ws_id);
    assert!(result.is_err(), "expected Err for unknown close_reason, got Ok");

    let _ = std::fs::remove_file(&path);
}


#[test]
fn oversized_snapshot_cols_returns_error_instead_of_truncating() {
    let path = common::unique_db_path("corrupt-cols");
    let store = Store::open(path.to_str().unwrap()).unwrap();
    let ws_id = store.create_workspace("test").unwrap();
    let session_id = store
        .start_session(NewSession {
            workspace_id: ws_id.clone(),
            transport: SessionTransport::Local,
            target_label: "local".into(),
            title: "shell".into(),
            shell: "zsh".into(),
            initial_cwd: None,
        })
        .unwrap();

    store
        .record_snapshot(NewSnapshot {
            session_id: session_id.clone(),
            kind: SnapshotKind::Final,
            cwd: None,
            grid: TerminalGrid::from_lines(80, 24, &["hello"]),
        })
        .unwrap();

    store
        .close_session(&session_id, CloseReason::UserClosed, None, None)
        .unwrap();
    drop(store);

    // Set cols to a value that overflows u16 (max 65535)
    let conn = Connection::open(path.to_str().unwrap()).unwrap();
    conn.execute(
        "update snapshots set cols = 70000 where session_id = ?1",
        params![session_id],
    )
    .unwrap();
    drop(conn);

    let store = Store::open(path.to_str().unwrap()).unwrap();
    let result = store.workspace_detail(&ws_id);
    assert!(result.is_err(), "expected Err for oversized cols, got Ok");

    let _ = std::fs::remove_file(&path);
}
