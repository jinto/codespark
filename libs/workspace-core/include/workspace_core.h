#ifndef WORKSPACE_CORE_H
#define WORKSPACE_CORE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct project_service project_service_t;

typedef enum project_status_t {
    PROJECT_STATUS_OK = 0,
    PROJECT_STATUS_OPEN_STORE_FAILED = 1,
    PROJECT_STATUS_CREATE_PROJECT_FAILED = 2,
    PROJECT_STATUS_UPDATE_PROJECT_NOTE_FAILED = 3,
    PROJECT_STATUS_PROJECT_DETAIL_FAILED = 4,
    PROJECT_STATUS_POISONED_STATE = 5,
    PROJECT_STATUS_LIST_PROJECTS_FAILED = 6,
    PROJECT_STATUS_RECONCILE_INTERRUPTED_FAILED = 7,
    PROJECT_STATUS_START_SESSION_FAILED = 8,
    PROJECT_STATUS_RECORD_SNAPSHOT_FAILED = 9,
    PROJECT_STATUS_CLOSE_SESSION_FAILED = 10,
    PROJECT_STATUS_RENAME_PROJECT_FAILED = 11,
    PROJECT_STATUS_DELETE_PROJECT_FAILED = 12,
} project_status_t;

typedef enum project_session_transport_t {
    PROJECT_SESSION_TRANSPORT_LOCAL = 0,
    PROJECT_SESSION_TRANSPORT_SSH = 1,
} project_session_transport_t;

typedef enum project_close_reason_t {
    PROJECT_CLOSE_REASON_USER_CLOSED = 0,
    PROJECT_CLOSE_REASON_PROCESS_EXITED = 1,
    PROJECT_CLOSE_REASON_SSH_DISCONNECTED = 2,
    PROJECT_CLOSE_REASON_APP_CRASHED = 3,
    PROJECT_CLOSE_REASON_HOST_QUIT = 4,
} project_close_reason_t;

typedef enum project_snapshot_kind_t {
    PROJECT_SNAPSHOT_KIND_CHECKPOINT = 0,
    PROJECT_SNAPSHOT_KIND_FINAL = 1,
} project_snapshot_kind_t;

typedef struct project_session_summary_t {
    char *id;
    char *title;
    project_session_transport_t transport;
    char *target_label;
    char *last_cwd;
    project_close_reason_t close_reason;
} project_session_summary_t;

typedef struct project_summary_t {
    char *id;
    char *name;
    char *path;
    project_session_transport_t transport;
    int64_t live_sessions;
    int64_t recently_closed_sessions;
    bool has_interrupted_sessions;
    int64_t updated_at;
    project_session_summary_t *live_session_details;
    int32_t live_session_detail_count;
} project_summary_t;

typedef struct project_detail_t {
    char *id;
    char *name;
    char *path;
    project_session_transport_t transport;
    project_session_summary_t *live_sessions;
    int32_t live_session_count;
} project_detail_t;

typedef struct project_new_session_t {
    const char *project_id;
    project_session_transport_t transport;
    const char *target_label;
    const char *title;
    const char *shell;
    const char *initial_cwd;
} project_new_session_t;

typedef struct project_new_snapshot_t {
    const char *session_id;
    project_snapshot_kind_t kind;
    const char *cwd;
    uint16_t cols;
    uint16_t rows;
    const char *const *lines;
    int32_t line_count;
} project_new_snapshot_t;

project_service_t *project_service_new(const char *store_path, project_status_t *out_status);
void project_service_free(project_service_t *service);

project_status_t project_service_start_session(
    project_service_t *service,
    const project_new_session_t *input,
    char **out_session_id
);

project_status_t project_service_record_snapshot(
    project_service_t *service,
    const project_new_snapshot_t *input
);

project_status_t project_service_close_session(
    project_service_t *service,
    const char *session_id,
    project_close_reason_t reason,
    const char *last_cwd
);

project_status_t project_service_update_session_title(
    project_service_t *service,
    const char *session_id,
    const char *new_title
);
project_status_t project_service_reconcile_interrupted_sessions(project_service_t *service);
project_status_t project_service_list_project_summaries(
    project_service_t *service,
    project_summary_t **out_summaries,
    int32_t *out_count
);
project_status_t project_service_create_project(
    project_service_t *service,
    const char *name,
    const char *path,
    project_session_transport_t transport,
    char **out_project_id
);
project_status_t project_service_rename_project(
    project_service_t *service,
    const char *project_id,
    const char *new_name
);
project_status_t project_service_delete_project(
    project_service_t *service,
    const char *project_id
);
project_status_t project_service_project_detail(
    project_service_t *service,
    const char *project_id,
    project_detail_t *out_detail
);

project_status_t project_service_find_project_by_cwd(
    project_service_t *service,
    const char *cwd,
    char **out_project_id
);

void project_free_string(char *value);
void project_free_summaries(project_summary_t *summaries, int32_t count);
void project_free_detail(project_detail_t *detail);

#ifdef __cplusplus
}
#endif

#endif
