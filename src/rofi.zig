const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

pub fn select(alloc: Allocator, label: []const u8, items: [][]const u8) !?u32 {
    const args = [_][]const u8{ "rofi", "-dmenu", "-no-custom", "-p", label };
    var child = std.process.Child.init(&args, alloc);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    try child.spawn();
    for (items) |item| {
        try child.stdin.?.writeAll(item);
        try child.stdin.?.writeAll("\n");
    }
    // child.stdin.?.close();
    const result_full = try child.stdout.?.readToEndAlloc(alloc, std.math.maxInt(usize));
    const result = mem.trim(u8, result_full, &std.ascii.whitespace);

    _ = try child.wait();

    if (result.len == 0) {
        return null;
    }

    for (items, 0..) |item, index| {
        if (mem.eql(u8, result, item)) {
            return @intCast(index);
        }
    }

    return null;
}

const SelectWriterIntermediate = struct {
    child: std.process.Child,
    writer: std.Io.Writer,
    alloc: mem.Allocator,

    pub fn finish(self: *SelectWriterIntermediate) !?[]const u8 {
        const result_full = try self.child.stdout.?.readToEndAlloc(self.alloc, std.math.maxInt(usize));
        const result = mem.trim(u8, result_full, &std.ascii.whitespace);

        _ = try self.child.wait();

        if (result.len == 0) {
            return null;
        }

        return result;
    }
};

pub fn select_writer(alloc: Allocator, label: []const u8) !SelectWriterIntermediate {
    const args = [_][]const u8{ "rofi", "-dmenu", "-no-custom", "-p", label };
    var child = std.process.Child.init(&args, alloc);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    try child.spawn();
    var stdin = child.stdin.?;
    // TODO: buffer writer
    const writer = stdin.writer(&.{}).interface;
    return .{ .child = child, .writer = writer, .alloc = alloc };
}

pub fn select_or_new_writer(alloc: Allocator, label: []const u8) !SelectWriterIntermediate {
    const args = [_][]const u8{ "rofi", "-dmenu", "-p", label };
    var child = std.process.Child.init(&args, alloc);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    try child.spawn();
    var stdin = child.stdin.?;
    // TODO: buffer writer
    const writer = stdin.writer(&.{}).interface;
    return .{ .child = child, .writer = writer, .alloc = alloc };
}

pub fn select_or_new(alloc: Allocator, label: []const u8, items: [][]const u8) !?union(enum) { existing: u32, new: []const u8 } {
    const args = [_][]const u8{ "rofi", "-dmenu", "-p", label };
    var child = std.process.Child.init(&args, alloc);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    try child.spawn();
    for (items) |item| {
        try child.stdin.?.writeAll(item);
        try child.stdin.?.writeAll("\n");
    }
    // child.stdin.?.close();
    const result_full = try child.stdout.?.readToEndAlloc(alloc, std.math.maxInt(usize));
    const result = mem.trim(u8, result_full, &std.ascii.whitespace);

    _ = try child.wait();

    if (result.len == 0) {
        return null;
    }

    for (items, 0..) |item, index| {
        if (mem.eql(u8, result, item)) {
            return .{ .existing = @intCast(index) };
        }
    }
    return .{ .new = result };
}

const refAllDecls = std.testing.refAllDeclsRecursive;
test refAllDecls {
    refAllDecls(@This());
}
