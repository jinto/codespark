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
