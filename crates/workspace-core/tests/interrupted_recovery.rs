use workspace_core::{NewSession, SessionTransport, Store};

#[test]
fn unfinalized_live_sessions_are_marked_interrupted_on_next_launch() {
    let store = Store::open(":memory:").unwrap();
    let workspace_id = store.create_workspace("spark3").unwrap();
    store
        .start_session(NewSession {
            workspace_id: workspace_id.clone(),
            transport: SessionTransport::Local,
            target_label: "local".into(),
            title: "shell".into(),
            shell: "zsh".into(),
            initial_cwd: Some("/Users/jinto/projects/spark3".into()),
        })
        .unwrap();

    store.reconcile_interrupted_sessions().unwrap();

    let summaries = store.list_workspace_summaries().unwrap();
    assert!(summaries[0].has_interrupted_sessions);
}
