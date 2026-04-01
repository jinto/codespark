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
