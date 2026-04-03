const std = @import("std");
const models = @import("models.zig");
const restore = @import("restore.zig");

const sqlite = @cImport({
    @cInclude("sqlite3.h");
});

pub const StoreError = std.mem.Allocator.Error || error{
    Database,
    InvalidData,
};

pub const Store = struct {
    db: *sqlite.sqlite3,

    pub fn open(path: []const u8) StoreError!Store {
        const path_z = try std.heap.c_allocator.dupeZ(u8, path);
        defer std.heap.c_allocator.free(path_z);

        var db: ?*sqlite.sqlite3 = null;
        try checkSqlite(sqlite.sqlite3_open(path_z.ptr, &db), db);
        errdefer _ = sqlite.sqlite3_close(db);

        var store = Store{ .db = db.? };
        errdefer store.deinit();

        try store.execScript("pragma foreign_keys = on;");
        try store.migrate();
        return store;
    }

    pub fn deinit(self: *Store) void {
        _ = sqlite.sqlite3_close(self.db);
    }

    pub fn createWorkspace(self: *Store, allocator: std.mem.Allocator, name: []const u8) StoreError![]u8 {
        const updated_at = now();
        var stmt = try Statement.init(
            self.db,
            "insert into workspaces (id, name, note_body, updated_at, last_opened_at)\n" ++
                " values (lower(hex(randomblob(16))), ?1, '', ?2, ?2)",
        );
        defer stmt.deinit();
        try stmt.bindText(1, name);
        try stmt.bindInt64(2, updated_at);
        try stmt.expectDone();

        var select_stmt = try Statement.init(
            self.db,
            "select id from workspaces where rowid = last_insert_rowid()",
        );
        defer select_stmt.deinit();
        const has_row = try select_stmt.step();
        if (!has_row) return error.Database;
        return select_stmt.columnOwnedText(allocator, 0);
    }

    pub fn listWorkspaceSummaries(self: *Store, allocator: std.mem.Allocator) StoreError![]models.WorkspaceSummary {
        var stmt = try Statement.init(
            self.db,
            "select\n" ++
                "    w.id,\n" ++
                "    w.name,\n" ++
                "    w.updated_at,\n" ++
                "    coalesce(sum(case when s.state = 'live' then 1 else 0 end), 0),\n" ++
                "    coalesce(sum(case when s.state in ('closed','exited','lost','crashed') then 1 else 0 end), 0),\n" ++
                "    coalesce(max(case when s.state = 'interrupted' then 1 else 0 end), 0)\n" ++
                " from workspaces w\n" ++
                " left join sessions s on s.workspace_id = w.id\n" ++
                " group by w.id, w.name, w.updated_at\n" ++
                " order by w.updated_at desc, w.rowid desc",
        );
        defer stmt.deinit();

        var items: std.ArrayList(models.WorkspaceSummary) = .empty;
        defer items.deinit(allocator);

        while (try stmt.step()) {
            const workspace_id = try stmt.columnOwnedText(allocator, 0);
            errdefer allocator.free(workspace_id);
            const name = try stmt.columnOwnedText(allocator, 1);
            errdefer allocator.free(name);
            const live_session_details = try self.sessionsForWorkspace(allocator, workspace_id, .live);
            errdefer {
                for (live_session_details) |*session| session.deinit(allocator);
                allocator.free(live_session_details);
            }

            try items.append(allocator, .{
                .id = workspace_id,
                .name = name,
                .updated_at = stmt.columnInt64(2),
                .live_sessions = stmt.columnInt64(3),
                .live_session_details = live_session_details,
                .recently_closed_sessions = stmt.columnInt64(4),
                .has_interrupted_sessions = stmt.columnInt64(5) != 0,
            });
        }

        return items.toOwnedSlice(allocator);
    }

    pub fn updateWorkspaceNote(self: *Store, workspace_id: []const u8, note_body: []const u8) StoreError!void {
        const updated_at = now();
        var stmt = try Statement.init(
            self.db,
            "update workspaces\n" ++
                " set note_body = ?2, updated_at = ?3\n" ++
                " where id = ?1",
        );
        defer stmt.deinit();
        try stmt.bindText(1, workspace_id);
        try stmt.bindText(2, note_body);
        try stmt.bindInt64(3, updated_at);
        try stmt.expectDone();
    }

    pub fn renameWorkspace(self: *Store, workspace_id: []const u8, new_name: []const u8) StoreError!void {
        const updated_at = now();
        var stmt = try Statement.init(
            self.db,
            "update workspaces\n" ++
                " set name = ?2, updated_at = ?3\n" ++
                " where id = ?1",
        );
        defer stmt.deinit();
        try stmt.bindText(1, workspace_id);
        try stmt.bindText(2, new_name);
        try stmt.bindInt64(3, updated_at);
        try stmt.expectDone();
    }

    pub fn deleteWorkspace(self: *Store, workspace_id: []const u8) StoreError!void {
        var stmt = try Statement.init(
            self.db,
            "delete from workspaces where id = ?1",
        );
        defer stmt.deinit();
        try stmt.bindText(1, workspace_id);
        try stmt.expectDone();
    }

    pub fn updateSessionTitle(self: *Store, session_id: []const u8, new_title: []const u8) StoreError!void {
        var stmt = try Statement.init(
            self.db,
            "update sessions set title = ?2, updated_at = ?3 where id = ?1",
        );
        defer stmt.deinit();
        try stmt.bindText(1, session_id);
        try stmt.bindText(2, new_title);
        try stmt.bindInt64(3, now());
        try stmt.expectDone();
    }

    pub fn startSession(self: *Store, allocator: std.mem.Allocator, input: models.NewSession) StoreError![]u8 {
        const updated_at = now();
        var stmt = try Statement.init(
            self.db,
            "insert into sessions (\n" ++
                "    id, workspace_id, transport, target_label, title, shell,\n" ++
                "    initial_cwd, last_cwd, state, close_reason, exit_status,\n" ++
                "    updated_at, created_at\n" ++
                " )\n" ++
                " values (\n" ++
                "    lower(hex(randomblob(16))), ?1, ?2, ?3, ?4, ?5,\n" ++
                "    ?6, ?6, ?7, null, null,\n" ++
                "    ?8, ?8\n" ++
                " )",
        );
        defer stmt.deinit();
        try stmt.bindText(1, input.workspace_id);
        try stmt.bindText(2, input.transport.asSql());
        try stmt.bindText(3, input.target_label);
        try stmt.bindText(4, input.title);
        try stmt.bindText(5, input.shell);
        try stmt.bindOptionalText(6, input.initial_cwd);
        try stmt.bindText(7, models.SessionState.live.asSql());
        try stmt.bindInt64(8, updated_at);
        try stmt.expectDone();

        var select_stmt = try Statement.init(
            self.db,
            "select id from sessions where rowid = last_insert_rowid()",
        );
        defer select_stmt.deinit();
        if (!try select_stmt.step()) return error.Database;
        const session_id = try select_stmt.columnOwnedText(allocator, 0);
        errdefer allocator.free(session_id);

        try self.touchWorkspace(input.workspace_id);
        return session_id;
    }

    pub fn recordSnapshot(self: *Store, input: models.NewSnapshot) StoreError!void {
        const created_at = now();
        const payload = try encodeTerminalGridLines(input.grid);
        defer std.heap.c_allocator.free(payload);

        var stmt = try Statement.init(
            self.db,
            "insert into snapshots (\n" ++
                "    id, session_id, kind, cwd, cols, rows, line_count, payload, created_at\n" ++
                " )\n" ++
                " values (\n" ++
                "    lower(hex(randomblob(16))), ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8\n" ++
                " )",
        );
        defer stmt.deinit();
        try stmt.bindText(1, input.session_id);
        try stmt.bindText(2, input.kind.asSql());
        try stmt.bindOptionalText(3, input.cwd);
        try stmt.bindInt64(4, input.grid.cols);
        try stmt.bindInt64(5, input.grid.rows);
        try stmt.bindInt64(6, @intCast(input.grid.lines.len));
        try stmt.bindBlob(7, payload);
        try stmt.bindInt64(8, created_at);
        try stmt.expectDone();

        try self.touchWorkspaceBySession(input.session_id);
    }

    pub fn closeSession(
        self: *Store,
        session_id: []const u8,
        reason: models.CloseReason,
        last_cwd: ?[]const u8,
        exit_status: ?i64,
    ) StoreError!void {
        const updated_at = now();
        var stmt = try Statement.init(
            self.db,
            "update sessions\n" ++
                " set state = ?2,\n" ++
                "     close_reason = ?3,\n" ++
                "     last_cwd = coalesce(?4, last_cwd),\n" ++
                "     exit_status = ?5,\n" ++
                "     updated_at = ?6\n" ++
                " where id = ?1 and state = ?7",
        );
        defer stmt.deinit();
        try stmt.bindText(1, session_id);
        try stmt.bindText(2, models.SessionState.closed.asSql());
        try stmt.bindText(3, reason.asSql());
        try stmt.bindOptionalText(4, last_cwd);
        try stmt.bindOptionalInt64(5, exit_status);
        try stmt.bindInt64(6, updated_at);
        try stmt.bindText(7, models.SessionState.live.asSql());
        try stmt.expectDone();

        if (sqlite.sqlite3_changes(self.db) == 0) {
            if (try self.sessionExists(session_id)) return;
            return error.Database;
        }

        try self.touchWorkspaceBySession(session_id);
    }

    pub fn reconcileInterruptedSessions(self: *Store) StoreError!void {
        var select_stmt = try Statement.init(
            self.db,
            "select id\n" ++
                " from sessions\n" ++
                " where state = ?1",
        );
        defer select_stmt.deinit();
        try select_stmt.bindText(1, models.SessionState.live.asSql());

        var session_ids: std.ArrayList([]u8) = .empty;
        defer {
            for (session_ids.items) |id| std.heap.c_allocator.free(id);
            session_ids.deinit(std.heap.c_allocator);
        }

        while (try select_stmt.step()) {
            try session_ids.append(std.heap.c_allocator, try select_stmt.columnOwnedText(std.heap.c_allocator, 0));
        }

        var update_stmt = try Statement.init(
            self.db,
            "update sessions\n" ++
                " set state = ?1,\n" ++
                "     close_reason = ?2,\n" ++
                "     updated_at = ?3\n" ++
                " where state = ?4",
        );
        defer update_stmt.deinit();
        try update_stmt.bindText(1, models.SessionState.interrupted.asSql());
        try update_stmt.bindText(2, models.CloseReason.app_crashed.asSql());
        try update_stmt.bindInt64(3, now());
        try update_stmt.bindText(4, models.SessionState.live.asSql());
        try update_stmt.expectDone();

        for (session_ids.items) |id| {
            try self.touchWorkspaceBySession(id);
        }
    }

    pub fn workspaceDetail(self: *Store, allocator: std.mem.Allocator, workspace_id: []const u8) StoreError!models.WorkspaceDetail {
        var stmt = try Statement.init(
            self.db,
            "select id, name, note_body\n" ++
                " from workspaces\n" ++
                " where id = ?1",
        );
        defer stmt.deinit();
        try stmt.bindText(1, workspace_id);
        if (!try stmt.step()) return error.Database;

        const id = try stmt.columnOwnedText(allocator, 0);
        errdefer allocator.free(id);
        const name = try stmt.columnOwnedText(allocator, 1);
        errdefer allocator.free(name);
        const note_body = try stmt.columnOwnedText(allocator, 2);
        errdefer allocator.free(note_body);
        const live_sessions = try self.sessionsForWorkspace(allocator, workspace_id, .live);
        errdefer {
            for (live_sessions) |*session| session.deinit(allocator);
            allocator.free(live_sessions);
        }
        const closed_sessions = try self.closedSessionsForWorkspace(allocator, workspace_id);

        return .{
            .id = id,
            .name = name,
            .note_body = note_body,
            .live_sessions = live_sessions,
            .closed_sessions = closed_sessions,
        };
    }

    fn migrate(self: *Store) StoreError!void {
        try self.execScript(
            "create table if not exists workspaces (\n" ++
                "    id text primary key not null,\n" ++
                "    name text not null,\n" ++
                "    note_body text not null,\n" ++
                "    updated_at integer not null,\n" ++
                "    last_opened_at integer not null\n" ++
                ");\n" ++
                "\n" ++
                "create table if not exists sessions (\n" ++
                "    id text primary key not null,\n" ++
                "    workspace_id text not null references workspaces(id) on delete cascade,\n" ++
                "    transport text not null,\n" ++
                "    target_label text not null,\n" ++
                "    title text not null,\n" ++
                "    shell text not null,\n" ++
                "    initial_cwd text,\n" ++
                "    last_cwd text,\n" ++
                "    state text not null,\n" ++
                "    close_reason text,\n" ++
                "    exit_status integer,\n" ++
                "    updated_at integer not null,\n" ++
                "    created_at integer not null\n" ++
                ");\n" ++
                "\n" ++
                "create table if not exists snapshots (\n" ++
                "    id text primary key not null,\n" ++
                "    session_id text not null references sessions(id) on delete cascade,\n" ++
                "    kind text not null,\n" ++
                "    cwd text,\n" ++
                "    cols integer not null,\n" ++
                "    rows integer not null,\n" ++
                "    line_count integer not null,\n" ++
                "    payload blob not null,\n" ++
                "    created_at integer not null\n" ++
                ");\n" ++
                "\n" ++
                "create index if not exists idx_sessions_workspace_id on sessions(workspace_id);\n" ++
                "create index if not exists idx_sessions_state on sessions(state);\n" ++
                "create index if not exists idx_snapshots_session_id on snapshots(session_id);",
        );
    }

    fn sessionsForWorkspace(
        self: *Store,
        allocator: std.mem.Allocator,
        workspace_id: []const u8,
        state: models.SessionState,
    ) StoreError![]models.SessionSummary {
        var stmt = try Statement.init(
            self.db,
            "select id, title, transport, target_label, last_cwd, close_reason\n" ++
                " from sessions\n" ++
                " where workspace_id = ?1 and state = ?2\n" ++
                " order by updated_at desc, rowid desc",
        );
        defer stmt.deinit();
        try stmt.bindText(1, workspace_id);
        try stmt.bindText(2, state.asSql());

        var items: std.ArrayList(models.SessionSummary) = .empty;
        defer items.deinit(allocator);

        while (try stmt.step()) {
            const transport = try models.SessionTransport.fromSql(try stmt.columnTextSlice(2));
            const close_reason = if (try stmt.columnOptionalTextSlice(5)) |value|
                try models.CloseReason.fromSql(value)
            else
                models.CloseReason.user_closed;

            try items.append(allocator, .{
                .id = try stmt.columnOwnedText(allocator, 0),
                .title = try stmt.columnOwnedText(allocator, 1),
                .transport = transport,
                .target_label = try stmt.columnOwnedText(allocator, 3),
                .last_cwd = try stmt.columnOptionalOwnedText(allocator, 4),
                .close_reason = close_reason,
            });
        }

        return items.toOwnedSlice(allocator);
    }

    fn closedSessionsForWorkspace(self: *Store, allocator: std.mem.Allocator, workspace_id: []const u8) StoreError![]models.ClosedSessionSummary {
        var stmt = try Statement.init(
            self.db,
            "select\n" ++
                "    s.id, s.title, s.transport, s.target_label, s.shell,\n" ++
                "    s.initial_cwd, s.last_cwd, s.close_reason,\n" ++
                "    snap.cwd as snap_cwd, snap.cols, snap.rows, snap.line_count, snap.payload\n" ++
                " from sessions s\n" ++
                " left join snapshots snap on snap.id = (\n" ++
                "     select id from snapshots\n" ++
                "     where session_id = s.id\n" ++
                "     order by created_at desc, rowid desc\n" ++
                "     limit 1\n" ++
                " )\n" ++
                " where s.workspace_id = ?1\n" ++
                "   and s.state in ('closed', 'exited', 'lost', 'crashed', 'interrupted')\n" ++
                " order by s.updated_at desc, s.rowid desc",
        );
        defer stmt.deinit();
        try stmt.bindText(1, workspace_id);

        var items: std.ArrayList(models.ClosedSessionSummary) = .empty;
        defer items.deinit(allocator);

        while (try stmt.step()) {
            try items.append(allocator, try mapClosedSessionRow(allocator, &stmt));
        }

        return items.toOwnedSlice(allocator);
    }

    fn touchWorkspace(self: *Store, workspace_id: []const u8) StoreError!void {
        var stmt = try Statement.init(
            self.db,
            "update workspaces\n" ++
                " set updated_at = ?2\n" ++
                " where id = ?1",
        );
        defer stmt.deinit();
        try stmt.bindText(1, workspace_id);
        try stmt.bindInt64(2, now());
        try stmt.expectDone();
    }

    fn touchWorkspaceBySession(self: *Store, session_id: []const u8) StoreError!void {
        var stmt = try Statement.init(
            self.db,
            "update workspaces set updated_at = ?2\n" ++
                " where id = (select workspace_id from sessions where id = ?1)",
        );
        defer stmt.deinit();
        try stmt.bindText(1, session_id);
        try stmt.bindInt64(2, now());
        try stmt.expectDone();
    }

    fn sessionExists(self: *Store, session_id: []const u8) StoreError!bool {
        var stmt = try Statement.init(
            self.db,
            "select 1 from sessions where id = ?1",
        );
        defer stmt.deinit();
        try stmt.bindText(1, session_id);
        return stmt.step();
    }

    fn execScript(self: *Store, sql: []const u8) StoreError!void {
        const sql_z = try std.heap.c_allocator.dupeZ(u8, sql);
        defer std.heap.c_allocator.free(sql_z);

        var err_msg: [*c]u8 = null;
        defer if (err_msg) |msg| sqlite.sqlite3_free(msg);

        try checkSqlite(sqlite.sqlite3_exec(self.db, sql_z.ptr, null, null, &err_msg), self.db);
    }
};

const Statement = struct {
    db: *sqlite.sqlite3,
    stmt: *sqlite.sqlite3_stmt,

    fn init(db: *sqlite.sqlite3, sql: []const u8) StoreError!Statement {
        const sql_z = try std.heap.c_allocator.dupeZ(u8, sql);
        defer std.heap.c_allocator.free(sql_z);

        var stmt: ?*sqlite.sqlite3_stmt = null;
        try checkSqlite(sqlite.sqlite3_prepare_v2(db, sql_z.ptr, -1, &stmt, null), db);
        return .{ .db = db, .stmt = stmt.? };
    }

    fn deinit(self: *Statement) void {
        _ = sqlite.sqlite3_finalize(self.stmt);
    }

    fn bindText(self: *Statement, index: c_int, value: []const u8) StoreError!void {
        const empty = "";
        try checkSqlite(
            sqlite.sqlite3_bind_text(
                self.stmt,
                index,
                if (value.len == 0) @ptrCast(empty) else @ptrCast(value.ptr),
                @intCast(value.len),
                null,
            ),
            self.db,
        );
    }

    fn bindOptionalText(self: *Statement, index: c_int, value: ?[]const u8) StoreError!void {
        if (value) |text| {
            try self.bindText(index, text);
        } else {
            try checkSqlite(sqlite.sqlite3_bind_null(self.stmt, index), self.db);
        }
    }

    fn bindInt64(self: *Statement, index: c_int, value: i64) StoreError!void {
        try checkSqlite(sqlite.sqlite3_bind_int64(self.stmt, index, value), self.db);
    }

    fn bindOptionalInt64(self: *Statement, index: c_int, value: ?i64) StoreError!void {
        if (value) |number| {
            try self.bindInt64(index, number);
        } else {
            try checkSqlite(sqlite.sqlite3_bind_null(self.stmt, index), self.db);
        }
    }

    fn bindBlob(self: *Statement, index: c_int, value: []const u8) StoreError!void {
        try checkSqlite(
            sqlite.sqlite3_bind_blob(
                self.stmt,
                index,
                if (value.len == 0) null else value.ptr,
                @intCast(value.len),
                null,
            ),
            self.db,
        );
    }

    fn step(self: *Statement) StoreError!bool {
        return switch (sqlite.sqlite3_step(self.stmt)) {
            sqlite.SQLITE_ROW => true,
            sqlite.SQLITE_DONE => false,
            else => error.Database,
        };
    }

    fn expectDone(self: *Statement) StoreError!void {
        if (try self.step()) return error.Database;
    }

    fn columnInt64(self: *Statement, index: c_int) i64 {
        return sqlite.sqlite3_column_int64(self.stmt, index);
    }

    fn columnOwnedText(self: *Statement, allocator: std.mem.Allocator, index: c_int) StoreError![]u8 {
        return allocator.dupe(u8, try self.columnTextSlice(index));
    }

    fn columnOptionalOwnedText(self: *Statement, allocator: std.mem.Allocator, index: c_int) StoreError!?[]u8 {
        if (try self.columnOptionalTextSlice(index)) |value| {
            return @as(?[]u8, try allocator.dupe(u8, value));
        }
        return null;
    }

    fn columnTextSlice(self: *Statement, index: c_int) StoreError![]const u8 {
        if (sqlite.sqlite3_column_type(self.stmt, index) == sqlite.SQLITE_NULL) return error.InvalidData;
        const text = sqlite.sqlite3_column_text(self.stmt, index) orelse return error.InvalidData;
        return std.mem.span(text);
    }

    fn columnOptionalTextSlice(self: *Statement, index: c_int) StoreError!?[]const u8 {
        if (sqlite.sqlite3_column_type(self.stmt, index) == sqlite.SQLITE_NULL) return null;
        const text = sqlite.sqlite3_column_text(self.stmt, index) orelse return error.InvalidData;
        return std.mem.span(text);
    }

    fn columnBlobOwned(self: *Statement, allocator: std.mem.Allocator, index: c_int) StoreError![]u8 {
        const bytes = sqlite.sqlite3_column_bytes(self.stmt, index);
        const blob_ptr = sqlite.sqlite3_column_blob(self.stmt, index);
        if (bytes == 0) return allocator.alloc(u8, 0);
        if (blob_ptr == null) return error.InvalidData;
        const slice = @as([*]const u8, @ptrCast(blob_ptr.?))[0..@intCast(bytes)];
        return allocator.dupe(u8, slice);
    }
};

fn mapClosedSessionRow(allocator: std.mem.Allocator, stmt: *Statement) StoreError!models.ClosedSessionSummary {
    const transport = try models.SessionTransport.fromSql(try stmt.columnTextSlice(2));
    const initial_cwd = try stmt.columnOptionalTextSlice(5);
    const last_cwd = try stmt.columnOptionalTextSlice(6);
    const snapshot_cwd = try stmt.columnOptionalTextSlice(8);

    var snapshot_preview = if (sqlite.sqlite3_column_type(stmt.stmt, 9) == sqlite.SQLITE_NULL)
        try models.TerminalGrid.empty(allocator)
    else
        models.TerminalGrid{
            .cols = try safeU16(stmt.columnInt64(9)),
            .rows = try safeU16(stmt.columnInt64(10)),
            .lines = try decodeTerminalGridLines(
                allocator,
                stmt.columnInt64(11),
                try stmt.columnBlobOwned(allocator, 12),
            ),
        };
    errdefer snapshot_preview.deinit(allocator);

    const restore_cwd = if (snapshot_cwd) |value|
        try allocator.dupe(u8, value)
    else if (last_cwd) |value|
        try allocator.dupe(u8, value)
    else if (initial_cwd) |value|
        try allocator.dupe(u8, value)
    else
        null;
    errdefer if (restore_cwd) |value| allocator.free(value);

    const close_reason = if (try stmt.columnOptionalTextSlice(7)) |value|
        try models.CloseReason.fromSql(value)
    else
        models.CloseReason.user_closed;

    const shell = try stmt.columnTextSlice(4);
    const target_label = try stmt.columnTextSlice(3);
    var restore_recipe = try restore.buildRestoreRecipe(
        allocator,
        transport,
        target_label,
        shell,
        if (restore_cwd) |value| value else null,
    );
    errdefer restore_recipe.deinit(allocator);

    return .{
        .id = try stmt.columnOwnedText(allocator, 0),
        .title = try stmt.columnOwnedText(allocator, 1),
        .transport = transport,
        .target_label = try stmt.columnOwnedText(allocator, 3),
        .last_cwd = restore_cwd,
        .close_reason = close_reason,
        .snapshot_preview = snapshot_preview,
        .restore_recipe = restore_recipe,
    };
}

fn safeU16(value: i64) StoreError!u16 {
    if (value < 0 or value > std.math.maxInt(u16)) return error.InvalidData;
    return @intCast(value);
}

fn now() i64 {
    return @intCast(std.time.nanoTimestamp());
}

fn encodeTerminalGridLines(grid: models.TerminalGridInput) StoreError![]u8 {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(std.heap.c_allocator);

    for (grid.lines, 0..) |line, index| {
        if (index > 0) try buffer.append(std.heap.c_allocator, '\n');
        try buffer.appendSlice(std.heap.c_allocator, line);
    }

    return buffer.toOwnedSlice(std.heap.c_allocator);
}

fn decodeTerminalGridLines(allocator: std.mem.Allocator, line_count: i64, payload: []u8) StoreError![][]u8 {
    defer allocator.free(payload);

    if (line_count == 0) return allocator.alloc([]u8, 0);
    if (!std.unicode.utf8ValidateSlice(payload)) return error.InvalidData;

    var items: std.ArrayList([]u8) = .empty;
    defer items.deinit(allocator);

    var iter = std.mem.splitScalar(u8, payload, '\n');
    while (iter.next()) |line| {
        try items.append(allocator, try allocator.dupe(u8, line));
    }

    return items.toOwnedSlice(allocator);
}

fn checkSqlite(code: c_int, db: ?*sqlite.sqlite3) StoreError!void {
    if (code == sqlite.SQLITE_OK) return;
    if (code == sqlite.SQLITE_DONE) return;
    if (code == sqlite.SQLITE_ROW) return;
    _ = db;
    return error.Database;
}
