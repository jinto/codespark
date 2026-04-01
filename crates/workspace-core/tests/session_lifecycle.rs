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
