#ifndef WORKSPACE_CORE_H
#define WORKSPACE_CORE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct workspace_service workspace_service_t;

typedef enum workspace_status_t {
    WORKSPACE_STATUS_OK = 0,
    WORKSPACE_STATUS_OPEN_STORE_FAILED = 1,
    WORKSPACE_STATUS_CREATE_WORKSPACE_FAILED = 2,
    WORKSPACE_STATUS_UPDATE_WORKSPACE_NOTE_FAILED = 3,
    WORKSPACE_STATUS_WORKSPACE_DETAIL_FAILED = 4,
    WORKSPACE_STATUS_POISONED_STATE = 5,
    WORKSPACE_STATUS_LIST_WORKSPACES_FAILED = 6,
    WORKSPACE_STATUS_RECONCILE_INTERRUPTED_FAILED = 7,
    WORKSPACE_STATUS_START_SESSION_FAILED = 8,
    WORKSPACE_STATUS_RECORD_SNAPSHOT_FAILED = 9,
    WORKSPACE_STATUS_CLOSE_SESSION_FAILED = 10,
} workspace_status_t;

typedef enum workspace_session_transport_t {
    WORKSPACE_SESSION_TRANSPORT_LOCAL = 0,
    WORKSPACE_SESSION_TRANSPORT_SSH = 1,
} workspace_session_transport_t;

typedef enum workspace_close_reason_t {
    WORKSPACE_CLOSE_REASON_USER_CLOSED = 0,
    WORKSPACE_CLOSE_REASON_PROCESS_EXITED = 1,
    WORKSPACE_CLOSE_REASON_SSH_DISCONNECTED = 2,
    WORKSPACE_CLOSE_REASON_APP_CRASHED = 3,
    WORKSPACE_CLOSE_REASON_HOST_QUIT = 4,
} workspace_close_reason_t;

typedef enum workspace_snapshot_kind_t {
    WORKSPACE_SNAPSHOT_KIND_CHECKPOINT = 0,
    WORKSPACE_SNAPSHOT_KIND_FINAL = 1,
} workspace_snapshot_kind_t;

typedef struct workspace_terminal_grid_t {
    uint16_t cols;
    uint16_t rows;
    char **lines;
    int32_t line_count;
} workspace_terminal_grid_t;

typedef struct workspace_restore_recipe_t {
    char *launch_command;
} workspace_restore_recipe_t;

typedef struct workspace_session_summary_t {
    char *id;
    char *title;
    workspace_session_transport_t transport;
    char *target_label;
    char *last_cwd;
    workspace_close_reason_t close_reason;
} workspace_session_summary_t;

typedef struct workspace_closed_session_summary_t {
    char *id;
    char *title;
    workspace_session_transport_t transport;
    char *target_label;
    char *last_cwd;
    workspace_close_reason_t close_reason;
    workspace_terminal_grid_t snapshot_preview;
    workspace_restore_recipe_t restore_recipe;
} workspace_closed_session_summary_t;

typedef struct workspace_summary_t {
    char *id;
    char *name;
    int64_t live_sessions;
    int64_t recently_closed_sessions;
    bool has_interrupted_sessions;
    int64_t updated_at;
} workspace_summary_t;

typedef struct workspace_detail_t {
    char *id;
    char *name;
    char *note_body;
    workspace_session_summary_t *live_sessions;
    int32_t live_session_count;
    workspace_closed_session_summary_t *closed_sessions;
    int32_t closed_session_count;
} workspace_detail_t;

typedef struct workspace_new_session_t {
    const char *workspace_id;
    workspace_session_transport_t transport;
    const char *target_label;
    const char *title;
    const char *shell;
    const char *initial_cwd;
} workspace_new_session_t;

typedef struct workspace_new_snapshot_t {
    const char *session_id;
    workspace_snapshot_kind_t kind;
    const char *cwd;
    uint16_t cols;
    uint16_t rows;
    const char *const *lines;
    int32_t line_count;
} workspace_new_snapshot_t;

workspace_service_t *workspace_service_new(const char *store_path, workspace_status_t *out_status);
void workspace_service_free(workspace_service_t *service);

workspace_status_t workspace_service_start_session(
    workspace_service_t *service,
    const workspace_new_session_t *input,
    char **out_session_id
);

workspace_status_t workspace_service_record_snapshot(
    workspace_service_t *service,
    const workspace_new_snapshot_t *input
);

workspace_status_t workspace_service_close_session(
    workspace_service_t *service,
    const char *session_id,
    workspace_close_reason_t reason,
    const char *last_cwd
);

workspace_status_t workspace_service_reconcile_interrupted_sessions(workspace_service_t *service);
workspace_status_t workspace_service_list_workspace_summaries(
    workspace_service_t *service,
    workspace_summary_t **out_summaries,
    int32_t *out_count
);
workspace_status_t workspace_service_create_workspace(
    workspace_service_t *service,
    const char *name,
    char **out_workspace_id
);
workspace_status_t workspace_service_update_workspace_note(
    workspace_service_t *service,
    const char *workspace_id,
    const char *note_body
);
workspace_status_t workspace_service_workspace_detail(
    workspace_service_t *service,
    const char *workspace_id,
    workspace_detail_t *out_detail
);

void workspace_free_string(char *value);
void workspace_free_summaries(workspace_summary_t *summaries, int32_t count);
void workspace_free_detail(workspace_detail_t *detail);

#ifdef __cplusplus
}
#endif

#endif
