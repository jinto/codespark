const std = @import("std");
const models = @import("models.zig");

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

    pub fn createProject(
        self: *Store,
        allocator: std.mem.Allocator,
        name: []const u8,
        path: []const u8,
        transport: models.SessionTransport,
    ) StoreError![]u8 {
        const updated_at = now();
        var stmt = try Statement.init(
            self.db,
            "insert into projects (id, name, path, transport, note_body, updated_at, last_opened_at)\n" ++
                " values (lower(hex(randomblob(16))), ?1, ?2, ?3, '', ?4, ?4)",
        );
        defer stmt.deinit();
        try stmt.bindText(1, name);
        try stmt.bindText(2, path);
        try stmt.bindText(3, transport.asSql());
        try stmt.bindInt64(4, updated_at);
        try stmt.expectDone();

        var select_stmt = try Statement.init(
            self.db,
            "select id from projects where rowid = last_insert_rowid()",
        );
        defer select_stmt.deinit();
        const has_row = try select_stmt.step();
        if (!has_row) return error.Database;
        const project_id = try select_stmt.columnOwnedText(allocator, 0);
        errdefer allocator.free(project_id);
        self.recordTimelineEvent(project_id, null, .project_created) catch |err| {
            std.log.warn("timeline event failed: {}", .{err});
        };
        return project_id;
    }

    pub fn listProjectSummaries(self: *Store, allocator: std.mem.Allocator) StoreError![]models.ProjectSummary {
        var stmt = try Statement.init(
            self.db,
            "select\n" ++
                "    w.id,\n" ++
                "    w.name,\n" ++
                "    w.path,\n" ++
                "    w.transport,\n" ++
                "    w.updated_at,\n" ++
                "    coalesce(sum(case when s.state = 'live' then 1 else 0 end), 0),\n" ++
                "    coalesce(sum(case when s.state in ('closed','exited','lost','crashed') then 1 else 0 end), 0),\n" ++
                "    coalesce(max(case when s.state = 'interrupted' then 1 else 0 end), 0)\n" ++
                " from projects w\n" ++
                " left join sessions s on s.project_id = w.id\n" ++
                " group by w.id, w.name, w.path, w.transport, w.updated_at\n" ++
                " order by w.updated_at desc, w.rowid desc",
        );
        defer stmt.deinit();

        var items: std.ArrayList(models.ProjectSummary) = .empty;
        defer items.deinit(allocator);

        while (try stmt.step()) {
            const project_id = try stmt.columnOwnedText(allocator, 0);
            errdefer allocator.free(project_id);
            const name = try stmt.columnOwnedText(allocator, 1);
            errdefer allocator.free(name);
            const path = try stmt.columnOwnedText(allocator, 2);
            errdefer allocator.free(path);
            const transport = try models.SessionTransport.fromSql(try stmt.columnTextSlice(3));
            const live_session_details = try self.sessionsForProject(allocator, project_id, .live);
            errdefer {
                for (live_session_details) |*session| session.deinit(allocator);
                allocator.free(live_session_details);
            }

            try items.append(allocator, .{
                .id = project_id,
                .name = name,
                .path = path,
                .transport = transport,
                .updated_at = stmt.columnInt64(4),
                .live_sessions = stmt.columnInt64(5),
                .live_session_details = live_session_details,
                .recently_closed_sessions = stmt.columnInt64(6),
                .has_interrupted_sessions = stmt.columnInt64(7) != 0,
            });
        }

        return items.toOwnedSlice(allocator);
    }

    pub fn renameProject(self: *Store, project_id: []const u8, new_name: []const u8) StoreError!void {
        const updated_at = now();
        var stmt = try Statement.init(
            self.db,
            "update projects\n" ++
                " set name = ?2, updated_at = ?3\n" ++
                " where id = ?1",
        );
        defer stmt.deinit();
        try stmt.bindText(1, project_id);
        try stmt.bindText(2, new_name);
        try stmt.bindInt64(3, updated_at);
        try stmt.expectDone();
    }

    pub fn deleteProject(self: *Store, project_id: []const u8) StoreError!void {
        var stmt = try Statement.init(
            self.db,
            "delete from projects where id = ?1",
        );
        defer stmt.deinit();
        try stmt.bindText(1, project_id);
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
                "    id, project_id, transport, target_label, title, shell,\n" ++
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
        try stmt.bindText(1, input.project_id);
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

        try self.touchProject(input.project_id);
        self.recordTimelineEvent(input.project_id, session_id, .session_started) catch |err| {
            std.log.warn("timeline event failed: {}", .{err});
        };
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

        try self.touchProjectBySession(input.session_id);
        if (input.kind == .final) {
            if (self.projectIdForSession(std.heap.c_allocator, input.session_id)) |project_id| {
                defer std.heap.c_allocator.free(project_id);
                self.recordTimelineEvent(project_id, input.session_id, .snapshot_finalized) catch |err| {
                    std.log.warn("timeline event failed: {}", .{err});
                };
            } else |_| {}
        }
    }

    pub fn recordTimelineEvent(
        self: *Store,
        project_id: []const u8,
        session_id: ?[]const u8,
        event_type: models.TimelineEventKind,
    ) StoreError!void {
        var stmt = try Statement.init(
            self.db,
            "insert into timeline_events (id, project_id, session_id, event_type, created_at)\n" ++
                " values (lower(hex(randomblob(16))), ?1, ?2, ?3, ?4)",
        );
        defer stmt.deinit();
        try stmt.bindText(1, project_id);
        try stmt.bindOptionalText(2, session_id);
        try stmt.bindText(3, event_type.asText());
        try stmt.bindInt64(4, now());
        try stmt.expectDone();
    }

    pub fn closeSession(
        self: *Store,
        session_id: []const u8,
        reason: models.CloseReason,
        last_cwd: ?[]const u8,
    ) StoreError!void {
        const updated_at = now();
        var stmt = try Statement.init(
            self.db,
            "update sessions\n" ++
                " set state = ?2,\n" ++
                "     close_reason = ?3,\n" ++
                "     last_cwd = coalesce(?4, last_cwd),\n" ++
                "     updated_at = ?5\n" ++
                " where id = ?1 and state = ?6",
        );
        defer stmt.deinit();
        try stmt.bindText(1, session_id);
        try stmt.bindText(2, models.SessionState.closed.asSql());
        try stmt.bindText(3, reason.asSql());
        try stmt.bindOptionalText(4, last_cwd);
        try stmt.bindInt64(5, updated_at);
        try stmt.bindText(6, models.SessionState.live.asSql());
        try stmt.expectDone();

        if (sqlite.sqlite3_changes(self.db) == 0) {
            if (try self.sessionExists(session_id)) return;
            return error.Database;
        }

        try self.touchProjectBySession(session_id);
        if (self.projectIdForSession(std.heap.c_allocator, session_id)) |project_id| {
            defer std.heap.c_allocator.free(project_id);
            self.recordTimelineEvent(project_id, session_id, .session_closed) catch |err| {
                std.log.warn("timeline event failed: {}", .{err});
            };
        } else |_| {}
    }

    pub fn reconcileInterruptedSessions(self: *Store) StoreError!void {
        const InterruptedSession = struct {
            id: []u8,
            project_id: []u8,
        };

        var select_stmt = try Statement.init(
            self.db,
            "select id, project_id\n" ++
                " from sessions\n" ++
                " where state = ?1",
        );
        defer select_stmt.deinit();
        try select_stmt.bindText(1, models.SessionState.live.asSql());

        var sessions: std.ArrayList(InterruptedSession) = .empty;
        defer {
            for (sessions.items) |item| {
                std.heap.c_allocator.free(item.id);
                std.heap.c_allocator.free(item.project_id);
            }
            sessions.deinit(std.heap.c_allocator);
        }

        while (try select_stmt.step()) {
            const session_id = try select_stmt.columnOwnedText(std.heap.c_allocator, 0);
            errdefer std.heap.c_allocator.free(session_id);
            const project_id = try select_stmt.columnOwnedText(std.heap.c_allocator, 1);
            errdefer std.heap.c_allocator.free(project_id);

            try sessions.append(std.heap.c_allocator, .{
                .id = session_id,
                .project_id = project_id,
            });
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

        for (sessions.items) |item| {
            try self.touchProjectBySession(item.id);
            self.recordTimelineEvent(item.project_id, item.id, .session_interrupted) catch |err| {
                std.log.warn("timeline event failed: {}", .{err});
            };
        }
    }

    pub fn projectDetail(self: *Store, allocator: std.mem.Allocator, project_id: []const u8) StoreError!models.ProjectDetail {
        var stmt = try Statement.init(
            self.db,
            "select id, name, path, transport\n" ++
                " from projects\n" ++
                " where id = ?1",
        );
        defer stmt.deinit();
        try stmt.bindText(1, project_id);
        if (!try stmt.step()) return error.Database;

        const id = try stmt.columnOwnedText(allocator, 0);
        errdefer allocator.free(id);
        const name = try stmt.columnOwnedText(allocator, 1);
        errdefer allocator.free(name);
        const path = try stmt.columnOwnedText(allocator, 2);
        errdefer allocator.free(path);
        const transport = try models.SessionTransport.fromSql(try stmt.columnTextSlice(3));
        const live_sessions = try self.sessionsForProject(allocator, project_id, .live);

        return .{
            .id = id,
            .name = name,
            .path = path,
            .transport = transport,
            .live_sessions = live_sessions,
        };
    }

    pub fn findProjectByCwd(self: *Store, allocator: std.mem.Allocator, cwd: []const u8) StoreError!?[]u8 {
        // 1. Exact match: find a live session whose last_cwd equals the given cwd
        {
            var stmt = try Statement.init(
                self.db,
                "select s.project_id\n" ++
                    " from sessions s\n" ++
                    " where s.last_cwd = ?1 and s.state = 'live'\n" ++
                    " order by s.updated_at desc\n" ++
                    " limit 1",
            );
            defer stmt.deinit();
            try stmt.bindText(1, cwd);
            if (try stmt.step()) {
                return try stmt.columnOwnedText(allocator, 0);
            }
        }

        // 2. Prefix match: find a project whose path is a prefix of cwd (or vice versa)
        //    We fetch all projects and test in Zig to avoid SQLite LIKE/GLOB edge cases.
        {
            var stmt = try Statement.init(
                self.db,
                "select id, path from projects\n" ++
                    " where path != ''\n" ++
                    " order by updated_at desc",
            );
            defer stmt.deinit();
            while (try stmt.step()) {
                const path = try stmt.columnTextSlice(1);
                if (path.len == 0) continue;
                if (std.mem.startsWith(u8, cwd, path) or std.mem.startsWith(u8, path, cwd)) {
                    return try stmt.columnOwnedText(allocator, 0);
                }
            }
        }

        return null;
    }

    fn migrate(self: *Store) StoreError!void {
        // Bootstrap the version table (always safe to run)
        try self.execScript(
            "create table if not exists schema_version (version integer not null)",
        );

        const version = try self.schemaVersion();

        if (version < 1) {
            try self.migrateV1();
            try self.setSchemaVersion(1);
        }
        if (version < 2) {
            try self.migrateV2();
            try self.setSchemaVersion(2);
        }
    }

    fn schemaVersion(self: *Store) StoreError!u32 {
        var stmt = try Statement.init(self.db, "select version from schema_version limit 1");
        defer stmt.deinit();
        if (!try stmt.step()) return 0;
        const v = stmt.columnInt64(0);
        if (v < 0 or v > std.math.maxInt(u32)) return error.InvalidData;
        return @intCast(v);
    }

    fn setSchemaVersion(self: *Store, version: u32) StoreError!void {
        try self.execScript("delete from schema_version");
        var stmt = try Statement.init(self.db, "insert into schema_version (version) values (?1)");
        defer stmt.deinit();
        try stmt.bindInt64(1, @intCast(version));
        try stmt.expectDone();
    }

    fn migrateV1(self: *Store) StoreError!void {
        try self.execScript(
            "create table if not exists projects (\n" ++
                "    id text primary key not null,\n" ++
                "    name text not null,\n" ++
                "    note_body text not null,\n" ++
                "    updated_at integer not null,\n" ++
                "    last_opened_at integer not null\n" ++
                ");\n" ++
                "\n" ++
                "create table if not exists sessions (\n" ++
                "    id text primary key not null,\n" ++
                "    project_id text not null references projects(id) on delete cascade,\n" ++
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
                "create index if not exists idx_sessions_project_id on sessions(project_id);\n" ++
                "create index if not exists idx_sessions_state on sessions(state);\n" ++
                "create index if not exists idx_snapshots_session_id on snapshots(session_id);\n" ++
                "\n" ++
                "create table if not exists timeline_events (\n" ++
                "    id text primary key not null,\n" ++
                "    project_id text not null references projects(id) on delete cascade,\n" ++
                "    session_id text,\n" ++
                "    event_type text not null,\n" ++
                "    created_at integer not null\n" ++
                ");\n" ++
                "create index if not exists idx_timeline_project_id on timeline_events(project_id);\n" ++
                "create index if not exists idx_timeline_created_at on timeline_events(created_at);",
        );
    }

    fn migrateV2(self: *Store) StoreError!void {
        try self.execScript(
            "alter table projects add column path text not null default '';\n" ++
                "alter table projects add column transport text not null default 'local';",
        );
    }

    fn sessionsForProject(
        self: *Store,
        allocator: std.mem.Allocator,
        project_id: []const u8,
        state: models.SessionState,
    ) StoreError![]models.SessionSummary {
        var stmt = try Statement.init(
            self.db,
            "select id, title, transport, target_label, last_cwd, close_reason\n" ++
                " from sessions\n" ++
                " where project_id = ?1 and state = ?2\n" ++
                " order by updated_at desc, rowid desc",
        );
        defer stmt.deinit();
        try stmt.bindText(1, project_id);
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

    fn touchProject(self: *Store, project_id: []const u8) StoreError!void {
        var stmt = try Statement.init(
            self.db,
            "update projects\n" ++
                " set updated_at = ?2\n" ++
                " where id = ?1",
        );
        defer stmt.deinit();
        try stmt.bindText(1, project_id);
        try stmt.bindInt64(2, now());
        try stmt.expectDone();
    }

    fn touchProjectBySession(self: *Store, session_id: []const u8) StoreError!void {
        var stmt = try Statement.init(
            self.db,
            "update projects set updated_at = ?2\n" ++
                " where id = (select project_id from sessions where id = ?1)",
        );
        defer stmt.deinit();
        try stmt.bindText(1, session_id);
        try stmt.bindInt64(2, now());
        try stmt.expectDone();
    }

    fn projectIdForSession(self: *Store, allocator: std.mem.Allocator, session_id: []const u8) StoreError![]u8 {
        var stmt = try Statement.init(
            self.db,
            "select project_id from sessions where id = ?1",
        );
        defer stmt.deinit();
        try stmt.bindText(1, session_id);
        if (!try stmt.step()) return error.Database;
        return stmt.columnOwnedText(allocator, 0);
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
