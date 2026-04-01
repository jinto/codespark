use workspace_ffi::WorkspaceService;

#[test]
fn workspace_service_returns_workspace_detail_for_swift() {
    let service = WorkspaceService::new().unwrap();
    let workspace_id = service.create_workspace("spark3".to_string()).unwrap();
    service
        .update_workspace_note(workspace_id.clone(), "check release flow".to_string())
        .unwrap();

    let detail = service.workspace_detail(workspace_id).unwrap();
    assert_eq!(detail.name, "spark3");
    assert_eq!(detail.note_body, "check release flow");
}
