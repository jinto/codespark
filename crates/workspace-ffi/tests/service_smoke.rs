use std::fs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use workspace_core::{CloseReason, NewSession, SessionTransport, Store};
use workspace_ffi::{WorkspaceService, WorkspaceServiceError};

#[test]
fn workspace_service_returns_workspace_detail_for_swift() {
    let service = WorkspaceService::new(":memory:".to_string()).unwrap();
    let workspace_id = service.create_workspace("spark3".to_string()).unwrap();
    service
        .update_workspace_note(workspace_id.clone(), "check release flow".to_string())
        .unwrap();

    let detail = service.workspace_detail(workspace_id).unwrap();
    assert_eq!(detail.name, "spark3");
    assert_eq!(detail.note_body, "check release flow");
}

#[test]
fn workspace_service_file_store_exposes_live_and_closed_sessions() {
    let path = unique_db_path();
    let store_path = path.to_str().unwrap().to_string();

    let workspace_id = {
        let service = WorkspaceService::new(store_path.clone()).unwrap();
        let workspace_id = service.create_workspace("release".to_string()).unwrap();
        service
            .update_workspace_note(workspace_id.clone(), "check prod logs".to_string())
            .unwrap();
        workspace_id
    };

    {
        let store = Store::open(path.to_str().unwrap()).unwrap();
        store
            .start_session(NewSession {
                workspace_id: workspace_id.clone(),
                transport: SessionTransport::Local,
                target_label: "local".into(),
                title: "live shell".into(),
                shell: "zsh".into(),
                initial_cwd: Some("/tmp".into()),
            })
            .unwrap();

        let closed_session_id = store
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
                &closed_session_id,
                CloseReason::UserClosed,
                Some("/srv/app".into()),
                None,
            )
            .unwrap();
    }

    let service = WorkspaceService::new(store_path).unwrap();
    let detail = service.workspace_detail(workspace_id).unwrap();

    assert_eq!(detail.live_sessions.len(), 1);
    assert_eq!(detail.live_sessions[0].title, "live shell");
    assert_eq!(
        detail.live_sessions[0].transport,
        workspace_ffi::SessionTransport::Local
    );
    assert_eq!(detail.closed_sessions.len(), 1);
    assert_eq!(detail.closed_sessions[0].title, "prod logs");
    assert_eq!(
        detail.closed_sessions[0].close_reason,
        workspace_ffi::CloseReason::UserClosed
    );
    assert_eq!(
        detail.closed_sessions[0].restore_recipe.launch_command,
        "ssh prod -- 'cd /srv/app && exec zsh -l'"
    );
    assert!(detail.closed_sessions[0].snapshot_preview.lines.is_empty());

    let _ = fs::remove_file(path);
}

#[test]
fn workspace_detail_reports_which_operation_failed() {
    let service = WorkspaceService::new(":memory:".to_string()).unwrap();

    let result = service.workspace_detail("missing-workspace".to_string());

    assert_eq!(
        result.unwrap_err(),
        WorkspaceServiceError::WorkspaceDetailFailed
    );
}

fn unique_db_path() -> PathBuf {
    static NEXT: AtomicU64 = AtomicU64::new(1);
    let stamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let suffix = NEXT.fetch_add(1, Ordering::Relaxed);
    std::env::temp_dir().join(format!("workspace-ffi-service-{stamp}-{suffix}.sqlite3"))
}
