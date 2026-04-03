const std = @import("std");
const models = @import("models.zig");

pub fn buildRestoreRecipe(
    allocator: std.mem.Allocator,
    transport: models.SessionTransport,
    target_label: []const u8,
    shell: []const u8,
    cwd: ?[]const u8,
) !models.RestoreRecipe {
    const quoted_shell = try shellQuote(allocator, shell);
    defer allocator.free(quoted_shell);

    const shell_command = if (cwd) |value| blk: {
        const quoted_cwd = try shellQuote(allocator, value);
        defer allocator.free(quoted_cwd);
        break :blk try std.fmt.allocPrint(allocator, "cd {s} && exec {s} -l", .{
            quoted_cwd,
            quoted_shell,
        });
    } else try std.fmt.allocPrint(allocator, "exec {s} -l", .{
        quoted_shell,
    });
    defer allocator.free(shell_command);

    const launch_command = switch (transport) {
        .local => try allocator.dupe(u8, shell_command),
        .ssh => blk: {
            const escaped = try escapeForSingleQuotes(allocator, shell_command);
            defer allocator.free(escaped);
            break :blk try std.fmt.allocPrint(allocator, "ssh {s} -- '{s}'", .{
                target_label,
                escaped,
            });
        },
    };

    return .{ .launch_command = launch_command };
}

fn shellQuote(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    for (value) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '/' and ch != '.' and ch != '_' and ch != '-' and ch != ':') {
            const escaped = try escapeForSingleQuotes(allocator, value);
            defer allocator.free(escaped);
            return std.fmt.allocPrint(allocator, "'{s}'", .{escaped});
        }
    }
    return allocator.dupe(u8, value);
}

fn escapeForSingleQuotes(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);

    for (value) |ch| {
        if (ch == '\'') {
            try buffer.appendSlice(allocator, "'\"'\"'");
        } else {
            try buffer.append(allocator, ch);
        }
    }

    return buffer.toOwnedSlice(allocator);
}
