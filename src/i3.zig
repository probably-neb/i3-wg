const std = @import("std");
const net = std.net;
const mem = std.mem;
const debug = std.debug;
const Allocator = mem.Allocator;

pub fn connect(alloc: Allocator) !net.Stream {
    const socket_path = try std.process.getEnvVarOwned(alloc, "I3SOCK");
    const socket = try net.connectUnixSocket(socket_path);
    return socket;
}

const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,
};

fn get_version(socket: net.Stream, alloc: Allocator) !Version {
    try exec_command(socket, .GET_VERSION, "");
    const response_full = try read_reply(socket, alloc, .VERSION);
    const version = try std.json.parseFromSlice(Version, alloc, response_full, .{
        .ignore_unknown_fields = true,
    });
    defer version.deinit();
    return version.value;
}

pub const Workspace = struct {
    id: u64,
    name: []const u8,
    rect: struct {
        x: u32,
        y: u32,
        width: u32,
        height: u32,
    },
    output: []const u8,
    num: u32,
    urgent: bool,
    focused: bool,

    const NameInfo = struct {
        num: ?[]const u8,
        group_name: []const u8,
        name: []const u8,
    };

    pub fn get_name_info(self: *const Workspace) NameInfo {
        const count_colons = blk: {
            var count: u32 = 0;
            for (self.name) |c| {
                count += @intFromBool(c == ':');
            }
            break :blk count;
        };
        switch (count_colons) {
            0 => return .{ .num = self.name, .group_name = "<default>", .name = self.name },
            1 => {
                const part = mem.lastIndexOfScalar(u8, self.name, ':').?;
                return .{ .num = self.name[0..part], .group_name = "<default>", .name = self.name[part + 1 ..] };
            },
            else => {
                const part_a = mem.indexOfScalar(u8, self.name, ':').?;
                const part_b = mem.indexOfScalarPos(u8, self.name, part_a + 1, ':').?;
                return .{
                    .num = self.name[0..part_a],
                    .group_name = self.name[part_a + 1 .. part_b],
                    .name = self.name[part_b + 1 ..],
                };
            },
        }
    }

    pub fn get_group_name(self: Workspace) []const u8 {
        var section_iter = mem.tokenizeScalar(u8, self.name, ':');
        _ = section_iter.next();
        var group_name = section_iter.next() orelse "<default>";
        if (section_iter.next() == null) {
            // set group name to default if only 2 sections
            group_name = "<default>";
        }
        return group_name;
    }

    pub fn format(self: *const @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.writeAll("Workspace{ ");
        const fields = .{ "id", "name", "rect", "output", "num", "urgent", "focused" };
        inline for (fields, 0..) |field, index| {
            if (@TypeOf(@field(self, field)) == []const u8) {
                try writer.print("{s}: \"{s}\"", .{ field, @field(self, field) });
            } else {
                try writer.print("{s}: {any}", .{ field, @field(self, field) });
            }
            if (index < fields.len - 1) {
                try writer.writeAll(", ");
            }
        }
        try writer.writeAll(" }");
    }
};

pub fn get_workspaces(socket: net.Stream, alloc: Allocator) ![]Workspace {
    try exec_command(socket, .GET_WORKSPACES, "");
    const response_full = try read_reply(socket, alloc, .WORKSPACES);
    const response = try std.json.parseFromSlice([]Workspace, alloc, response_full, .{
        .ignore_unknown_fields = true,
    });
    // debug.print("{s}\n", .{response_full});
    return response.value;
}

fn rename_workspace(socket: net.Stream, alloc: Allocator, name: []const u8, to_name: []const u8) !void {
    const command = try std.fmt.allocPrint(alloc, "rename workspace {s} to {s}", .{ name, to_name });
    try exec_command(socket, .RUN_COMMAND, command);
    alloc.free(command);
    const response = try read_reply(socket, alloc, .COMMAND);
    alloc.free(response);

    debug.print("{s}\n", .{response});
}

fn switch_to_workspace(socket: net.Stream, alloc: Allocator, name: []const u8) !void {
    const command = "workspace ";
    try exec_command_len(socket, .RUN_COMMAND, @intCast(command.len + name.len));
    try socket.writeAll(command);
    try socket.writeAll(name);
    try read_reply_expect_single_success_true(socket, alloc, .COMMAND);
    return;
}

const Command = enum(i32) {
    RUN_COMMAND = 0,
    GET_WORKSPACES = 1,
    SUBSCRIBE = 2,
    GET_OUTPUTS = 3,
    GET_TREE = 4,
    GET_MARKS = 5,
    GET_BAR_CONFIG = 6,
    GET_VERSION = 7,
    GET_BINDING_MODES = 8,
    GET_CONFIG = 9,
    SEND_TICK = 10,
    SYNC = 11,
    GET_BINDING_STATE = 12,
};

const Reply = enum(i32) {
    COMMAND = 0,
    WORKSPACES = 1,
    SUBSCRIBE = 2,
    OUTPUTS = 3,
    TREE = 4,
    MARKS = 5,
    BAR_CONFIG = 6,
    VERSION = 7,
    BINDING_MODES = 8,
    GET_CONFIG = 9,
    TICK = 10,
    SYNC = 11,
    GET_BINDING_STATE = 12,
};

const MAGIC_STRING = "i3-ipc";

pub fn exec_command(socket: net.Stream, command: Command, msg: []const u8) !void {
    try socket.writeAll(MAGIC_STRING);
    try socket.writeAll(&mem.toBytes(@as(i32, @intCast(msg.len))));
    try socket.writeAll(&mem.toBytes(@as(i32, @intFromEnum(command))));
    try socket.writeAll(msg);
}

pub fn exec_command_len(socket: net.Stream, command: Command, msg_len: u32) !void {
    try socket.writeAll(MAGIC_STRING);
    try socket.writeAll(&mem.toBytes(@as(i32, @intCast(msg_len))));
    try socket.writeAll(&mem.toBytes(@as(i32, @intFromEnum(command))));
}

pub fn read_reply(socket: net.Stream, alloc: mem.Allocator, expected_reply: Reply) ![]const u8 {
    // PERF: make initial buf with [I3_MAGIC_STRING.len + 4 + 4]u8 to cut number of read calls
    {
        var magic_buffer: [MAGIC_STRING.len]u8 = undefined;
        const magic_read_count = try socket.readAtLeast(&magic_buffer, MAGIC_STRING.len);
        if (magic_read_count != MAGIC_STRING.len or !mem.eql(u8, MAGIC_STRING, &magic_buffer)) {
            return error.InvalidMagic;
        }
    }

    const message_length = blk: {
        var length_buffer: [4]u8 = undefined;
        const length_read_count = try socket.readAtLeast(&length_buffer, 4);
        if (length_read_count != 4) {
            return error.InvalidLength;
        }
        const message_len_i32 = @as(i32, @bitCast(length_buffer));
        if (message_len_i32 < 0) {
            return error.InvalidLength;
        }
        break :blk @as(usize, @intCast(message_len_i32));
    };

    {
        var type_buffer: [4]u8 = undefined;
        const type_read_count = try socket.readAtLeast(&type_buffer, 4);
        if (type_read_count != 4) {
            return error.InvalidType;
        }
        const type_val = @as(i32, @bitCast(type_buffer));
        const reply: Reply = @enumFromInt(type_val);
        if (reply != expected_reply) {
            return error.UnexpectedReplyType;
        }
    }
    const message_buffer = try alloc.alloc(u8, message_length);
    const msg_read_count = try socket.readAtLeast(message_buffer, message_length);
    if (msg_read_count != message_length) {
        return error.InsufficientMessageLength;
    }
    return message_buffer;
}

pub fn read_reply_expect_single_success_true(socket: net.Stream, alloc: mem.Allocator, expected_reply: Reply) !void {
    const expected_response = "[{\"success\":true}]";
    const expected_response_2 = "[{\"success\": true}]";
    var buf_alloc = std.heap.stackFallback(expected_response_2.len + 1, alloc);
    const response = try read_reply(socket, buf_alloc.get(), expected_reply);
    const equals_expected_response = if (response.len >= expected_response_2.len) mem.eql(u8, response[0..expected_response_2.len], expected_response_2) else mem.eql(u8, response[0..expected_response.len], expected_response);
    if (!equals_expected_response) {
        // TODO: parse out error message using original alloc and log / return it
        // can use stack fallback allocator instead of FixedBufferAllocator to get full message if longer than expected (i.e. has error) or create new buf & memcpy buf contents into it
        debug.print("unexpected response: '{s}'\n", .{response});
        return error.UnsuccessfulResponse;
    }
    return;
}
