const std = @import("std");
const models = @import("models.zig");
const store_mod = @import("store.zig");

// Re-export internal types for tests
pub const Store = store_mod.Store;
pub const StoreError = store_mod.StoreError;
pub const SessionTransport = models.SessionTransport;
pub const CloseReason = models.CloseReason;
pub const TimelineEventKind = models.TimelineEventKind;
pub const ProjectSummary = models.ProjectSummary;
pub const SessionSummary = models.SessionSummary;

const c_allocator = std.heap.c_allocator;

pub const project_status_t = enum(c_int) {
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
};

pub const project_session_transport_t = enum(c_int) {
    PROJECT_SESSION_TRANSPORT_LOCAL = 0,
    PROJECT_SESSION_TRANSPORT_SSH = 1,
};

pub const project_close_reason_t = enum(c_int) {
    PROJECT_CLOSE_REASON_USER_CLOSED = 0,
    PROJECT_CLOSE_REASON_PROCESS_EXITED = 1,
    PROJECT_CLOSE_REASON_SSH_DISCONNECTED = 2,
    PROJECT_CLOSE_REASON_APP_CRASHED = 3,
    PROJECT_CLOSE_REASON_HOST_QUIT = 4,
};

pub const project_snapshot_kind_t = enum(c_int) {
    PROJECT_SNAPSHOT_KIND_CHECKPOINT = 0,
    PROJECT_SNAPSHOT_KIND_FINAL = 1,
};

pub const project_session_summary_t = extern struct {
    id: ?[*:0]u8,
    title: ?[*:0]u8,
    transport: project_session_transport_t,
    target_label: ?[*:0]u8,
    last_cwd: ?[*:0]u8,
    close_reason: project_close_reason_t,
};

pub const project_summary_t = extern struct {
    id: ?[*:0]u8,
    name: ?[*:0]u8,
    path: ?[*:0]u8,
    transport: project_session_transport_t,
    live_sessions: i64,
    recently_closed_sessions: i64,
    has_interrupted_sessions: bool,
    updated_at: i64,
    live_session_details: ?[*]project_session_summary_t,
    live_session_detail_count: i32,
};

pub const project_detail_t = extern struct {
    id: ?[*:0]u8,
    name: ?[*:0]u8,
    path: ?[*:0]u8,
    transport: project_session_transport_t,
    live_sessions: ?[*]project_session_summary_t,
    live_session_count: i32,
};

pub const project_new_session_t = extern struct {
    project_id: ?[*:0]const u8,
    transport: project_session_transport_t,
    target_label: ?[*:0]const u8,
    title: ?[*:0]const u8,
    shell: ?[*:0]const u8,
    initial_cwd: ?[*:0]const u8,
};

pub const project_new_snapshot_t = extern struct {
    session_id: ?[*:0]const u8,
    kind: project_snapshot_kind_t,
    cwd: ?[*:0]const u8,
    cols: u16,
    rows: u16,
    lines: ?[*]const ?[*:0]const u8,
    line_count: i32,
};

pub const project_service = struct {
    mutex: std.Thread.Mutex = .{},
    store: store_mod.Store,
};

fn setStatus(out_status: ?*project_status_t, value: project_status_t) void {
    if (out_status) |ptr| ptr.* = value;
}

fn spanOrNull(value: ?[*:0]const u8) ?[]const u8 {
    if (value) |ptr| return std.mem.span(ptr);
    return null;
}

fn spanRequired(value: ?[*:0]const u8) ?[]const u8 {
    if (value) |ptr| return std.mem.span(ptr);
    return null;
}

fn dupCString(value: []const u8) ![*:0]u8 {
    return (try c_allocator.dupeZ(u8, value)).ptr;
}

fn dupOptionalCString(value: ?[]const u8) !?[*:0]u8 {
    if (value) |text| return try dupCString(text);
    return null;
}

fn toTransport(value: models.SessionTransport) project_session_transport_t {
    return switch (value) {
        .local => .PROJECT_SESSION_TRANSPORT_LOCAL,
        .ssh => .PROJECT_SESSION_TRANSPORT_SSH,
    };
}

fn fromTransport(value: project_session_transport_t) ?models.SessionTransport {
    return switch (value) {
        .PROJECT_SESSION_TRANSPORT_LOCAL => .local,
        .PROJECT_SESSION_TRANSPORT_SSH => .ssh,
    };
}

fn toCloseReason(value: models.CloseReason) project_close_reason_t {
    return switch (value) {
        .user_closed => .PROJECT_CLOSE_REASON_USER_CLOSED,
        .process_exited => .PROJECT_CLOSE_REASON_PROCESS_EXITED,
        .ssh_disconnected => .PROJECT_CLOSE_REASON_SSH_DISCONNECTED,
        .app_crashed => .PROJECT_CLOSE_REASON_APP_CRASHED,
        .host_quit => .PROJECT_CLOSE_REASON_HOST_QUIT,
    };
}

fn fromCloseReason(value: project_close_reason_t) ?models.CloseReason {
    return switch (value) {
        .PROJECT_CLOSE_REASON_USER_CLOSED => .user_closed,
        .PROJECT_CLOSE_REASON_PROCESS_EXITED => .process_exited,
        .PROJECT_CLOSE_REASON_SSH_DISCONNECTED => .ssh_disconnected,
        .PROJECT_CLOSE_REASON_APP_CRASHED => .app_crashed,
        .PROJECT_CLOSE_REASON_HOST_QUIT => .host_quit,
    };
}

fn fromSnapshotKind(value: project_snapshot_kind_t) ?models.SnapshotKind {
    return switch (value) {
        .PROJECT_SNAPSHOT_KIND_CHECKPOINT => .checkpoint,
        .PROJECT_SNAPSHOT_KIND_FINAL => .final,
    };
}

fn fillSessionSummary(out: *project_session_summary_t, value: models.SessionSummary) !void {
    out.* = std.mem.zeroes(project_session_summary_t);
    out.id = try dupCString(value.id);
    errdefer freeSessionSummary(out);
    out.title = try dupCString(value.title);
    out.transport = toTransport(value.transport);
    out.target_label = try dupCString(value.target_label);
    out.last_cwd = try dupOptionalCString(value.last_cwd);
    out.close_reason = toCloseReason(value.close_reason);
}

fn freeSessionSummary(value: *project_session_summary_t) void {
    project_free_string(value.id);
    project_free_string(value.title);
    project_free_string(value.target_label);
    project_free_string(value.last_cwd);
    value.* = std.mem.zeroes(project_session_summary_t);
}

fn fillProjectSummary(out: *project_summary_t, value: models.ProjectSummary) !void {
    out.* = std.mem.zeroes(project_summary_t);
    out.id = try dupCString(value.id);
    errdefer freeProjectSummary(out);
    out.name = try dupCString(value.name);
    out.path = try dupCString(value.path);
    out.transport = toTransport(value.transport);
    out.live_sessions = value.live_sessions;
    out.recently_closed_sessions = value.recently_closed_sessions;
    out.has_interrupted_sessions = value.has_interrupted_sessions;
    out.updated_at = value.updated_at;

    if (value.live_session_details.len > 0) {
        const details = try c_allocator.alloc(project_session_summary_t, value.live_session_details.len);
        errdefer c_allocator.free(details);
        for (details) |*d| d.* = std.mem.zeroes(project_session_summary_t);
        errdefer for (details) |*d| freeSessionSummary(d);

        for (value.live_session_details, 0..) |session, index| {
            try fillSessionSummary(&details[index], session);
        }
        out.live_session_details = details.ptr;
        out.live_session_detail_count = @intCast(details.len);
    }
}

fn freeProjectSummary(summary: *project_summary_t) void {
    project_free_string(summary.id);
    project_free_string(summary.name);
    project_free_string(summary.path);
    if (summary.live_session_details) |details| {
        const slice = details[0..@intCast(summary.live_session_detail_count)];
        for (slice) |*session| freeSessionSummary(session);
        c_allocator.free(slice);
    }
    summary.* = std.mem.zeroes(project_summary_t);
}

fn fillProjectDetail(out: *project_detail_t, value: models.ProjectDetail) !void {
    out.* = std.mem.zeroes(project_detail_t);
    out.id = try dupCString(value.id);
    errdefer project_free_detail(out);
    out.name = try dupCString(value.name);
    out.path = try dupCString(value.path);
    out.transport = toTransport(value.transport);

    if (value.live_sessions.len > 0) {
        const live_sessions = try c_allocator.alloc(project_session_summary_t, value.live_sessions.len);
        errdefer c_allocator.free(live_sessions);
        for (live_sessions) |*session| session.* = std.mem.zeroes(project_session_summary_t);
        errdefer for (live_sessions) |*session| freeSessionSummary(session);

        for (value.live_sessions, 0..) |session, index| {
            try fillSessionSummary(&live_sessions[index], session);
        }
        out.live_sessions = live_sessions.ptr;
        out.live_session_count = @intCast(live_sessions.len);
    }
}

pub export fn project_service_new(
    store_path: ?[*:0]const u8,
    out_status: ?*project_status_t,
) ?*project_service {
    const path = spanRequired(store_path) orelse {
        setStatus(out_status, .PROJECT_STATUS_OPEN_STORE_FAILED);
        return null;
    };

    const service = c_allocator.create(project_service) catch {
        setStatus(out_status, .PROJECT_STATUS_OPEN_STORE_FAILED);
        return null;
    };
    errdefer c_allocator.destroy(service);

    const store = store_mod.Store.open(path) catch {
        setStatus(out_status, .PROJECT_STATUS_OPEN_STORE_FAILED);
        return null;
    };

    service.* = .{ .store = store };
    setStatus(out_status, .PROJECT_STATUS_OK);
    return service;
}

pub export fn project_service_free(service: ?*project_service) void {
    if (service) |ptr| {
        ptr.store.deinit();
        c_allocator.destroy(ptr);
    }
}

pub export fn project_service_start_session(
    service: ?*project_service,
    input: ?*const project_new_session_t,
    out_session_id: ?*?[*:0]u8,
) project_status_t {
    if (out_session_id) |ptr| ptr.* = null;
    const ptr = service orelse return .PROJECT_STATUS_START_SESSION_FAILED;
    const raw = input orelse return .PROJECT_STATUS_START_SESSION_FAILED;

    const project_id = spanRequired(raw.project_id) orelse return .PROJECT_STATUS_START_SESSION_FAILED;
    const target_label = spanRequired(raw.target_label) orelse return .PROJECT_STATUS_START_SESSION_FAILED;
    const title = spanRequired(raw.title) orelse return .PROJECT_STATUS_START_SESSION_FAILED;
    const shell = spanRequired(raw.shell) orelse return .PROJECT_STATUS_START_SESSION_FAILED;
    const transport = fromTransport(raw.transport) orelse return .PROJECT_STATUS_START_SESSION_FAILED;

    ptr.mutex.lock();
    defer ptr.mutex.unlock();

    const session_id = ptr.store.startSession(c_allocator, .{
        .project_id = project_id,
        .transport = transport,
        .target_label = target_label,
        .title = title,
        .shell = shell,
        .initial_cwd = spanOrNull(raw.initial_cwd),
    }) catch return .PROJECT_STATUS_START_SESSION_FAILED;
    defer c_allocator.free(session_id);

    const out_value = dupCString(session_id) catch return .PROJECT_STATUS_START_SESSION_FAILED;
    if (out_session_id) |out| out.* = out_value;
    return .PROJECT_STATUS_OK;
}

pub export fn project_service_record_snapshot(
    service: ?*project_service,
    input: ?*const project_new_snapshot_t,
) project_status_t {
    const ptr = service orelse return .PROJECT_STATUS_RECORD_SNAPSHOT_FAILED;
    const raw = input orelse return .PROJECT_STATUS_RECORD_SNAPSHOT_FAILED;

    const session_id = spanRequired(raw.session_id) orelse return .PROJECT_STATUS_RECORD_SNAPSHOT_FAILED;
    const kind = fromSnapshotKind(raw.kind) orelse return .PROJECT_STATUS_RECORD_SNAPSHOT_FAILED;
    if (raw.line_count < 0 or raw.line_count > 10000) return .PROJECT_STATUS_RECORD_SNAPSHOT_FAILED;
    if (raw.line_count > 0 and raw.lines == null) return .PROJECT_STATUS_RECORD_SNAPSHOT_FAILED;

    const line_count: usize = @intCast(raw.line_count);
    const lines = c_allocator.alloc([]const u8, line_count) catch return .PROJECT_STATUS_RECORD_SNAPSHOT_FAILED;
    defer c_allocator.free(lines);
    for (lines, 0..) |*slot, index| {
        const line_ptr = raw.lines.?[index] orelse return .PROJECT_STATUS_RECORD_SNAPSHOT_FAILED;
        slot.* = std.mem.span(line_ptr);
    }

    ptr.mutex.lock();
    defer ptr.mutex.unlock();

    ptr.store.recordSnapshot(.{
        .session_id = session_id,
        .kind = kind,
        .cwd = spanOrNull(raw.cwd),
        .grid = .{
            .cols = raw.cols,
            .rows = raw.rows,
            .lines = lines,
        },
    }) catch return .PROJECT_STATUS_RECORD_SNAPSHOT_FAILED;

    return .PROJECT_STATUS_OK;
}

pub export fn project_service_close_session(
    service: ?*project_service,
    session_id: ?[*:0]const u8,
    reason: project_close_reason_t,
    last_cwd: ?[*:0]const u8,
) project_status_t {
    const ptr = service orelse return .PROJECT_STATUS_CLOSE_SESSION_FAILED;
    const session = spanRequired(session_id) orelse return .PROJECT_STATUS_CLOSE_SESSION_FAILED;
    const close_reason = fromCloseReason(reason) orelse return .PROJECT_STATUS_CLOSE_SESSION_FAILED;

    ptr.mutex.lock();
    defer ptr.mutex.unlock();

    ptr.store.closeSession(session, close_reason, spanOrNull(last_cwd)) catch return .PROJECT_STATUS_CLOSE_SESSION_FAILED;
    return .PROJECT_STATUS_OK;
}

pub export fn project_service_update_session_title(
    ptr: ?*project_service,
    session_id: ?[*:0]const u8,
    new_title: ?[*:0]const u8,
) project_status_t {
    const svc = ptr orelse return .PROJECT_STATUS_POISONED_STATE;
    svc.mutex.lock();
    defer svc.mutex.unlock();

    const sid = spanOrNull(session_id) orelse return .PROJECT_STATUS_CLOSE_SESSION_FAILED;
    const title = spanOrNull(new_title) orelse return .PROJECT_STATUS_CLOSE_SESSION_FAILED;

    svc.store.updateSessionTitle(sid, title) catch return .PROJECT_STATUS_CLOSE_SESSION_FAILED;
    return .PROJECT_STATUS_OK;
}

pub export fn project_service_reconcile_interrupted_sessions(
    service: ?*project_service,
) project_status_t {
    const ptr = service orelse return .PROJECT_STATUS_RECONCILE_INTERRUPTED_FAILED;

    ptr.mutex.lock();
    defer ptr.mutex.unlock();

    ptr.store.reconcileInterruptedSessions() catch return .PROJECT_STATUS_RECONCILE_INTERRUPTED_FAILED;
    return .PROJECT_STATUS_OK;
}

pub export fn project_service_list_project_summaries(
    service: ?*project_service,
    out_summaries: ?*?[*]project_summary_t,
    out_count: ?*i32,
) project_status_t {
    if (out_summaries) |ptr| ptr.* = null;
    if (out_count) |ptr| ptr.* = 0;
    const ptr = service orelse return .PROJECT_STATUS_LIST_PROJECTS_FAILED;

    ptr.mutex.lock();
    defer ptr.mutex.unlock();

    const summaries = ptr.store.listProjectSummaries(c_allocator) catch return .PROJECT_STATUS_LIST_PROJECTS_FAILED;
    defer {
        for (summaries) |*summary| summary.deinit(c_allocator);
        c_allocator.free(summaries);
    }

    if (summaries.len == 0) return .PROJECT_STATUS_OK;

    const output = c_allocator.alloc(project_summary_t, summaries.len) catch return .PROJECT_STATUS_LIST_PROJECTS_FAILED;
    errdefer {
        for (output) |*summary| freeProjectSummary(summary);
        c_allocator.free(output);
    }

    for (output) |*summary| summary.* = std.mem.zeroes(project_summary_t);
    for (summaries, 0..) |summary, index| {
        fillProjectSummary(&output[index], summary) catch return .PROJECT_STATUS_LIST_PROJECTS_FAILED;
    }

    if (out_summaries) |out| out.* = output.ptr;
    if (out_count) |out| out.* = @intCast(output.len);
    return .PROJECT_STATUS_OK;
}

pub export fn project_service_create_project(
    service: ?*project_service,
    name: ?[*:0]const u8,
    path: ?[*:0]const u8,
    transport: project_session_transport_t,
    out_project_id: ?*?[*:0]u8,
) project_status_t {
    if (out_project_id) |ptr| ptr.* = null;
    const ptr = service orelse return .PROJECT_STATUS_CREATE_PROJECT_FAILED;
    const project_name = spanRequired(name) orelse return .PROJECT_STATUS_CREATE_PROJECT_FAILED;
    const project_path = spanRequired(path) orelse return .PROJECT_STATUS_CREATE_PROJECT_FAILED;
    const project_transport = fromTransport(transport) orelse return .PROJECT_STATUS_CREATE_PROJECT_FAILED;

    ptr.mutex.lock();
    defer ptr.mutex.unlock();

    const project_id = ptr.store.createProject(c_allocator, project_name, project_path, project_transport) catch return .PROJECT_STATUS_CREATE_PROJECT_FAILED;
    defer c_allocator.free(project_id);

    const output = dupCString(project_id) catch return .PROJECT_STATUS_CREATE_PROJECT_FAILED;
    if (out_project_id) |out| out.* = output;
    return .PROJECT_STATUS_OK;
}

pub export fn project_service_rename_project(
    service: ?*project_service,
    project_id: ?[*:0]const u8,
    new_name: ?[*:0]const u8,
) project_status_t {
    const ptr = service orelse return .PROJECT_STATUS_RENAME_PROJECT_FAILED;
    const project = spanRequired(project_id) orelse return .PROJECT_STATUS_RENAME_PROJECT_FAILED;
    const name = spanRequired(new_name) orelse return .PROJECT_STATUS_RENAME_PROJECT_FAILED;

    ptr.mutex.lock();
    defer ptr.mutex.unlock();

    ptr.store.renameProject(project, name) catch return .PROJECT_STATUS_RENAME_PROJECT_FAILED;
    return .PROJECT_STATUS_OK;
}

pub export fn project_service_delete_project(
    service: ?*project_service,
    project_id: ?[*:0]const u8,
) project_status_t {
    const ptr = service orelse return .PROJECT_STATUS_DELETE_PROJECT_FAILED;
    const project = spanRequired(project_id) orelse return .PROJECT_STATUS_DELETE_PROJECT_FAILED;

    ptr.mutex.lock();
    defer ptr.mutex.unlock();

    ptr.store.deleteProject(project) catch return .PROJECT_STATUS_DELETE_PROJECT_FAILED;
    return .PROJECT_STATUS_OK;
}

pub export fn project_service_project_detail(
    service: ?*project_service,
    project_id: ?[*:0]const u8,
    out_detail: ?*project_detail_t,
) project_status_t {
    if (out_detail) |ptr| ptr.* = std.mem.zeroes(project_detail_t);
    const ptr = service orelse return .PROJECT_STATUS_PROJECT_DETAIL_FAILED;
    const project = spanRequired(project_id) orelse return .PROJECT_STATUS_PROJECT_DETAIL_FAILED;
    const output = out_detail orelse return .PROJECT_STATUS_PROJECT_DETAIL_FAILED;

    ptr.mutex.lock();
    defer ptr.mutex.unlock();

    var detail = ptr.store.projectDetail(c_allocator, project) catch return .PROJECT_STATUS_PROJECT_DETAIL_FAILED;
    defer detail.deinit(c_allocator);

    fillProjectDetail(output, detail) catch return .PROJECT_STATUS_PROJECT_DETAIL_FAILED;
    return .PROJECT_STATUS_OK;
}

pub export fn project_free_string(value: ?[*:0]u8) void {
    if (value) |ptr| {
        c_allocator.free(std.mem.span(ptr));
    }
}

pub export fn project_free_summaries(
    summaries: ?[*]project_summary_t,
    count: i32,
) void {
    if (summaries) |ptr| {
        const slice = ptr[0..@intCast(count)];
        for (slice) |*summary| freeProjectSummary(summary);
        c_allocator.free(slice);
    }
}

pub export fn project_free_detail(detail: ?*project_detail_t) void {
    if (detail) |ptr| {
        project_free_string(ptr.id);
        project_free_string(ptr.name);
        project_free_string(ptr.path);

        if (ptr.live_sessions) |live_sessions| {
            const slice = live_sessions[0..@intCast(ptr.live_session_count)];
            for (slice) |*session| freeSessionSummary(session);
            c_allocator.free(slice);
        }

        ptr.* = std.mem.zeroes(project_detail_t);
    }
}
