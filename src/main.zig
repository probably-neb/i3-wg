const std = @import("std");
const net = std.net;
const Allocator = std.mem.Allocator;

const Cli_Commands = enum {
    Help,
    Switch_Active_Workspace_Group,
    Assign_Workspace_To_Group,
    Focus_On_Arbitrary_Workspace,
    Move_Active_Container_To_Arbitrary_Workspace,
    Rename_Workspace,
    Focus_On_Workspace_Number,
    Move_Active_Container_To_Workspace_Number,
    Pretty_List_Workspaces,

    pub const Map = std.StaticStringMap(@This()).initComptime(.{
        .{ "switch-active-workspace-group", .Switch_Active_Workspace_Group },
        .{ "assign-workspace-to-group", .Assign_Workspace_To_Group },
        .{ "focus-on-arbitrary-workspace", .Focus_On_Arbitrary_Workspace },
        .{ "move-active-container-to-arbitrary-workspace", .Move_Active_Container_To_Arbitrary_Workspace },
        .{ "rename-workspace", .Rename_Workspace },
        .{ "focus-workspace-number", .Focus_On_Workspace_Number },
        .{ "move-active-container-to-workspace", .Move_Active_Container_To_Workspace_Number },
        .{ "dbg-pretty-print-workspaces", .Pretty_List_Workspaces },
        .{ "help", .Help },
        .{ "--help", .Help },
        .{ "-h", .Help },
    });
};

pub fn main() !void {
    const base_alloc = std.heap.page_allocator;
    var arena_alloc = std.heap.ArenaAllocator.init(base_alloc);
    const alloc = arena_alloc.allocator();

    var args_iter = try std.process.argsWithAllocator(alloc);
    _ = args_iter.next();

    const socket_path = try std.process.getEnvVarOwned(alloc, "I3SOCK");
    const socket = try net.connectUnixSocket(socket_path);

    const cmd = if (args_iter.next()) |cmd_str| Cli_Commands.Map.get(cmd_str) orelse Cli_Commands.Help else Cli_Commands.Help;
    // TODO: suggest command in case of misspelling
    switch (cmd) {
        .Help => {
            return error.NotImplemented;
        },
        .Switch_Active_Workspace_Group => {
            const workspaces = try I3.get_workspaces(socket, alloc);
            const group_names = try extract_workspace_group_names(alloc, workspaces);
            const choice = try Rofi.select_or_new(alloc, "Switch Active Workspace Group", group_names) orelse return;
            const new_workspace_group_name = switch (choice) {
                .new => |name| name,
                .existing => |index| group_names[index],
            };
            // TODO: get current workspace index and switch to that number in other group if exists
            const new_workspace_num = 100202; // TODO: correctly compute
            const new_workspace_name = try std.fmt.allocPrint(alloc, "{d}:{s}:1", .{ new_workspace_num, new_workspace_group_name });
            try I3.switch_to_workspace(socket, alloc, new_workspace_name);

            return;
        },
        .Assign_Workspace_To_Group => {
            return error.NotImplemented;
        },
        .Focus_On_Arbitrary_Workspace => {
            const workspaces = try I3.get_workspaces(socket, alloc);
            std.mem.sort(I3.Workspace, workspaces, {}, I3.Workspace.sort_by_group_name_and_name_num_less_than);
            const WsNamePair = @typeInfo(@TypeOf(I3.Workspace.get_group_name_and_rest_name)).Fn.return_type.?;
            var names = try alloc.alloc(WsNamePair, workspaces.len);
            var group_name_len_max: u64 = 0;
            var name_len_max: u64 = 0;

            for (workspaces, 0..) |workspace, index| {
                const pair = I3.Workspace.get_group_name_and_rest_name(workspace);
                if (pair.group_name.len > group_name_len_max) {
                    group_name_len_max = pair.group_name.len;
                }
                if (pair.name.len > name_len_max) {
                    name_len_max = pair.name.len;
                }
                names[index] = pair;
            }

            var selection = try Rofi.select_writer(alloc, "Workspace");
            // TODO: Pango markup help text here

            for (names) |pair| {
                try selection.writer.writeByteNTimes(' ', pair.group_name.len -| group_name_len_max);
                try selection.writer.writeAll(pair.group_name);
                try selection.writer.writeByteNTimes(' ', 2 + name_len_max -| pair.name.len);
                try selection.writer.writeAll(pair.name);
                try selection.writer.writeByte('\n');
            }
            const maybe_choice = try selection.finish();
            if (maybe_choice == null) return;
            const choice = maybe_choice.?;
            std.debug.print("choice: {s}\n", .{choice});
            // TODO: if choice contains ":" then create new workspace (and possibly group)
            return error.NotImplemented;
        },
        .Move_Active_Container_To_Arbitrary_Workspace => {
            return error.NotImplemented;
        },
        .Rename_Workspace => {
            return error.NotImplemented;
        },
        .Focus_On_Workspace_Number => {
            return error.NotImplemented;
        },
        .Move_Active_Container_To_Workspace_Number => {
            return error.NotImplemented;
        },
        .Pretty_List_Workspaces => {
            const workspaces = try I3.get_workspaces(socket, alloc);
            try pretty_list_workspaces(alloc, workspaces);
        },
    }
}

fn pretty_list_workspaces(alloc: Allocator, base_workspaces: []I3.Workspace) !void {
    if (base_workspaces.len == 0) {
        return;
    }
    const workspaces = try alloc.dupe(I3.Workspace, base_workspaces);
    defer alloc.free(workspaces);
    std.mem.sort(I3.Workspace, workspaces, {}, I3.Workspace.sort_by_output_less_than);
    var ouput_start_index: u32 = 0;
    var output_end_index: u32 = 1;
    var found_multiple_outputs = false;
    while (output_end_index < workspaces.len) : (output_end_index += 1) {
        const output_a = workspaces[output_end_index - 1].output;
        const output_b = workspaces[output_end_index].output;
        if (!std.mem.eql(u8, output_a, output_b)) {
            std.mem.sort(I3.Workspace, workspaces[ouput_start_index..output_end_index], {}, I3.Workspace.sort_by_name_less_than);
            ouput_start_index = output_end_index;
            found_multiple_outputs = true;
        }
    }
    std.mem.sort(I3.Workspace, workspaces[ouput_start_index..output_end_index], {}, I3.Workspace.sort_by_name_less_than);

    var output = workspaces[0].output;
    const prefix = if (found_multiple_outputs) blk: {
        std.debug.print("{s}:\n", .{output});
        break :blk "   ";
    } else "";
    for (workspaces) |workspace| {
        if (found_multiple_outputs and !std.mem.eql(u8, workspace.output, output)) {
            std.debug.print("{s}:\n", .{workspace.output});
            output = workspace.output;
        }
        std.debug.print("{s}[{s}]\n", .{ prefix, workspace.name });
        std.debug.print("{s}  group: {s}\n", .{ prefix, workspace.get_group_name() });
        std.debug.print("{s}  id: {d}\n", .{ prefix, workspace.id });
        std.debug.print("{s}  num: {d}\n", .{ prefix, workspace.num });
    }
}

fn extract_workspace_group_names(alloc: Allocator, workspaces: []I3.Workspace) ![][]const u8 {
    var names = try std.ArrayList([]const u8).initCapacity(alloc, workspaces.len);
    for (workspaces) |workspace| {
        const group_name = workspace.get_group_name();
        names.appendAssumeCapacity(group_name);
    }
    {
        std.mem.sort(
            []const u8,
            names.items,
            {},
            struct {
                fn less_than(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.lessThan(u8, a, b);
                }
            }.less_than,
        );
        var i: u32 = 1;
        while (i < names.items.len) {
            if (std.mem.eql(u8, names.items[i - 1], names.items[i])) {
                _ = names.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }
    return names.items;
}

const I3 = struct {
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

    const Workspace = struct {
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

        pub fn sort_by_output_less_than(_: void, a: Workspace, b: Workspace) bool {
            return std.mem.lessThan(u8, a.output, b.output);
        }

        pub fn sort_by_name_less_than(_: void, a: Workspace, b: Workspace) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }

        pub fn sort_by_group_name_less_than(_: void, a: Workspace, b: Workspace) bool {
            // TODO: consider caching group_names
            return std.mem.lessThan(u8, a.get_group_name(), b.get_group_name());
        }

        // PERF: rewrite
        pub fn sort_by_group_name_and_name_num_less_than(_: void, a: Workspace, b: Workspace) bool {
            const info_a = a.get_group_name_and_rest_name();
            const info_b = b.get_group_name_and_rest_name();

            if (!std.mem.eql(u8, info_a.group_name, info_b.group_name)) {
                return std.mem.lessThan(u8, info_a.group_name, info_b.group_name);
            }
            return std.mem.lessThan(u8, info_a.name, info_b.name);
        }

        pub fn get_group_name_and_rest_name(self: Workspace) struct { group_name: []const u8, name: []const u8 } {
            var section_iter = std.mem.tokenizeScalar(u8, self.name, ':');
            _ = section_iter.next();
            var group_name = section_iter.next() orelse "<default>";
            const rest_name = section_iter.rest();
            if (section_iter.next() == null) {
                // set group name to default if only 2 sections
                group_name = "<default>";
            }
            return .{ .group_name = group_name, .name = rest_name };
        }

        pub fn get_group_name(self: Workspace) []const u8 {
            var section_iter = std.mem.tokenizeScalar(u8, self.name, ':');
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

    fn get_workspaces(socket: net.Stream, alloc: Allocator) ![]Workspace {
        try exec_command(socket, .GET_WORKSPACES, "");
        const response_full = try read_reply(socket, alloc, .WORKSPACES);
        const response = try std.json.parseFromSlice([]Workspace, alloc, response_full, .{
            .ignore_unknown_fields = true,
        });
        // std.debug.print("{s}\n", .{response_full});
        return response.value;
    }

    fn rename_workspace(socket: net.Stream, alloc: Allocator, name: []const u8, to_name: []const u8) !void {
        const command = try std.fmt.allocPrint(alloc, "rename workspace {s} to {s}", .{ name, to_name });
        try exec_command(socket, .RUN_COMMAND, command);
        alloc.free(command);
        const response = try read_reply(socket, alloc, .COMMAND);
        alloc.free(response);

        std.debug.print("{s}\n", .{response});
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

    fn exec_command(socket: net.Stream, command: Command, msg: []const u8) !void {
        try socket.writeAll(MAGIC_STRING);
        try socket.writeAll(&std.mem.toBytes(@as(i32, @intCast(msg.len))));
        try socket.writeAll(&std.mem.toBytes(@as(i32, @intFromEnum(command))));
        try socket.writeAll(msg);
    }

    fn exec_command_len(socket: net.Stream, command: Command, msg_len: u32) !void {
        try socket.writeAll(MAGIC_STRING);
        try socket.writeAll(&std.mem.toBytes(@as(i32, @intCast(msg_len))));
        try socket.writeAll(&std.mem.toBytes(@as(i32, @intFromEnum(command))));
    }

    fn read_reply(socket: net.Stream, alloc: std.mem.Allocator, expected_reply: Reply) ![]const u8 {
        // PERF: make initial buf with [I3_MAGIC_STRING.len + 4 + 4]u8 to cut number of read calls
        {
            var magic_buffer: [MAGIC_STRING.len]u8 = undefined;
            const magic_read_count = try socket.readAtLeast(&magic_buffer, MAGIC_STRING.len);
            if (magic_read_count != MAGIC_STRING.len or !std.mem.eql(u8, MAGIC_STRING, &magic_buffer)) {
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

    fn read_reply_expect_single_success_true(socket: net.Stream, alloc: std.mem.Allocator, expected_reply: Reply) !void {
        const expected_response = "[{\"success\":true}]";
        const expected_response_2 = "[{\"success\": true}]";
        var buf: [expected_response_2.len + 1]u8 = undefined;
        var buf_alloc = std.heap.FixedBufferAllocator.init(&buf);
        const response = try read_reply(socket, buf_alloc.allocator(), expected_reply);
        std.debug.print("response: '{s}' '{s}'\n", .{ response, expected_response });
        const equals_expected_response = if (response.len >= expected_response_2.len) std.mem.eql(u8, response[0..expected_response_2.len], expected_response_2) else std.mem.eql(u8, response[0..expected_response.len], expected_response);
        if (!equals_expected_response) {
            // TODO: parse out error message using original alloc and log / return it
            _ = alloc;
            return error.UnsuccessfulResponse;
        }
        return;
    }
};

const Rofi = struct {
    pub fn select(alloc: Allocator, label: []const u8, items: [][]const u8) !?u32 {
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
        const result = std.mem.trim(u8, result_full, &std.ascii.whitespace);

        _ = try child.wait();

        if (result.len == 0) {
            return null;
        }

        for (items, 0..) |item, index| {
            if (std.mem.eql(u8, result, item)) {
                return @intCast(index);
            }
        }

        return null;
    }

    const SelectWriterIntermediate = struct {
        child: std.process.Child,
        writer: std.fs.File.Writer,
        alloc: std.mem.Allocator,

        pub fn finish(self: *SelectWriterIntermediate) !?[]const u8 {
            const result_full = try self.child.stdout.?.readToEndAlloc(self.alloc, std.math.maxInt(usize));
            const result = std.mem.trim(u8, result_full, &std.ascii.whitespace);

            _ = try self.child.wait();

            if (result.len == 0) {
                return null;
            }

            return result;
        }
    };

    pub fn select_writer(alloc: Allocator, label: []const u8) !SelectWriterIntermediate {
        const args = [_][]const u8{ "rofi", "-dmenu", "-p", label };
        var child = std.process.Child.init(&args, alloc);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        try child.spawn();
        return .{ .child = child, .writer = child.stdin.?.writer(), .alloc = alloc };
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
        const result = std.mem.trim(u8, result_full, &std.ascii.whitespace);

        _ = try child.wait();

        if (result.len == 0) {
            return null;
        }

        for (items, 0..) |item, index| {
            if (std.mem.eql(u8, result, item)) {
                return .{ .existing = @intCast(index) };
            }
        }
        return .{ .new = result };
    }
};

fn split_N_times(comptime T: type, buf: []const T, needle: T, comptime N: comptime_int) [N][]const T {
    var elems: [N][]const T = undefined;
    var iter = std.mem.tokenizeScalar(T, buf, needle);
    inline for (0..N) |i| {
        elems[i] = iter.next() orelse std.debug.panic("Not Enough Segments in Buf. Failed to split N ({}) times", .{N});
    }
    if (iter.next()) |_| {
        std.debug.panic("Too Many Segments in Buf. Failed to split N ({}) times", .{N});
    }
    return elems;
}

fn split_N_times_seq(comptime T: type, buf: []const T, needle: []const T, comptime N: comptime_int) [N][]const T {
    var elems: [N][]const T = undefined;
    var iter = std.mem.tokenizeSequence(T, buf, needle);
    inline for (0..N) |i| {
        elems[i] = iter.next() orelse std.debug.panic("Not Enough Segments in Buf. Failed to split N ({}) times", .{N});
    }
    if (iter.next()) |_| {
        std.debug.panic("Too Many Segments in Buf. Failed to split N ({}) times", .{N});
    }
    return elems;
}

fn strip_prefix_exact(comptime T: type, buf: []const T, prefix: []const T) []const T {
    std.debug.assert(buf.len > prefix.len);
    std.debug.assert(std.mem.eql(T, buf[0..prefix.len], prefix));
    return buf[prefix.len..];
}
