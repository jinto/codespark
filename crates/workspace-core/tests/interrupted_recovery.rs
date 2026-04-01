use workspace_core::{
    NewSession, NewSnapshot, SessionTransport, SnapshotKind, Store, TerminalGrid,
};

#[test]
fn unfinalized_live_sessions_are_marked_interrupted_on_next_launch() {
    let store = Store::open(":memory:").unwrap();
    let workspace_id = store.create_workspace("spark3").unwrap();
    let session_id = store
        .start_session(NewSession {
            workspace_id: workspace_id.clone(),
            transport: SessionTransport::Local,
            target_label: "local".into(),
            title: "shell".into(),
            shell: "zsh".into(),
            initial_cwd: Some("/Users/jinto/projects/spark3".into()),
        })
        .unwrap();
    store
        .record_snapshot(NewSnapshot {
            session_id,
            kind: SnapshotKind::Checkpoint,
            cwd: Some("/Users/jinto/projects/spark3/crates/workspace-core".into()),
            grid: TerminalGrid::from_lines(80, 24, &["cargo test", "waiting"]),
        })
        .unwrap();

    store.reconcile_interrupted_sessions().unwrap();

    let summaries = store.list_workspace_summaries().unwrap();
    assert!(summaries[0].has_interrupted_sessions);

    let detail = store.workspace_detail(&workspace_id).unwrap();
    assert_eq!(detail.closed_sessions.len(), 1);
    assert_eq!(
        detail.closed_sessions[0].snapshot_preview.lines[0],
        "cargo test"
    );
    assert_eq!(
        detail.closed_sessions[0].close_reason,
        workspace_core::CloseReason::AppCrashed
    );
    assert_eq!(
        detail.closed_sessions[0].restore_recipe.launch_command,
        "cd /Users/jinto/projects/spark3/crates/workspace-core && exec zsh -l"
    );
}
