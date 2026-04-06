const std = @import("std");

pub const SessionTransport = enum {
    local,
    ssh,

    pub fn asSql(self: SessionTransport) []const u8 {
        return switch (self) {
            .local => "local",
            .ssh => "ssh",
        };
    }

    pub fn fromSql(value: []const u8) !SessionTransport {
        if (std.mem.eql(u8, value, "local")) return .local;
        if (std.mem.eql(u8, value, "ssh")) return .ssh;
        return error.InvalidData;
    }
};

pub const SessionState = enum {
    live,
    closed,
    exited,
    lost,
    crashed,
    interrupted,

    pub fn asSql(self: SessionState) []const u8 {
        return switch (self) {
            .live => "live",
            .closed => "closed",
            .exited => "exited",
            .lost => "lost",
            .crashed => "crashed",
            .interrupted => "interrupted",
        };
    }
};

pub const CloseReason = enum {
    user_closed,
    process_exited,
    ssh_disconnected,
    app_crashed,
    host_quit,

    pub fn asSql(self: CloseReason) []const u8 {
        return switch (self) {
            .user_closed => "user_closed",
            .process_exited => "process_exited",
            .ssh_disconnected => "ssh_disconnected",
            .app_crashed => "app_crashed",
            .host_quit => "host_quit",
        };
    }

    pub fn fromSql(value: []const u8) !CloseReason {
        if (std.mem.eql(u8, value, "user_closed")) return .user_closed;
        if (std.mem.eql(u8, value, "process_exited")) return .process_exited;
        if (std.mem.eql(u8, value, "ssh_disconnected")) return .ssh_disconnected;
        if (std.mem.eql(u8, value, "app_crashed")) return .app_crashed;
        if (std.mem.eql(u8, value, "host_quit")) return .host_quit;
        return error.InvalidData;
    }
};

pub const TimelineEventKind = enum {
    project_created,
    session_started,
    session_closed,
    session_interrupted,
    snapshot_finalized,
    note_updated,

    pub fn asText(self: TimelineEventKind) []const u8 {
        return switch (self) {
            .project_created => "project_created",
            .session_started => "session_started",
            .session_closed => "session_closed",
            .session_interrupted => "session_interrupted",
            .snapshot_finalized => "snapshot_finalized",
            .note_updated => "note_updated",
        };
    }
};

pub const NewSession = struct {
    project_id: []const u8,
    transport: SessionTransport,
    target_label: []const u8,
    title: []const u8,
    shell: []const u8,
    initial_cwd: ?[]const u8,
};

pub const TerminalGrid = struct {
    cols: u16,
    rows: u16,
    lines: [][]u8,

    pub fn empty(allocator: std.mem.Allocator) !TerminalGrid {
        return .{
            .cols = 0,
            .rows = 0,
            .lines = try allocator.alloc([]u8, 0),
        };
    }

    pub fn deinit(self: *TerminalGrid, allocator: std.mem.Allocator) void {
        for (self.lines) |line| allocator.free(line);
        allocator.free(self.lines);
        self.* = .{ .cols = 0, .rows = 0, .lines = &.{} };
    }
};

pub const SnapshotKind = enum {
    checkpoint,
    final,

    pub fn asSql(self: SnapshotKind) []const u8 {
        return switch (self) {
            .checkpoint => "checkpoint",
            .final => "final",
        };
    }
};

pub const NewSnapshot = struct {
    session_id: []const u8,
    kind: SnapshotKind,
    cwd: ?[]const u8,
    grid: TerminalGridInput,
};

pub const TerminalGridInput = struct {
    cols: u16,
    rows: u16,
    lines: []const []const u8,
};

pub const RestoreRecipe = struct {
    launch_command: []u8,

    pub fn deinit(self: *RestoreRecipe, allocator: std.mem.Allocator) void {
        allocator.free(self.launch_command);
        self.* = undefined;
    }
};

pub const SessionSummary = struct {
    id: []u8,
    title: []u8,
    transport: SessionTransport,
    target_label: []u8,
    last_cwd: ?[]u8,
    close_reason: CloseReason,

    pub fn deinit(self: *SessionSummary, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.title);
        allocator.free(self.target_label);
        if (self.last_cwd) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const ClosedSessionSummary = struct {
    id: []u8,
    title: []u8,
    transport: SessionTransport,
    target_label: []u8,
    last_cwd: ?[]u8,
    close_reason: CloseReason,
    snapshot_preview: TerminalGrid,
    restore_recipe: RestoreRecipe,

    pub fn deinit(self: *ClosedSessionSummary, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.title);
        allocator.free(self.target_label);
        if (self.last_cwd) |value| allocator.free(value);
        self.snapshot_preview.deinit(allocator);
        self.restore_recipe.deinit(allocator);
        self.* = undefined;
    }
};

pub const ProjectSummary = struct {
    id: []u8,
    name: []u8,
    path: []u8,
    transport: SessionTransport,
    live_sessions: i64,
    live_session_details: []SessionSummary,
    recently_closed_sessions: i64,
    has_interrupted_sessions: bool,
    updated_at: i64,

    pub fn deinit(self: *ProjectSummary, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.path);
        for (self.live_session_details) |*session| session.deinit(allocator);
        allocator.free(self.live_session_details);
        self.* = undefined;
    }
};

pub const ProjectDetail = struct {
    id: []u8,
    name: []u8,
    path: []u8,
    transport: SessionTransport,
    live_sessions: []SessionSummary,

    pub fn deinit(self: *ProjectDetail, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.path);
        for (self.live_sessions) |*session| session.deinit(allocator);
        allocator.free(self.live_sessions);
        self.* = undefined;
    }
};
