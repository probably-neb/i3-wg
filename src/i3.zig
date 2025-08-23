const std = @import("std");
const net = std.net;
const mem = std.mem;
const debug = std.debug;
const Allocator = mem.Allocator;
const Io = std.Io;
const is_test = @import("builtin").is_test;

pub fn connect(alloc: Allocator) !net.Stream {
    const socket_path = try std.process.getEnvVarOwned(alloc, "I3SOCK");
    // defer alloc.free(socket_path);
    const socket = try net.connectUnixSocket(socket_path);
    return socket;
}

pub const Workspace = struct {
    id: i64,
    name: []const u8,
    // PERF: don't parse useless data
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

pub fn get_workspaces(writer: *Io.Writer, reader: *Io.Reader, alloc: Allocator) ![]Workspace {
    try exec_command(writer, .GET_WORKSPACES, "");
    try writer.flush();
    const response_full = try read_reply(reader, alloc, .WORKSPACES);
    const response = try std.json.parseFromSlice([]Workspace, alloc, response_full, .{
        .ignore_unknown_fields = true,
    });
    return response.value;
}

pub fn rename_workspace(socket: *Io.Writer, comptime source_fmt: []const u8, source: anytype, comptime target_fmt: []const u8, target: anytype) !void {
    const fmt = "rename workspace " ++ source_fmt ++ " to " ++ target_fmt;
    try exec_command_print(socket, .RUN_COMMAND, fmt, .{ source, target });
}

pub fn switch_to_workspace(socket: *Io.Writer, comptime name_fmt: []const u8, name: anytype) !void {
    const fmt = "workspace " ++ name_fmt;
    try exec_command_print(socket, .RUN_COMMAND, fmt, .{name});
}

pub fn move_active_container_to_workspace(socket: *Io.Writer, comptime name_fmt: []const u8, name: anytype) !void {
    const fmt = "move container to workspace " ++ name_fmt;
    try exec_command_print(socket, .RUN_COMMAND, fmt, .{name});
}

pub const Command = enum(i32) {
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

pub const Reply = enum(i32) {
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

pub fn exec_command(socket: *Io.Writer, command: Command, msg: []const u8) !void {
    try socket.writeAll(MAGIC_STRING);
    try socket.writeAll(&mem.toBytes(@as(i32, @intCast(msg.len))));
    try socket.writeAll(&mem.toBytes(@as(i32, @intFromEnum(command))));
    try socket.writeAll(msg);
}

pub fn exec_command_len(socket: *Io.Writer, command: Command, msg_len: u32) !void {
    try socket.writeAll(MAGIC_STRING);
    try socket.writeAll(&mem.toBytes(@as(i32, @intCast(msg_len))));
    try socket.writeAll(&mem.toBytes(@as(i32, @intFromEnum(command))));
}

pub fn exec_command_print(socket: *Io.Writer, command: Command, comptime msg: []const u8, args: anytype) !void {
    try exec_command_len(socket, command, @intCast(std.fmt.count(msg, args)));
    try socket.print(msg, args);
}

pub fn read_msg_header(socket: *Io.Reader) !usize {
    {
        var magic_buffer: [MAGIC_STRING.len]u8 = undefined;
        const magic_read_count = try socket.readSliceShort(&magic_buffer);
        if (magic_read_count != MAGIC_STRING.len or !mem.eql(u8, MAGIC_STRING, &magic_buffer)) {
            return error.InvalidMagic;
        }
    }

    const message_length = blk: {
        var length_buffer: [4]u8 = undefined;
        const length_read_count = try socket.readSliceShort(&length_buffer);
        if (length_read_count != 4) {
            return error.InvalidLength;
        }
        const message_len_i32 = @as(i32, @bitCast(length_buffer));
        if (message_len_i32 < 0) {
            return error.InvalidLength;
        }
        break :blk @as(usize, @intCast(message_len_i32));
    };
    return message_length;
}

pub fn read_msg_kind(comptime Msg: type, socket: *Io.Reader) !Msg {
    var type_buffer: [4]u8 = undefined;
    const type_read_count = try socket.readSliceShort(&type_buffer);
    if (type_read_count != type_buffer.len) {
        return error.InvalidType;
    }
    const type_val = @as(i32, @bitCast(type_buffer));
    const reply: Msg = @enumFromInt(type_val);
    return reply;
}

pub fn read_reply(socket: *Io.Reader, alloc: mem.Allocator, expected_reply: Reply) ![]const u8 {
    // PERF: make initial buf with [I3_MAGIC_STRING.len + 4 + 4]u8 to cut number of read calls
    const message_length = try read_msg_header(socket);

    const reply = try read_msg_kind(Reply, socket);
    if (reply != expected_reply) {
        return error.UnexpectedReplyType;
    }
    const message_buffer = try socket.readAlloc(alloc, message_length);
    if (message_buffer.len != message_length) {
        return error.InsufficientMessageLength;
    }
    return message_buffer;
}

pub fn read_reply_expect_single_success_true(socket: *Io.Reader, alloc: mem.Allocator, expected_reply: Reply) !void {
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

const refAllDecls = std.testing.refAllDeclsRecursive;

test refAllDecls {
    refAllDecls(@This());
}
