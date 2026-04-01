const std = @import("std");
const core = @import("workspace_core");

test "creates and lists projects in recent order" {
    var store = try core.Store.open(":memory:");
    defer store.deinit();

    const project_one = try store.createProject(std.testing.allocator, "spark3", "", .local);
    defer std.testing.allocator.free(project_one);
    const project_two = try store.createProject(std.testing.allocator, "release", "", .local);
    defer std.testing.allocator.free(project_two);

    const summaries = try store.listProjectSummaries(std.testing.allocator);
    defer freeProjectSummaries(summaries);

    try std.testing.expectEqual(@as(usize, 2), summaries.len);
    try std.testing.expectEqualStrings("release", summaries[0].name);
    try std.testing.expectEqualStrings("spark3", summaries[1].name);
    try std.testing.expectEqual(@as(i64, 0), summaries[0].live_sessions);
    try std.testing.expectEqual(@as(i64, 0), summaries[0].recently_closed_sessions);
    try std.testing.expect(!summaries[0].has_interrupted_sessions);
}

test "memory databases do not share state across connections" {
    var first = try core.Store.open(":memory:");
    defer first.deinit();

    const project_id = try first.createProject(std.testing.allocator, "spark3", "", .local);
    defer std.testing.allocator.free(project_id);

    var second = try core.Store.open(":memory:");
    defer second.deinit();

    const summaries = try second.listProjectSummaries(std.testing.allocator);
    defer freeProjectSummaries(summaries);

    try std.testing.expectEqual(@as(usize, 0), summaries.len);
}

test "file backed databases persist across reopen" {
    const path = try uniqueDbPath("project-store");
    defer std.testing.allocator.free(path);
    defer std.fs.cwd().deleteFile(path) catch {};

    {
        var store = try core.Store.open(path);
        defer store.deinit();
        const project_id = try store.createProject(std.testing.allocator, "spark3", "", .local);
        defer std.testing.allocator.free(project_id);
    }

    var reopened = try core.Store.open(path);
    defer reopened.deinit();
    const summaries = try reopened.listProjectSummaries(std.testing.allocator);
    defer freeProjectSummaries(summaries);

    try std.testing.expectEqual(@as(usize, 1), summaries.len);
    try std.testing.expectEqualStrings("spark3", summaries[0].name);
}

test "closing a session updates recently closed count" {
    var store = try core.Store.open(":memory:");
    defer store.deinit();
    const project_id = try store.createProject(std.testing.allocator, "release", "", .local);
    defer std.testing.allocator.free(project_id);

    const session_id = try store.startSession(std.testing.allocator, .{
        .project_id = project_id,
        .transport = .ssh,
        .target_label = "prod",
        .title = "prod logs",
        .shell = "zsh",
        .initial_cwd = "/srv/app",
    });
    defer std.testing.allocator.free(session_id);

    try store.closeSession(session_id, .user_closed, "/srv/app");

    var detail = try store.projectDetail(std.testing.allocator, project_id);
    defer detail.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), detail.live_sessions.len);

    const summaries = try store.listProjectSummaries(std.testing.allocator);
    defer freeProjectSummaries(summaries);
    try std.testing.expectEqual(@as(i64, 1), summaries[0].recently_closed_sessions);
}

test "file backed reopen preserves session counts" {
    const path = try uniqueDbPath("session-lifecycle");
    defer std.testing.allocator.free(path);
    defer std.fs.cwd().deleteFile(path) catch {};

    var project_id: []u8 = undefined;
    {
        var store = try core.Store.open(path);
        defer store.deinit();
        project_id = try store.createProject(std.testing.allocator, "release", "/tmp/release", .local);

        const session_id = try store.startSession(std.testing.allocator, .{
            .project_id = project_id,
            .transport = .ssh,
            .target_label = "prod",
            .title = "prod logs",
            .shell = "zsh",
            .initial_cwd = "/srv/app",
        });
        defer std.testing.allocator.free(session_id);

        try store.closeSession(session_id, .user_closed, "/srv/app");
    }
    defer std.testing.allocator.free(project_id);

    var reopened = try core.Store.open(path);
    defer reopened.deinit();
    const summaries = try reopened.listProjectSummaries(std.testing.allocator);
    defer freeProjectSummaries(summaries);

    try std.testing.expectEqual(@as(usize, 1), summaries.len);
    try std.testing.expectEqualStrings("release", summaries[0].name);
    try std.testing.expectEqualStrings("/tmp/release", summaries[0].path);
    try std.testing.expectEqual(core.SessionTransport.local, summaries[0].transport);
    try std.testing.expectEqual(@as(i64, 0), summaries[0].live_sessions);
    try std.testing.expectEqual(@as(i64, 1), summaries[0].recently_closed_sessions);
    try std.testing.expect(!summaries[0].has_interrupted_sessions);

    var detail = try reopened.projectDetail(std.testing.allocator, summaries[0].id);
    defer detail.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("/tmp/release", detail.path);
    try std.testing.expectEqual(@as(usize, 0), detail.live_sessions.len);
}

test "timeline events are recorded for project and session operations" {
    const path = try uniqueDbPath("timeline-events");
    defer std.testing.allocator.free(path);
    defer std.fs.cwd().deleteFile(path) catch {};

    var project_id: []u8 = undefined;
    var session_id: []u8 = undefined;
    {
        var store = try core.Store.open(path);
        defer store.deinit();

        project_id = try store.createProject(std.testing.allocator, "release", "", .local);
        session_id = try store.startSession(std.testing.allocator, .{
            .project_id = project_id,
            .transport = .ssh,
            .target_label = "prod",
            .title = "prod logs",
            .shell = "zsh",
            .initial_cwd = "/srv/app",
        });

        try store.closeSession(session_id, .user_closed, "/srv/app");
    }
    defer std.testing.allocator.free(project_id);
    defer std.testing.allocator.free(session_id);

    const events = try listTimelineEvents(std.testing.allocator, path);
    defer freeTimelineEvents(events);

    try std.testing.expectEqual(@as(usize, 3), events.len);
    try std.testing.expectEqualStrings("project_created", events[0].event_type);
    try std.testing.expectEqualStrings(project_id, events[0].project_id);
    try std.testing.expect(events[0].session_id == null);

    try std.testing.expectEqualStrings("session_started", events[1].event_type);
    try std.testing.expectEqualStrings(project_id, events[1].project_id);
    try std.testing.expect(events[1].session_id != null);
    try std.testing.expectEqualStrings(session_id, events[1].session_id.?);

    try std.testing.expectEqualStrings("session_closed", events[2].event_type);
    try std.testing.expectEqualStrings(project_id, events[2].project_id);
    try std.testing.expect(events[2].session_id != null);
    try std.testing.expectEqualStrings(session_id, events[2].session_id.?);
}

test "closing an already closed session is idempotent" {
    var store = try core.Store.open(":memory:");
    defer store.deinit();
    const project_id = try store.createProject(std.testing.allocator, "release", "", .local);
    defer std.testing.allocator.free(project_id);

    const session_id = try store.startSession(std.testing.allocator, .{
        .project_id = project_id,
        .transport = .ssh,
        .target_label = "prod",
        .title = "prod logs",
        .shell = "zsh",
        .initial_cwd = "/srv/app",
    });
    defer std.testing.allocator.free(session_id);

    try store.closeSession(session_id, .user_closed, "/srv/app");
    // Second close should be no-op (session already closed)
    try store.closeSession(session_id, .app_crashed, null);

    const summaries = try store.listProjectSummaries(std.testing.allocator);
    defer freeProjectSummaries(summaries);
    try std.testing.expectEqual(@as(i64, 1), summaries[0].recently_closed_sessions);
}

test "session activity updates project list recency" {
    const path = try uniqueDbPath("session-lifecycle");
    defer std.testing.allocator.free(path);
    defer std.fs.cwd().deleteFile(path) catch {};

    {
        var store = try core.Store.open(path);
        defer store.deinit();
        const alpha_id = try store.createProject(std.testing.allocator, "alpha", "", .local);
        defer std.testing.allocator.free(alpha_id);
        const beta_id = try store.createProject(std.testing.allocator, "beta", "", .local);
        defer std.testing.allocator.free(beta_id);

        const after_create = try store.listProjectSummaries(std.testing.allocator);
        defer freeProjectSummaries(after_create);
        try std.testing.expectEqualStrings(beta_id, after_create[0].id);
        try std.testing.expectEqualStrings(alpha_id, after_create[1].id);

        const session_id = try store.startSession(std.testing.allocator, .{
            .project_id = alpha_id,
            .transport = .local,
            .target_label = "local",
            .title = "alpha session",
            .shell = "zsh",
            .initial_cwd = null,
        });
        defer std.testing.allocator.free(session_id);

        const after_start = try store.listProjectSummaries(std.testing.allocator);
        defer freeProjectSummaries(after_start);
        try std.testing.expectEqualStrings(alpha_id, after_start[0].id);

        const gamma_id = try store.createProject(std.testing.allocator, "gamma", "", .local);
        defer std.testing.allocator.free(gamma_id);
        const after_gamma = try store.listProjectSummaries(std.testing.allocator);
        defer freeProjectSummaries(after_gamma);
        try std.testing.expectEqualStrings(gamma_id, after_gamma[0].id);

        try store.closeSession(session_id, .user_closed, "/tmp");

        const after_close = try store.listProjectSummaries(std.testing.allocator);
        defer freeProjectSummaries(after_close);
        try std.testing.expectEqualStrings(alpha_id, after_close[0].id);
    }
}

test "start session rejects missing project without creating orphan row" {
    const path = try uniqueDbPath("session-lifecycle");
    defer std.testing.allocator.free(path);
    defer std.fs.cwd().deleteFile(path) catch {};

    var store = try core.Store.open(path);
    defer store.deinit();

    const result = store.startSession(std.testing.allocator, .{
        .project_id = "missing-project",
        .transport = .local,
        .target_label = "local",
        .title = "orphan",
        .shell = "zsh",
        .initial_cwd = null,
    });

    try std.testing.expectError(core.StoreError.Database, result);
    const session_count = try rawCount(path, "select count(*) from sessions");
    try std.testing.expectEqual(@as(i64, 0), session_count);
}

test "snapshot recording succeeds for a closed session" {
    var store = try core.Store.open(":memory:");
    defer store.deinit();
    const project_id = try store.createProject(std.testing.allocator, "release", "", .local);
    defer std.testing.allocator.free(project_id);
    const session_id = try store.startSession(std.testing.allocator, .{
        .project_id = project_id,
        .transport = .ssh,
        .target_label = "prod",
        .title = "prod logs",
        .shell = "zsh",
        .initial_cwd = "/srv/app",
    });
    defer std.testing.allocator.free(session_id);

    try store.recordSnapshot(.{
        .session_id = session_id,
        .kind = .final,
        .cwd = "/srv/app",
        .grid = .{ .cols = 80, .rows = 24, .lines = &.{ "tail -f log", "error line" } },
    });
    try store.closeSession(session_id, .user_closed, "/srv/app");

    const summaries = try store.listProjectSummaries(std.testing.allocator);
    defer freeProjectSummaries(summaries);
    try std.testing.expectEqual(@as(i64, 1), summaries[0].recently_closed_sessions);
}

test "unfinalized live sessions are marked interrupted on next launch" {
    var store = try core.Store.open(":memory:");
    defer store.deinit();
    const project_id = try store.createProject(std.testing.allocator, "spark3", "", .local);
    defer std.testing.allocator.free(project_id);
    const session_id = try store.startSession(std.testing.allocator, .{
        .project_id = project_id,
        .transport = .local,
        .target_label = "local",
        .title = "shell",
        .shell = "zsh",
        .initial_cwd = "/Users/jinto/projects/spark3",
    });
    defer std.testing.allocator.free(session_id);

    try store.recordSnapshot(.{
        .session_id = session_id,
        .kind = .checkpoint,
        .cwd = "/Users/jinto/projects/spark3/crates/workspace-core",
        .grid = .{ .cols = 80, .rows = 24, .lines = &.{ "cargo test", "waiting" } },
    });

    try store.reconcileInterruptedSessions();

    const summaries = try store.listProjectSummaries(std.testing.allocator);
    defer freeProjectSummaries(summaries);
    try std.testing.expect(summaries[0].has_interrupted_sessions);

    var detail = try store.projectDetail(std.testing.allocator, project_id);
    defer detail.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), detail.live_sessions.len);
}

test "updateSessionTitle changes the session title" {
    var store = try core.Store.open(":memory:");
    defer store.deinit();
    const project_id = try store.createProject(std.testing.allocator, "spark3", "", .local);
    defer std.testing.allocator.free(project_id);

    const session_id = try store.startSession(std.testing.allocator, .{
        .project_id = project_id,
        .transport = .local,
        .target_label = "local",
        .title = "Original",
        .shell = "zsh",
        .initial_cwd = null,
    });
    defer std.testing.allocator.free(session_id);

    try store.updateSessionTitle(session_id, "Renamed");

    var detail = try store.projectDetail(std.testing.allocator, project_id);
    defer detail.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), detail.live_sessions.len);
    try std.testing.expectEqualStrings("Renamed", detail.live_sessions[0].title);
}

test "renameProject changes the project name" {
    var store = try core.Store.open(":memory:");
    defer store.deinit();
    const project_id = try store.createProject(std.testing.allocator, "Original", "", .local);
    defer std.testing.allocator.free(project_id);

    try store.renameProject(project_id, "Renamed");

    const summaries = try store.listProjectSummaries(std.testing.allocator);
    defer freeProjectSummaries(summaries);

    try std.testing.expectEqual(@as(usize, 1), summaries.len);
    try std.testing.expectEqualStrings("Renamed", summaries[0].name);
}

test "deleteProject removes the project from the list" {
    var store = try core.Store.open(":memory:");
    defer store.deinit();
    const alpha_id = try store.createProject(std.testing.allocator, "alpha", "", .local);
    defer std.testing.allocator.free(alpha_id);
    const beta_id = try store.createProject(std.testing.allocator, "beta", "", .local);
    defer std.testing.allocator.free(beta_id);

    try store.deleteProject(alpha_id);

    const summaries = try store.listProjectSummaries(std.testing.allocator);
    defer freeProjectSummaries(summaries);

    try std.testing.expectEqual(@as(usize, 1), summaries.len);
    try std.testing.expectEqualStrings("beta", summaries[0].name);
}

test "deleteProject cascades to sessions and snapshots" {
    var store = try core.Store.open(":memory:");
    defer store.deinit();
    const project_id = try store.createProject(std.testing.allocator, "doomed", "", .local);
    defer std.testing.allocator.free(project_id);

    const session_id = try store.startSession(std.testing.allocator, .{
        .project_id = project_id,
        .transport = .local,
        .target_label = "local",
        .title = "shell",
        .shell = "zsh",
        .initial_cwd = "/tmp",
    });
    defer std.testing.allocator.free(session_id);

    try store.recordSnapshot(.{
        .session_id = session_id,
        .kind = .final,
        .cwd = "/tmp",
        .grid = .{ .cols = 80, .rows = 24, .lines = &.{"hello"} },
    });

    try store.deleteProject(project_id);

    const summaries = try store.listProjectSummaries(std.testing.allocator);
    defer freeProjectSummaries(summaries);

    try std.testing.expectEqual(@as(usize, 0), summaries.len);
}

test "corrupt transport returns error instead of panic" {
    const path = try uniqueDbPath("corrupt-transport");
    defer std.testing.allocator.free(path);
    defer std.fs.cwd().deleteFile(path) catch {};

    var store = try core.Store.open(path);
    const project_id = try store.createProject(std.testing.allocator, "test", "", .local);
    defer std.testing.allocator.free(project_id);
    const session_id = try store.startSession(std.testing.allocator, .{
        .project_id = project_id,
        .transport = .local,
        .target_label = "local",
        .title = "shell",
        .shell = "zsh",
        .initial_cwd = null,
    });
    defer std.testing.allocator.free(session_id);
    store.deinit();

    try execSql(path, "update sessions set transport = 'telepathy' where id = ?1", session_id);

    var reopened = try core.Store.open(path);
    defer reopened.deinit();
    const result = reopened.projectDetail(std.testing.allocator, project_id);
    try std.testing.expectError(core.StoreError.InvalidData, result);
}

test "many closed sessions are counted correctly" {
    var store = try core.Store.open(":memory:");
    defer store.deinit();
    const project_id = try store.createProject(std.testing.allocator, "bench", "", .local);
    defer std.testing.allocator.free(project_id);

    for (0..20) |i| {
        const title = try std.fmt.allocPrint(std.testing.allocator, "session-{d}", .{i});
        defer std.testing.allocator.free(title);
        const cwd = try std.fmt.allocPrint(std.testing.allocator, "/tmp/{d}", .{i});
        defer std.testing.allocator.free(cwd);

        const session_id = try store.startSession(std.testing.allocator, .{
            .project_id = project_id,
            .transport = .local,
            .target_label = "local",
            .title = title,
            .shell = "zsh",
            .initial_cwd = cwd,
        });
        defer std.testing.allocator.free(session_id);

        try store.closeSession(session_id, .user_closed, cwd);
    }

    const summaries = try store.listProjectSummaries(std.testing.allocator);
    defer freeProjectSummaries(summaries);
    try std.testing.expectEqual(@as(i64, 20), summaries[0].recently_closed_sessions);
}

test "project service returns project detail for swift" {
    var status: core.project_status_t = .PROJECT_STATUS_OK;
    const service = core.project_service_new(":memory:", &status);
    defer core.project_service_free(service);
    try std.testing.expectEqual(core.project_status_t.PROJECT_STATUS_OK, status);

    var project_id: ?[*:0]u8 = null;
    try std.testing.expectEqual(
        core.project_status_t.PROJECT_STATUS_OK,
        core.project_service_create_project(service, "spark3", "/tmp/spark3", .PROJECT_SESSION_TRANSPORT_LOCAL, &project_id),
    );
    defer core.project_free_string(project_id);
    try std.testing.expect(project_id != null);

    var detail = std.mem.zeroes(core.project_detail_t);
    defer core.project_free_detail(&detail);
    try std.testing.expectEqual(
        core.project_status_t.PROJECT_STATUS_OK,
        core.project_service_project_detail(service, project_id.?, &detail),
    );

    try std.testing.expect(detail.name != null);
    try std.testing.expectEqualStrings("spark3", std.mem.span(detail.name.?));
    try std.testing.expect(detail.path != null);
    try std.testing.expectEqualStrings("/tmp/spark3", std.mem.span(detail.path.?));
    try std.testing.expectEqual(core.project_session_transport_t.PROJECT_SESSION_TRANSPORT_LOCAL, detail.transport);
}

test "project service file store exposes live sessions" {
    const path = try uniqueDbPath("project-service");
    defer std.testing.allocator.free(path);
    defer std.fs.cwd().deleteFile(path) catch {};

    var status: core.project_status_t = .PROJECT_STATUS_OK;
    var project_id: ?[*:0]u8 = null;
    {
        const service = core.project_service_new(path.ptr, &status);
        defer core.project_service_free(service);
        try std.testing.expectEqual(core.project_status_t.PROJECT_STATUS_OK, status);
        try std.testing.expectEqual(
            core.project_status_t.PROJECT_STATUS_OK,
            core.project_service_create_project(service, "release", "/tmp/release", .PROJECT_SESSION_TRANSPORT_LOCAL, &project_id),
        );
        try std.testing.expect(project_id != null);
    }
    defer core.project_free_string(project_id);

    {
        var store = try core.Store.open(path);
        defer store.deinit();

        const live_session_id = try store.startSession(std.testing.allocator, .{
            .project_id = std.mem.span(project_id.?),
            .transport = .local,
            .target_label = "local",
            .title = "live shell",
            .shell = "zsh",
            .initial_cwd = "/tmp",
        });
        defer std.testing.allocator.free(live_session_id);

        const closed_session_id = try store.startSession(std.testing.allocator, .{
            .project_id = std.mem.span(project_id.?),
            .transport = .ssh,
            .target_label = "prod",
            .title = "prod logs",
            .shell = "zsh",
            .initial_cwd = "/srv/app",
        });
        defer std.testing.allocator.free(closed_session_id);

        try store.closeSession(closed_session_id, .user_closed, "/srv/app");
    }

    const service = core.project_service_new(path.ptr, &status);
    defer core.project_service_free(service);
    try std.testing.expectEqual(core.project_status_t.PROJECT_STATUS_OK, status);

    var detail = std.mem.zeroes(core.project_detail_t);
    defer core.project_free_detail(&detail);
    try std.testing.expectEqual(
        core.project_status_t.PROJECT_STATUS_OK,
        core.project_service_project_detail(service, project_id.?, &detail),
    );

    try std.testing.expectEqual(@as(i32, 1), detail.live_session_count);
    try std.testing.expect(detail.live_sessions != null);
    try std.testing.expectEqualStrings("live shell", std.mem.span(detail.live_sessions.?[0].title.?));
    try std.testing.expectEqual(core.project_session_transport_t.PROJECT_SESSION_TRANSPORT_LOCAL, detail.live_sessions.?[0].transport);
    try std.testing.expect(detail.path != null);
    try std.testing.expectEqualStrings("/tmp/release", std.mem.span(detail.path.?));
}

test "project detail reports which operation failed" {
    var status: core.project_status_t = .PROJECT_STATUS_OK;
    const service = core.project_service_new(":memory:", &status);
    defer core.project_service_free(service);
    try std.testing.expectEqual(core.project_status_t.PROJECT_STATUS_OK, status);

    var detail = std.mem.zeroes(core.project_detail_t);
    defer core.project_free_detail(&detail);
    try std.testing.expectEqual(
        core.project_status_t.PROJECT_STATUS_PROJECT_DETAIL_FAILED,
        core.project_service_project_detail(service, "missing-project", &detail),
    );
}

test "project service renames and deletes a project via C API" {
    var status: core.project_status_t = .PROJECT_STATUS_OK;
    const service = core.project_service_new(":memory:", &status);
    defer core.project_service_free(service);
    try std.testing.expectEqual(core.project_status_t.PROJECT_STATUS_OK, status);

    var project_id: ?[*:0]u8 = null;
    try std.testing.expectEqual(
        core.project_status_t.PROJECT_STATUS_OK,
        core.project_service_create_project(service, "Original", "", .PROJECT_SESSION_TRANSPORT_LOCAL, &project_id),
    );
    defer core.project_free_string(project_id);
    try std.testing.expect(project_id != null);

    try std.testing.expectEqual(
        core.project_status_t.PROJECT_STATUS_OK,
        core.project_service_rename_project(service, project_id.?, "Renamed"),
    );

    {
        var summaries: ?[*]core.project_summary_t = null;
        var count: i32 = 0;
        try std.testing.expectEqual(
            core.project_status_t.PROJECT_STATUS_OK,
            core.project_service_list_project_summaries(service, &summaries, &count),
        );
        defer core.project_free_summaries(summaries, count);
        try std.testing.expectEqual(@as(i32, 1), count);
        try std.testing.expect(summaries != null);
        try std.testing.expectEqualStrings("Renamed", std.mem.span(summaries.?[0].name.?));
    }

    try std.testing.expectEqual(
        core.project_status_t.PROJECT_STATUS_OK,
        core.project_service_delete_project(service, project_id.?),
    );

    {
        var summaries: ?[*]core.project_summary_t = null;
        var count: i32 = 0;
        try std.testing.expectEqual(
            core.project_status_t.PROJECT_STATUS_OK,
            core.project_service_list_project_summaries(service, &summaries, &count),
        );
        defer core.project_free_summaries(summaries, count);
        try std.testing.expectEqual(@as(i32, 0), count);
        try std.testing.expect(summaries == null);
    }
}

test "findProjectByCwd returns exact session match" {
    var store = try core.Store.open(":memory:");
    defer store.deinit();
    const project_id = try store.createProject(std.testing.allocator, "myapp", "/Users/me/myapp", .local);
    defer std.testing.allocator.free(project_id);

    const session_id = try store.startSession(std.testing.allocator, .{
        .project_id = project_id,
        .transport = .local,
        .target_label = "local",
        .title = "shell",
        .shell = "zsh",
        .initial_cwd = "/Users/me/myapp",
    });
    defer std.testing.allocator.free(session_id);

    // Exact match on live session's last_cwd
    const found = try store.findProjectByCwd(std.testing.allocator, "/Users/me/myapp");
    defer if (found) |id| std.testing.allocator.free(id);
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings(project_id, found.?);
}

test "findProjectByCwd falls back to prefix match on project path" {
    var store = try core.Store.open(":memory:");
    defer store.deinit();
    const project_id = try store.createProject(std.testing.allocator, "myapp", "/Users/me/myapp", .local);
    defer std.testing.allocator.free(project_id);

    // No sessions, but project path is a prefix of the query cwd
    const found = try store.findProjectByCwd(std.testing.allocator, "/Users/me/myapp/src/lib");
    defer if (found) |id| std.testing.allocator.free(id);
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings(project_id, found.?);
}

test "findProjectByCwd returns null for unrelated path" {
    var store = try core.Store.open(":memory:");
    defer store.deinit();
    const project_id = try store.createProject(std.testing.allocator, "myapp", "/Users/me/myapp", .local);
    defer std.testing.allocator.free(project_id);

    const found = try store.findProjectByCwd(std.testing.allocator, "/Users/me/other");
    try std.testing.expect(found == null);
}

test "findProjectByCwd prefers exact session match over prefix" {
    var store = try core.Store.open(":memory:");
    defer store.deinit();

    const proj_a = try store.createProject(std.testing.allocator, "parent", "/Users/me/projects", .local);
    defer std.testing.allocator.free(proj_a);
    const proj_b = try store.createProject(std.testing.allocator, "child", "/Users/me/projects/child", .local);
    defer std.testing.allocator.free(proj_b);

    const session_id = try store.startSession(std.testing.allocator, .{
        .project_id = proj_b,
        .transport = .local,
        .target_label = "local",
        .title = "shell",
        .shell = "zsh",
        .initial_cwd = "/Users/me/projects/child",
    });
    defer std.testing.allocator.free(session_id);

    // Exact session cwd match should win over parent project prefix
    const found = try store.findProjectByCwd(std.testing.allocator, "/Users/me/projects/child");
    defer if (found) |id| std.testing.allocator.free(id);
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings(proj_b, found.?);
}

test "findProjectByCwd via C API" {
    var status: core.project_status_t = .PROJECT_STATUS_OK;
    const service = core.project_service_new(":memory:", &status);
    defer core.project_service_free(service);
    try std.testing.expectEqual(core.project_status_t.PROJECT_STATUS_OK, status);

    var project_id: ?[*:0]u8 = null;
    try std.testing.expectEqual(
        core.project_status_t.PROJECT_STATUS_OK,
        core.project_service_create_project(service, "myapp", "/Users/me/myapp", .PROJECT_SESSION_TRANSPORT_LOCAL, &project_id),
    );
    defer core.project_free_string(project_id);

    // Prefix match via C API
    var found_id: ?[*:0]u8 = null;
    try std.testing.expectEqual(
        core.project_status_t.PROJECT_STATUS_OK,
        core.project_service_find_project_by_cwd(service, "/Users/me/myapp/src", &found_id),
    );
    defer core.project_free_string(found_id);
    try std.testing.expect(found_id != null);
    try std.testing.expectEqualStrings(std.mem.span(project_id.?), std.mem.span(found_id.?));

    // No match via C API
    var no_match: ?[*:0]u8 = null;
    try std.testing.expectEqual(
        core.project_status_t.PROJECT_STATUS_OK,
        core.project_service_find_project_by_cwd(service, "/Users/me/other", &no_match),
    );
    try std.testing.expect(no_match == null);
}

fn freeProjectSummaries(items: []core.ProjectSummary) void {
    for (items) |*item| item.deinit(std.testing.allocator);
    std.testing.allocator.free(items);
}

const TimelineEventRow = struct {
    project_id: []u8,
    session_id: ?[]u8,
    event_type: []u8,

    fn deinit(self: *TimelineEventRow) void {
        std.testing.allocator.free(self.project_id);
        if (self.session_id) |value| std.testing.allocator.free(value);
        std.testing.allocator.free(self.event_type);
        self.* = undefined;
    }
};

fn freeTimelineEvents(items: []TimelineEventRow) void {
    for (items) |*item| item.deinit();
    std.testing.allocator.free(items);
}

fn uniqueDbPath(prefix: []const u8) ![:0]u8 {
    const stamp = std.time.nanoTimestamp();
    const suffix = std.crypto.random.int(u64);
    const path = try std.fmt.allocPrint(std.testing.allocator, "/tmp/{s}-{d}-{d}.sqlite3", .{
        prefix, stamp, suffix,
    });
    defer std.testing.allocator.free(path);
    return std.testing.allocator.dupeZ(u8, path);
}

const sqlite = @cImport({
    @cInclude("sqlite3.h");
});

fn execSql(path: []const u8, sql: []const u8, id: []const u8) !void {
    var db: ?*sqlite.sqlite3 = null;
    const path_z = try std.testing.allocator.dupeZ(u8, path);
    defer std.testing.allocator.free(path_z);
    try expectSqliteOk(sqlite.sqlite3_open(path_z.ptr, &db), db);
    defer _ = sqlite.sqlite3_close(db);

    var stmt: ?*sqlite.sqlite3_stmt = null;
    const sql_z = try std.testing.allocator.dupeZ(u8, sql);
    defer std.testing.allocator.free(sql_z);
    try expectSqliteOk(sqlite.sqlite3_prepare_v2(db, sql_z.ptr, -1, &stmt, null), db);
    defer _ = sqlite.sqlite3_finalize(stmt);

    const id_z = try std.testing.allocator.dupeZ(u8, id);
    defer std.testing.allocator.free(id_z);
    try expectSqliteOk(sqlite.sqlite3_bind_text(stmt, 1, id_z.ptr, -1, null), db);
    try expectSqliteDone(stmt, db);
}

fn rawCount(path: []const u8, sql: []const u8) !i64 {
    var db: ?*sqlite.sqlite3 = null;
    const path_z = try std.testing.allocator.dupeZ(u8, path);
    defer std.testing.allocator.free(path_z);
    try expectSqliteOk(sqlite.sqlite3_open(path_z.ptr, &db), db);
    defer _ = sqlite.sqlite3_close(db);

    var stmt: ?*sqlite.sqlite3_stmt = null;
    const sql_z = try std.testing.allocator.dupeZ(u8, sql);
    defer std.testing.allocator.free(sql_z);
    try expectSqliteOk(sqlite.sqlite3_prepare_v2(db, sql_z.ptr, -1, &stmt, null), db);
    defer _ = sqlite.sqlite3_finalize(stmt);

    const step_result = sqlite.sqlite3_step(stmt);
    if (step_result != sqlite.SQLITE_ROW) return error.Database;
    return sqlite.sqlite3_column_int64(stmt, 0);
}

fn listTimelineEvents(allocator: std.mem.Allocator, path: []const u8) ![]TimelineEventRow {
    var db: ?*sqlite.sqlite3 = null;
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    try expectSqliteOk(sqlite.sqlite3_open(path_z.ptr, &db), db);
    defer _ = sqlite.sqlite3_close(db);

    var stmt: ?*sqlite.sqlite3_stmt = null;
    const sql =
        "select project_id, session_id, event_type\n" ++
        " from timeline_events\n" ++
        " order by created_at asc, rowid asc";
    const sql_z = try allocator.dupeZ(u8, sql);
    defer allocator.free(sql_z);
    try expectSqliteOk(sqlite.sqlite3_prepare_v2(db, sql_z.ptr, -1, &stmt, null), db);
    defer _ = sqlite.sqlite3_finalize(stmt);

    var events: std.ArrayList(TimelineEventRow) = .empty;
    defer {
        for (events.items) |*item| item.deinit();
        events.deinit(allocator);
    }

    while (true) {
        switch (sqlite.sqlite3_step(stmt)) {
            sqlite.SQLITE_ROW => {
                const project_id = try dupColumnText(allocator, stmt, 0);
                errdefer allocator.free(project_id);
                const session_id = try dupOptionalColumnText(allocator, stmt, 1);
                errdefer if (session_id) |value| allocator.free(value);
                const event_type = try dupColumnText(allocator, stmt, 2);
                errdefer allocator.free(event_type);

                try events.append(allocator, .{
                    .project_id = project_id,
                    .session_id = session_id,
                    .event_type = event_type,
                });
            },
            sqlite.SQLITE_DONE => return events.toOwnedSlice(allocator),
            else => return error.Database,
        }
    }
}

fn dupColumnText(allocator: std.mem.Allocator, stmt: ?*sqlite.sqlite3_stmt, index: c_int) ![]u8 {
    const text = sqlite.sqlite3_column_text(stmt, index) orelse return error.Database;
    return allocator.dupe(u8, std.mem.span(text));
}

fn dupOptionalColumnText(allocator: std.mem.Allocator, stmt: ?*sqlite.sqlite3_stmt, index: c_int) !?[]u8 {
    if (sqlite.sqlite3_column_type(stmt, index) == sqlite.SQLITE_NULL) return null;
    return @as(?[]u8, try dupColumnText(allocator, stmt, index));
}

fn expectSqliteOk(code: c_int, db: ?*sqlite.sqlite3) !void {
    if (code == sqlite.SQLITE_OK) return;
    _ = db;
    return error.Database;
}

fn expectSqliteDone(stmt: ?*sqlite.sqlite3_stmt, db: ?*sqlite.sqlite3) !void {
    const code = sqlite.sqlite3_step(stmt);
    if (code == sqlite.SQLITE_DONE) return;
    _ = db;
    return error.Database;
}
