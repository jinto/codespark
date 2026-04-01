use rusqlite::Connection;
use std::fs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};
use workspace_core::{
    CloseReason, NewSession, NewSnapshot, SessionTransport, SnapshotKind, Store, TerminalGrid,
};

#[test]
fn final_snapshot_and_restore_recipe_are_available_for_a_closed_ssh_session() {
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
        .record_snapshot(NewSnapshot {
            session_id: session_id.clone(),
            kind: SnapshotKind::Final,
            cwd: Some("/srv/app".into()),
            grid: TerminalGrid::from_lines(80, 24, &["tail -f log", "error line"]),
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
    assert_eq!(
        detail.closed_sessions[0].snapshot_preview.lines[1],
        "error line"
    );
    assert_eq!(
        detail.closed_sessions[0].restore_recipe.launch_command,
        "ssh prod -- 'cd /srv/app && exec zsh -l'"
    );
}

#[test]
fn restore_recipe_prefers_latest_snapshot_cwd_over_stale_session_paths() {
    let store = Store::open(":memory:").unwrap();
    let workspace_id = store.create_workspace("release").unwrap();
    let session_id = store
        .start_session(NewSession {
            workspace_id: workspace_id.clone(),
            transport: SessionTransport::Ssh,
            target_label: "prod".into(),
            title: "prod shell".into(),
            shell: "zsh".into(),
            initial_cwd: Some("/srv/app".into()),
        })
        .unwrap();

    store
        .record_snapshot(NewSnapshot {
            session_id: session_id.clone(),
            kind: SnapshotKind::Final,
            cwd: Some("/srv/app/releases/2026-04-01".into()),
            grid: TerminalGrid::from_lines(80, 24, &["pwd", "/srv/app/releases/2026-04-01"]),
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
    assert_eq!(
        detail.closed_sessions[0].restore_recipe.launch_command,
        "ssh prod -- 'cd /srv/app/releases/2026-04-01 && exec zsh -l'"
    );
}

#[test]
fn finalized_non_closed_states_are_hydrated_as_closed_session_summaries() {
    let path = unique_db_path();

    {
        let store = Store::open(path.to_str().unwrap()).unwrap();
        let workspace_id = store.create_workspace("release").unwrap();
        let session_id = store
            .start_session(NewSession {
                workspace_id: workspace_id.clone(),
                transport: SessionTransport::Ssh,
                target_label: "prod".into(),
                title: "prod worker".into(),
                shell: "bash".into(),
                initial_cwd: Some("/srv/app".into()),
            })
            .unwrap();

        store
            .record_snapshot(NewSnapshot {
                session_id: session_id.clone(),
                kind: SnapshotKind::Final,
                cwd: Some("/srv/app".into()),
                grid: TerminalGrid::from_lines(80, 24, &["deploy", "finished"]),
            })
            .unwrap();

        let conn = Connection::open(path.to_str().unwrap()).unwrap();
        conn.execute(
            "update sessions
             set state = 'exited',
                 close_reason = 'process_exited',
                 updated_at = updated_at + 1
             where id = ?1",
            [&session_id],
        )
        .unwrap();

        let detail = store.workspace_detail(&workspace_id).unwrap();
        assert_eq!(detail.closed_sessions.len(), 1);
        assert_eq!(detail.closed_sessions[0].title, "prod worker");
        assert_eq!(
            detail.closed_sessions[0].snapshot_preview.lines[1],
            "finished"
        );
        assert_eq!(
            detail.closed_sessions[0].restore_recipe.launch_command,
            "ssh prod -- 'cd /srv/app && exec bash -l'"
        );
    }

    let _ = fs::remove_file(path);
}

fn unique_db_path() -> PathBuf {
    static NEXT: AtomicU64 = AtomicU64::new(1);
    let stamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let suffix = NEXT.fetch_add(1, Ordering::Relaxed);
    std::env::temp_dir().join(format!(
        "workspace-core-snapshot-restore-{stamp}-{suffix}.sqlite3"
    ))
}
