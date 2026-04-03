const std = @import("std");
const models = @import("models.zig");
const store_mod = @import("store.zig");

// Re-export internal types for tests
pub const Store = store_mod.Store;
pub const StoreError = store_mod.StoreError;
pub const SessionTransport = models.SessionTransport;
pub const CloseReason = models.CloseReason;
pub const WorkspaceSummary = models.WorkspaceSummary;
pub const SessionSummary = models.SessionSummary;

const c_allocator = std.heap.c_allocator;

pub const workspace_status_t = enum(c_int) {
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
    WORKSPACE_STATUS_RENAME_WORKSPACE_FAILED = 11,
    WORKSPACE_STATUS_DELETE_WORKSPACE_FAILED = 12,
};

pub const workspace_session_transport_t = enum(c_int) {
    WORKSPACE_SESSION_TRANSPORT_LOCAL = 0,
    WORKSPACE_SESSION_TRANSPORT_SSH = 1,
};

pub const workspace_close_reason_t = enum(c_int) {
    WORKSPACE_CLOSE_REASON_USER_CLOSED = 0,
    WORKSPACE_CLOSE_REASON_PROCESS_EXITED = 1,
    WORKSPACE_CLOSE_REASON_SSH_DISCONNECTED = 2,
    WORKSPACE_CLOSE_REASON_APP_CRASHED = 3,
    WORKSPACE_CLOSE_REASON_HOST_QUIT = 4,
};

pub const workspace_snapshot_kind_t = enum(c_int) {
    WORKSPACE_SNAPSHOT_KIND_CHECKPOINT = 0,
    WORKSPACE_SNAPSHOT_KIND_FINAL = 1,
};

pub const workspace_terminal_grid_t = extern struct {
    cols: u16,
    rows: u16,
    lines: ?[*]?[*:0]u8,
    line_count: i32,
};

pub const workspace_restore_recipe_t = extern struct {
    launch_command: ?[*:0]u8,
};

pub const workspace_session_summary_t = extern struct {
    id: ?[*:0]u8,
    title: ?[*:0]u8,
    transport: workspace_session_transport_t,
    target_label: ?[*:0]u8,
    last_cwd: ?[*:0]u8,
    close_reason: workspace_close_reason_t,
};

pub const workspace_closed_session_summary_t = extern struct {
    id: ?[*:0]u8,
    title: ?[*:0]u8,
    transport: workspace_session_transport_t,
    target_label: ?[*:0]u8,
    last_cwd: ?[*:0]u8,
    close_reason: workspace_close_reason_t,
    snapshot_preview: workspace_terminal_grid_t,
    restore_recipe: workspace_restore_recipe_t,
};

pub const workspace_summary_t = extern struct {
    id: ?[*:0]u8,
    name: ?[*:0]u8,
    live_sessions: i64,
    recently_closed_sessions: i64,
    has_interrupted_sessions: bool,
    updated_at: i64,
    live_session_details: ?[*]workspace_session_summary_t,
    live_session_detail_count: i32,
};

pub const workspace_detail_t = extern struct {
    id: ?[*:0]u8,
    name: ?[*:0]u8,
    note_body: ?[*:0]u8,
    live_sessions: ?[*]workspace_session_summary_t,
    live_session_count: i32,
    closed_sessions: ?[*]workspace_closed_session_summary_t,
    closed_session_count: i32,
};

pub const workspace_new_session_t = extern struct {
    workspace_id: ?[*:0]const u8,
    transport: workspace_session_transport_t,
    target_label: ?[*:0]const u8,
    title: ?[*:0]const u8,
    shell: ?[*:0]const u8,
    initial_cwd: ?[*:0]const u8,
};

pub const workspace_new_snapshot_t = extern struct {
    session_id: ?[*:0]const u8,
    kind: workspace_snapshot_kind_t,
    cwd: ?[*:0]const u8,
    cols: u16,
    rows: u16,
    lines: ?[*]const ?[*:0]const u8,
    line_count: i32,
};

pub const workspace_service = struct {
    mutex: std.Thread.Mutex = .{},
    store: store_mod.Store,
};

fn setStatus(out_status: ?*workspace_status_t, value: workspace_status_t) void {
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

fn toTransport(value: models.SessionTransport) workspace_session_transport_t {
    return switch (value) {
        .local => .WORKSPACE_SESSION_TRANSPORT_LOCAL,
        .ssh => .WORKSPACE_SESSION_TRANSPORT_SSH,
    };
}

fn fromTransport(value: workspace_session_transport_t) ?models.SessionTransport {
    return switch (value) {
        .WORKSPACE_SESSION_TRANSPORT_LOCAL => .local,
        .WORKSPACE_SESSION_TRANSPORT_SSH => .ssh,
    };
}

fn toCloseReason(value: models.CloseReason) workspace_close_reason_t {
    return switch (value) {
        .user_closed => .WORKSPACE_CLOSE_REASON_USER_CLOSED,
        .process_exited => .WORKSPACE_CLOSE_REASON_PROCESS_EXITED,
        .ssh_disconnected => .WORKSPACE_CLOSE_REASON_SSH_DISCONNECTED,
        .app_crashed => .WORKSPACE_CLOSE_REASON_APP_CRASHED,
        .host_quit => .WORKSPACE_CLOSE_REASON_HOST_QUIT,
    };
}

fn fromCloseReason(value: workspace_close_reason_t) ?models.CloseReason {
    return switch (value) {
        .WORKSPACE_CLOSE_REASON_USER_CLOSED => .user_closed,
        .WORKSPACE_CLOSE_REASON_PROCESS_EXITED => .process_exited,
        .WORKSPACE_CLOSE_REASON_SSH_DISCONNECTED => .ssh_disconnected,
        .WORKSPACE_CLOSE_REASON_APP_CRASHED => .app_crashed,
        .WORKSPACE_CLOSE_REASON_HOST_QUIT => .host_quit,
    };
}

fn fromSnapshotKind(value: workspace_snapshot_kind_t) ?models.SnapshotKind {
    return switch (value) {
        .WORKSPACE_SNAPSHOT_KIND_CHECKPOINT => .checkpoint,
        .WORKSPACE_SNAPSHOT_KIND_FINAL => .final,
    };
}

fn fillTerminalGrid(out: *workspace_terminal_grid_t, grid: models.TerminalGrid) !void {
    out.* = std.mem.zeroes(workspace_terminal_grid_t);
    out.cols = grid.cols;
    out.rows = grid.rows;
    out.line_count = @intCast(grid.lines.len);
    if (grid.lines.len == 0) return;

    const lines = try c_allocator.alloc(?[*:0]u8, grid.lines.len);
    errdefer c_allocator.free(lines);
    for (lines) |*slot| slot.* = null;
    errdefer for (lines) |maybe_line| {
        if (maybe_line) |line| workspace_free_string(line);
    };

    for (grid.lines, 0..) |line, index| {
        lines[index] = try dupCString(line);
    }

    out.lines = lines.ptr;
}

fn freeTerminalGrid(grid: *workspace_terminal_grid_t) void {
    if (grid.lines) |lines| {
        const slice = lines[0..@intCast(grid.line_count)];
        for (slice) |maybe_line| {
            if (maybe_line) |line| workspace_free_string(line);
        }
        c_allocator.free(slice);
    }
    grid.* = std.mem.zeroes(workspace_terminal_grid_t);
}

fn fillSessionSummary(out: *workspace_session_summary_t, value: models.SessionSummary) !void {
    out.* = std.mem.zeroes(workspace_session_summary_t);
    out.id = try dupCString(value.id);
    errdefer freeSessionSummary(out);
    out.title = try dupCString(value.title);
    out.transport = toTransport(value.transport);
    out.target_label = try dupCString(value.target_label);
    out.last_cwd = try dupOptionalCString(value.last_cwd);
    out.close_reason = toCloseReason(value.close_reason);
}

fn freeSessionSummary(value: *workspace_session_summary_t) void {
    workspace_free_string(value.id);
    workspace_free_string(value.title);
    workspace_free_string(value.target_label);
    workspace_free_string(value.last_cwd);
    value.* = std.mem.zeroes(workspace_session_summary_t);
}

fn fillClosedSessionSummary(out: *workspace_closed_session_summary_t, value: models.ClosedSessionSummary) !void {
    out.* = std.mem.zeroes(workspace_closed_session_summary_t);
    out.id = try dupCString(value.id);
    errdefer freeClosedSessionSummary(out);
    out.title = try dupCString(value.title);
    out.transport = toTransport(value.transport);
    out.target_label = try dupCString(value.target_label);
    out.last_cwd = try dupOptionalCString(value.last_cwd);
    out.close_reason = toCloseReason(value.close_reason);
    try fillTerminalGrid(&out.snapshot_preview, value.snapshot_preview);
    out.restore_recipe.launch_command = try dupCString(value.restore_recipe.launch_command);
}

fn freeClosedSessionSummary(value: *workspace_closed_session_summary_t) void {
    workspace_free_string(value.id);
    workspace_free_string(value.title);
    workspace_free_string(value.target_label);
    workspace_free_string(value.last_cwd);
    freeTerminalGrid(&value.snapshot_preview);
    workspace_free_string(value.restore_recipe.launch_command);
    value.* = std.mem.zeroes(workspace_closed_session_summary_t);
}

fn fillWorkspaceSummary(out: *workspace_summary_t, value: models.WorkspaceSummary) !void {
    out.* = std.mem.zeroes(workspace_summary_t);
    out.id = try dupCString(value.id);
    errdefer freeWorkspaceSummary(out);
    out.name = try dupCString(value.name);
    out.live_sessions = value.live_sessions;
    out.recently_closed_sessions = value.recently_closed_sessions;
    out.has_interrupted_sessions = value.has_interrupted_sessions;
    out.updated_at = value.updated_at;

    if (value.live_session_details.len > 0) {
        const details = try c_allocator.alloc(workspace_session_summary_t, value.live_session_details.len);
        errdefer c_allocator.free(details);
        for (details) |*d| d.* = std.mem.zeroes(workspace_session_summary_t);
        errdefer for (details) |*d| freeSessionSummary(d);

        for (value.live_session_details, 0..) |session, index| {
            try fillSessionSummary(&details[index], session);
        }
        out.live_session_details = details.ptr;
        out.live_session_detail_count = @intCast(details.len);
    }
}

fn freeWorkspaceSummary(summary: *workspace_summary_t) void {
    workspace_free_string(summary.id);
    workspace_free_string(summary.name);
    if (summary.live_session_details) |details| {
        const slice = details[0..@intCast(summary.live_session_detail_count)];
        for (slice) |*session| freeSessionSummary(session);
        c_allocator.free(slice);
    }
    summary.* = std.mem.zeroes(workspace_summary_t);
}

fn fillWorkspaceDetail(out: *workspace_detail_t, value: models.WorkspaceDetail) !void {
    out.* = std.mem.zeroes(workspace_detail_t);
    out.id = try dupCString(value.id);
    errdefer workspace_free_detail(out);
    out.name = try dupCString(value.name);
    out.note_body = try dupCString(value.note_body);

    if (value.live_sessions.len > 0) {
        const live_sessions = try c_allocator.alloc(workspace_session_summary_t, value.live_sessions.len);
        errdefer c_allocator.free(live_sessions);
        for (live_sessions) |*session| session.* = std.mem.zeroes(workspace_session_summary_t);
        errdefer for (live_sessions) |*session| freeSessionSummary(session);

        for (value.live_sessions, 0..) |session, index| {
            try fillSessionSummary(&live_sessions[index], session);
        }
        out.live_sessions = live_sessions.ptr;
        out.live_session_count = @intCast(live_sessions.len);
    }

    if (value.closed_sessions.len > 0) {
        const closed_sessions = try c_allocator.alloc(workspace_closed_session_summary_t, value.closed_sessions.len);
        errdefer c_allocator.free(closed_sessions);
        for (closed_sessions) |*session| session.* = std.mem.zeroes(workspace_closed_session_summary_t);
        errdefer for (closed_sessions) |*session| freeClosedSessionSummary(session);

        for (value.closed_sessions, 0..) |session, index| {
            try fillClosedSessionSummary(&closed_sessions[index], session);
        }
        out.closed_sessions = closed_sessions.ptr;
        out.closed_session_count = @intCast(closed_sessions.len);
    }
}

pub export fn workspace_service_new(
    store_path: ?[*:0]const u8,
    out_status: ?*workspace_status_t,
) ?*workspace_service {
    const path = spanRequired(store_path) orelse {
        setStatus(out_status, .WORKSPACE_STATUS_OPEN_STORE_FAILED);
        return null;
    };

    const service = c_allocator.create(workspace_service) catch {
        setStatus(out_status, .WORKSPACE_STATUS_OPEN_STORE_FAILED);
        return null;
    };
    errdefer c_allocator.destroy(service);

    const store = store_mod.Store.open(path) catch {
        setStatus(out_status, .WORKSPACE_STATUS_OPEN_STORE_FAILED);
        return null;
    };

    service.* = .{ .store = store };
    setStatus(out_status, .WORKSPACE_STATUS_OK);
    return service;
}

pub export fn workspace_service_free(service: ?*workspace_service) void {
    if (service) |ptr| {
        ptr.store.deinit();
        c_allocator.destroy(ptr);
    }
}

pub export fn workspace_service_start_session(
    service: ?*workspace_service,
    input: ?*const workspace_new_session_t,
    out_session_id: ?*?[*:0]u8,
) workspace_status_t {
    if (out_session_id) |ptr| ptr.* = null;
    const ptr = service orelse return .WORKSPACE_STATUS_START_SESSION_FAILED;
    const raw = input orelse return .WORKSPACE_STATUS_START_SESSION_FAILED;

    const workspace_id = spanRequired(raw.workspace_id) orelse return .WORKSPACE_STATUS_START_SESSION_FAILED;
    const target_label = spanRequired(raw.target_label) orelse return .WORKSPACE_STATUS_START_SESSION_FAILED;
    const title = spanRequired(raw.title) orelse return .WORKSPACE_STATUS_START_SESSION_FAILED;
    const shell = spanRequired(raw.shell) orelse return .WORKSPACE_STATUS_START_SESSION_FAILED;
    const transport = fromTransport(raw.transport) orelse return .WORKSPACE_STATUS_START_SESSION_FAILED;

    ptr.mutex.lock();
    defer ptr.mutex.unlock();

    const session_id = ptr.store.startSession(c_allocator, .{
        .workspace_id = workspace_id,
        .transport = transport,
        .target_label = target_label,
        .title = title,
        .shell = shell,
        .initial_cwd = spanOrNull(raw.initial_cwd),
    }) catch return .WORKSPACE_STATUS_START_SESSION_FAILED;
    defer c_allocator.free(session_id);

    const out_value = dupCString(session_id) catch return .WORKSPACE_STATUS_START_SESSION_FAILED;
    if (out_session_id) |out| out.* = out_value;
    return .WORKSPACE_STATUS_OK;
}

pub export fn workspace_service_record_snapshot(
    service: ?*workspace_service,
    input: ?*const workspace_new_snapshot_t,
) workspace_status_t {
    const ptr = service orelse return .WORKSPACE_STATUS_RECORD_SNAPSHOT_FAILED;
    const raw = input orelse return .WORKSPACE_STATUS_RECORD_SNAPSHOT_FAILED;

    const session_id = spanRequired(raw.session_id) orelse return .WORKSPACE_STATUS_RECORD_SNAPSHOT_FAILED;
    const kind = fromSnapshotKind(raw.kind) orelse return .WORKSPACE_STATUS_RECORD_SNAPSHOT_FAILED;
    if (raw.line_count < 0) return .WORKSPACE_STATUS_RECORD_SNAPSHOT_FAILED;

    const line_count: usize = @intCast(raw.line_count);
    const lines = c_allocator.alloc([]const u8, line_count) catch return .WORKSPACE_STATUS_RECORD_SNAPSHOT_FAILED;
    defer c_allocator.free(lines);
    for (lines, 0..) |*slot, index| {
        const line_ptr = raw.lines.?[index] orelse return .WORKSPACE_STATUS_RECORD_SNAPSHOT_FAILED;
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
    }) catch return .WORKSPACE_STATUS_RECORD_SNAPSHOT_FAILED;

    return .WORKSPACE_STATUS_OK;
}

pub export fn workspace_service_close_session(
    service: ?*workspace_service,
    session_id: ?[*:0]const u8,
    reason: workspace_close_reason_t,
    last_cwd: ?[*:0]const u8,
) workspace_status_t {
    const ptr = service orelse return .WORKSPACE_STATUS_CLOSE_SESSION_FAILED;
    const session = spanRequired(session_id) orelse return .WORKSPACE_STATUS_CLOSE_SESSION_FAILED;
    const close_reason = fromCloseReason(reason) orelse return .WORKSPACE_STATUS_CLOSE_SESSION_FAILED;

    ptr.mutex.lock();
    defer ptr.mutex.unlock();

    ptr.store.closeSession(session, close_reason, spanOrNull(last_cwd), null) catch return .WORKSPACE_STATUS_CLOSE_SESSION_FAILED;
    return .WORKSPACE_STATUS_OK;
}

pub export fn workspace_service_update_session_title(
    ptr: ?*workspace_service,
    session_id: ?[*:0]const u8,
    new_title: ?[*:0]const u8,
) workspace_status_t {
    const svc = ptr orelse return .WORKSPACE_STATUS_POISONED_STATE;
    svc.mutex.lock();
    defer svc.mutex.unlock();

    const sid = spanOrNull(session_id) orelse return .WORKSPACE_STATUS_CLOSE_SESSION_FAILED;
    const title = spanOrNull(new_title) orelse return .WORKSPACE_STATUS_CLOSE_SESSION_FAILED;

    svc.store.updateSessionTitle(sid, title) catch return .WORKSPACE_STATUS_CLOSE_SESSION_FAILED;
    return .WORKSPACE_STATUS_OK;
}

pub export fn workspace_service_reconcile_interrupted_sessions(
    service: ?*workspace_service,
) workspace_status_t {
    const ptr = service orelse return .WORKSPACE_STATUS_RECONCILE_INTERRUPTED_FAILED;

    ptr.mutex.lock();
    defer ptr.mutex.unlock();

    ptr.store.reconcileInterruptedSessions() catch return .WORKSPACE_STATUS_RECONCILE_INTERRUPTED_FAILED;
    return .WORKSPACE_STATUS_OK;
}

pub export fn workspace_service_list_workspace_summaries(
    service: ?*workspace_service,
    out_summaries: ?*?[*]workspace_summary_t,
    out_count: ?*i32,
) workspace_status_t {
    if (out_summaries) |ptr| ptr.* = null;
    if (out_count) |ptr| ptr.* = 0;
    const ptr = service orelse return .WORKSPACE_STATUS_LIST_WORKSPACES_FAILED;

    ptr.mutex.lock();
    defer ptr.mutex.unlock();

    const summaries = ptr.store.listWorkspaceSummaries(c_allocator) catch return .WORKSPACE_STATUS_LIST_WORKSPACES_FAILED;
    defer {
        for (summaries) |*summary| summary.deinit(c_allocator);
        c_allocator.free(summaries);
    }

    if (summaries.len == 0) return .WORKSPACE_STATUS_OK;

    const output = c_allocator.alloc(workspace_summary_t, summaries.len) catch return .WORKSPACE_STATUS_LIST_WORKSPACES_FAILED;
    errdefer {
        for (output) |*summary| freeWorkspaceSummary(summary);
        c_allocator.free(output);
    }

    for (output) |*summary| summary.* = std.mem.zeroes(workspace_summary_t);
    for (summaries, 0..) |summary, index| {
        fillWorkspaceSummary(&output[index], summary) catch return .WORKSPACE_STATUS_LIST_WORKSPACES_FAILED;
    }

    if (out_summaries) |out| out.* = output.ptr;
    if (out_count) |out| out.* = @intCast(output.len);
    return .WORKSPACE_STATUS_OK;
}

pub export fn workspace_service_create_workspace(
    service: ?*workspace_service,
    name: ?[*:0]const u8,
    out_workspace_id: ?*?[*:0]u8,
) workspace_status_t {
    if (out_workspace_id) |ptr| ptr.* = null;
    const ptr = service orelse return .WORKSPACE_STATUS_CREATE_WORKSPACE_FAILED;
    const workspace_name = spanRequired(name) orelse return .WORKSPACE_STATUS_CREATE_WORKSPACE_FAILED;

    ptr.mutex.lock();
    defer ptr.mutex.unlock();

    const workspace_id = ptr.store.createWorkspace(c_allocator, workspace_name) catch return .WORKSPACE_STATUS_CREATE_WORKSPACE_FAILED;
    defer c_allocator.free(workspace_id);

    const output = dupCString(workspace_id) catch return .WORKSPACE_STATUS_CREATE_WORKSPACE_FAILED;
    if (out_workspace_id) |out| out.* = output;
    return .WORKSPACE_STATUS_OK;
}

pub export fn workspace_service_update_workspace_note(
    service: ?*workspace_service,
    workspace_id: ?[*:0]const u8,
    note_body: ?[*:0]const u8,
) workspace_status_t {
    const ptr = service orelse return .WORKSPACE_STATUS_UPDATE_WORKSPACE_NOTE_FAILED;
    const workspace = spanRequired(workspace_id) orelse return .WORKSPACE_STATUS_UPDATE_WORKSPACE_NOTE_FAILED;
    const note = spanRequired(note_body) orelse return .WORKSPACE_STATUS_UPDATE_WORKSPACE_NOTE_FAILED;

    ptr.mutex.lock();
    defer ptr.mutex.unlock();

    ptr.store.updateWorkspaceNote(workspace, note) catch return .WORKSPACE_STATUS_UPDATE_WORKSPACE_NOTE_FAILED;
    return .WORKSPACE_STATUS_OK;
}

pub export fn workspace_service_rename_workspace(
    service: ?*workspace_service,
    workspace_id: ?[*:0]const u8,
    new_name: ?[*:0]const u8,
) workspace_status_t {
    const ptr = service orelse return .WORKSPACE_STATUS_RENAME_WORKSPACE_FAILED;
    const workspace = spanRequired(workspace_id) orelse return .WORKSPACE_STATUS_RENAME_WORKSPACE_FAILED;
    const name = spanRequired(new_name) orelse return .WORKSPACE_STATUS_RENAME_WORKSPACE_FAILED;

    ptr.mutex.lock();
    defer ptr.mutex.unlock();

    ptr.store.renameWorkspace(workspace, name) catch return .WORKSPACE_STATUS_RENAME_WORKSPACE_FAILED;
    return .WORKSPACE_STATUS_OK;
}

pub export fn workspace_service_delete_workspace(
    service: ?*workspace_service,
    workspace_id: ?[*:0]const u8,
) workspace_status_t {
    const ptr = service orelse return .WORKSPACE_STATUS_DELETE_WORKSPACE_FAILED;
    const workspace = spanRequired(workspace_id) orelse return .WORKSPACE_STATUS_DELETE_WORKSPACE_FAILED;

    ptr.mutex.lock();
    defer ptr.mutex.unlock();

    ptr.store.deleteWorkspace(workspace) catch return .WORKSPACE_STATUS_DELETE_WORKSPACE_FAILED;
    return .WORKSPACE_STATUS_OK;
}

pub export fn workspace_service_workspace_detail(
    service: ?*workspace_service,
    workspace_id: ?[*:0]const u8,
    out_detail: ?*workspace_detail_t,
) workspace_status_t {
    if (out_detail) |ptr| ptr.* = std.mem.zeroes(workspace_detail_t);
    const ptr = service orelse return .WORKSPACE_STATUS_WORKSPACE_DETAIL_FAILED;
    const workspace = spanRequired(workspace_id) orelse return .WORKSPACE_STATUS_WORKSPACE_DETAIL_FAILED;
    const output = out_detail orelse return .WORKSPACE_STATUS_WORKSPACE_DETAIL_FAILED;

    ptr.mutex.lock();
    defer ptr.mutex.unlock();

    var detail = ptr.store.workspaceDetail(c_allocator, workspace) catch return .WORKSPACE_STATUS_WORKSPACE_DETAIL_FAILED;
    defer detail.deinit(c_allocator);

    fillWorkspaceDetail(output, detail) catch return .WORKSPACE_STATUS_WORKSPACE_DETAIL_FAILED;
    return .WORKSPACE_STATUS_OK;
}

pub export fn workspace_free_string(value: ?[*:0]u8) void {
    if (value) |ptr| {
        c_allocator.free(std.mem.span(ptr));
    }
}

pub export fn workspace_free_summaries(
    summaries: ?[*]workspace_summary_t,
    count: i32,
) void {
    if (summaries) |ptr| {
        const slice = ptr[0..@intCast(count)];
        for (slice) |*summary| freeWorkspaceSummary(summary);
        c_allocator.free(slice);
    }
}

pub export fn workspace_free_detail(detail: ?*workspace_detail_t) void {
    if (detail) |ptr| {
        workspace_free_string(ptr.id);
        workspace_free_string(ptr.name);
        workspace_free_string(ptr.note_body);

        if (ptr.live_sessions) |live_sessions| {
            const slice = live_sessions[0..@intCast(ptr.live_session_count)];
            for (slice) |*session| freeSessionSummary(session);
            c_allocator.free(slice);
        }

        if (ptr.closed_sessions) |closed_sessions| {
            const slice = closed_sessions[0..@intCast(ptr.closed_session_count)];
            for (slice) |*session| freeClosedSessionSummary(session);
            c_allocator.free(slice);
        }

        ptr.* = std.mem.zeroes(workspace_detail_t);
    }
}
