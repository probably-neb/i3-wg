const std = @import("std");
const net = std.net;
const Allocator = std.mem.Allocator;

const INACTIVE_WORKSPACE_GROUP_FACTOR = 10_000;

const build_mode = @import("builtin").mode;

const SAFETY_CHECKS_ENABLE = build_mode == .Debug or build_mode == .ReleaseSafe;
const DEBUG_ENABLE = build_mode == .Debug;

const Cli_Commands = enum {
    Help,
    Switch_Active_Workspace_Group,
    Assign_Workspace_To_Group,
    Focus_Workspace_Select,
    Rename_Workspace,
    Focus_Workspace,
    Move_Active_Container_To_Workspace,
    Pretty_List_Workspaces,

    pub const Map = std.StaticStringMap(@This()).initComptime(.{
        .{ "switch-active-workspace-group", .Switch_Active_Workspace_Group },
        .{ "assign-workspace-to-group", .Assign_Workspace_To_Group },
        .{ "focus-workspace-select", .Focus_Workspace_Select },
        .{ "rename-workspace", .Rename_Workspace },
        .{ "focus-workspace", .Focus_Workspace },
        .{ "move-active-container-to-workspace", .Move_Active_Container_To_Workspace },
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
    defer socket.close();

    const cmd = if (args_iter.next()) |cmd_str| Cli_Commands.Map.get(cmd_str) orelse Cli_Commands.Help else Cli_Commands.Help;
    // TODO: suggest command in case of misspelling
    switch (cmd) {
        .Help => {
            return error.NotImplemented;
        },
        .Switch_Active_Workspace_Group => {
            const workspaces = try I3.get_workspaces(socket, alloc);
            const group_names = try extract_workspace_group_names(alloc, workspaces);
            // TODO: ensure default group is always shown?
            const choice = try Rofi.select_or_new(alloc, "Switch Active Workspace Group", group_names) orelse return;
            // TODO: if new_workspace_group_name already exists, don't rename all workspaces
            // TODO: allow entering `group_name:workspace_name` to create new workspace with non number workspace name
            const new_workspace_group_name = switch (choice) {
                .new => |name| name,
                .existing => |index| group_names[index],
            };
            // FIXME: is_new should also be true if new_workspace_group_name == "<default>" and no existing workspaces are in default group
            const is_new = choice == .new;

            const is_default = !is_new and std.mem.eql(u8, new_workspace_group_name, "<default>");

            // ?TODO: consider if focused workspace is also in active workspace group, using it's number
            // TODO: if switching to exisiting group, and not doing current ws number, switch to lowest number in that group
            const new_workspace_num = 1;

            // FIXME: rename all workspaces here if group not active (or new)
            renaming: {
                // number of groups based on unique
                var group_logical_indices = try alloc.alloc(u32, group_names.len);
                @memset(group_logical_indices, 0);

                var active_group: []const u8 = "";
                var logical_group_count: u32 = 0; // default 1 for <default> group
                for (workspaces) |workspace| {
                    const logical_group_index = @divTrunc(workspace.num, INACTIVE_WORKSPACE_GROUP_FACTOR);
                    if (logical_group_index > logical_group_count) {
                        logical_group_count = logical_group_index;
                    }

                    const group_name = workspace.get_group_name();
                    const group_name_index = group_name_index: for (group_names, 0..) |existing_group_name, index| {
                        if (std.mem.eql(u8, existing_group_name, group_name)) break :group_name_index index;
                    } else unreachable;

                    std.debug.assert(group_logical_indices[group_name_index] == 0 or group_logical_indices[group_name_index] == logical_group_index);
                    group_logical_indices[group_name_index] = logical_group_index;

                    if (is_in_active_group(workspace) and active_group.len == 0) {
                        active_group = group_name;
                    } else if (is_in_active_group(workspace)) {
                        std.debug.assert(std.mem.eql(u8, group_name, active_group));
                    }
                }
                logical_group_count += 1;
                std.debug.assert(logical_group_count >= group_names.len);
                if (SAFETY_CHECKS_ENABLE) {
                    check_active_group_consistency(workspaces, if (active_group.len > 0) active_group else null);
                }

                if (active_group.len > 0 and std.mem.eql(u8, active_group, new_workspace_group_name)) {
                    break :renaming;
                }

                // actually inverted (set => not found, unset => found) because api only provides findFirstSet not findFirstUnset
                var found_logical_group_index_map = try std.DynamicBitSetUnmanaged.initFull(alloc, logical_group_count + 1); // +1 for final always unset bit
                for (workspaces) |workspace| {
                    const logical_group_index = @divTrunc(workspace.num, INACTIVE_WORKSPACE_GROUP_FACTOR);
                    found_logical_group_index_map.unset(logical_group_index);
                }

                //PERF: just check if < pivot logical_group_index+=1 instead of allocating lut
                var new_logical_group_index_map = try alloc.alloc(u32, logical_group_count);
                const pivot = found_logical_group_index_map.findFirstSet().?;
                for (0..pivot) |i| {
                    new_logical_group_index_map[i] = @intCast(i + 1);
                }

                for (pivot..logical_group_count) |i| {
                    new_logical_group_index_map[i] = @intCast(i);
                }

                // FIXME: handle write or rename failure (easier if writes are batched and we have an intermediate buffer of name mappings)
                // PERF: batch all rename calls
                var completed = try std.DynamicBitSet.initEmpty(alloc, workspaces.len);
                var iterations: usize = 0;

                // TODO: determine whether rename conflicts (resulting in need to retry) actually happen now that bugs are fixed
                while (completed.count() < workspaces.len and iterations < 100) : (iterations += 1) {
                    for (workspaces, 0..) |workspace, index| {
                        if (completed.isSet(index)) continue;

                        const info = workspace.get_name_info();

                        const num_actual = workspace.num % INACTIVE_WORKSPACE_GROUP_FACTOR;
                        const num_logical_orig = @divTrunc(workspace.num, INACTIVE_WORKSPACE_GROUP_FACTOR);
                        const is_group_new_active = !is_new and std.mem.eql(u8, info.group_name, new_workspace_group_name);
                        const num_logical_new = if (is_group_new_active) 0 else new_logical_group_index_map[num_logical_orig];
                        std.debug.print(
                            "workspace {s} name='{s}' with logical group {d} and actual {d} becomes logical group {d} and actual {d}\n",
                            .{
                                workspace.name,
                                info.name,
                                num_logical_orig,
                                num_actual,
                                num_logical_new,
                                num_actual,
                            },
                        );

                        const new_combined_num = (num_logical_new * INACTIVE_WORKSPACE_GROUP_FACTOR) + num_actual;

                        const is_group_default = std.mem.eql(u8, info.group_name, "<default>");

                        const command_len =
                            "rename workspace ".len +
                            workspace.name.len +
                            " to ".len +
                            count_digits(new_combined_num) +
                            ":".len +
                            (if (is_group_default) 0 else info.group_name.len + ":".len) +
                            info.name.len;
                        try I3.exec_command_len(socket, .RUN_COMMAND, @intCast(command_len));
                        var writer = socket.writer();
                        try writer.writeAll("rename workspace ");
                        try writer.writeAll(workspace.name);
                        try writer.writeAll(" to ");
                        try std.fmt.formatInt(new_combined_num, 10, .lower, .{}, writer);
                        try writer.writeByte(':');
                        if (!is_group_default) {
                            try writer.writeAll(info.group_name);
                            try writer.writeByte(':');
                        }
                        try writer.writeAll(info.name);

                        var success = true;
                        I3.read_reply_expect_single_success_true(socket, alloc, .COMMAND) catch {
                            success = false;
                        };
                        if (success) {
                            completed.set(index);
                        }
                    }
                }
            }

            const command_len =
                "workspace ".len +
                count_digits(new_workspace_num) +
                ":".len +
                (if (is_default) 0 else new_workspace_group_name.len + ":".len) +
                count_digits(new_workspace_num);

            try I3.exec_command_len(socket, .RUN_COMMAND, @intCast(command_len));

            var writer = socket.writer();

            try writer.writeAll("workspace ");
            try std.fmt.formatInt(new_workspace_num, 10, .lower, .{}, writer);
            try writer.writeByte(':');
            if (!is_default) {
                try writer.writeAll(new_workspace_group_name);
                try writer.writeByte(':');
            }
            try std.fmt.formatInt(new_workspace_num, 10, .lower, .{}, writer);
            try I3.read_reply_expect_single_success_true(socket, alloc, .COMMAND);
            return;
        },
        .Assign_Workspace_To_Group => {
            return error.NotImplemented;
        },
        .Focus_Workspace_Select => {
            const workspaces = try I3.get_workspaces(socket, alloc);
            std.mem.sort(I3.Workspace, workspaces, {}, I3.Workspace.sort_by_group_name_and_name_num_less_than);
            var names = try alloc.alloc(I3.Workspace.NameInfo, workspaces.len);
            var group_name_len_max: u64 = 0;
            var name_len_max: u64 = 0;

            for (workspaces, 0..) |workspace, index| {
                const pair = I3.Workspace.get_name_info(workspace);
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
                try selection.writer.writeByteNTimes(' ', group_name_len_max -| pair.group_name.len);
                try selection.writer.writeAll(pair.group_name);
                try selection.writer.writeByteNTimes(' ', name_len_max -| pair.name.len + 2);
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
        .Rename_Workspace => {
            return error.NotImplemented;
        },
        .Focus_Workspace => {
            const workspaces = try I3.get_workspaces(socket, alloc);

            const name = args_iter.next() orelse return error.MissingArgument;

            // TODO: is no active workspace group actually an error here?
            const active_workspace_group = get_active_workspace_group(workspaces) orelse return error.NoActiveWorkspaceGroup;
            // TODO:
            // - identify whether chosen workspace already exists (and is active workspace group)
            // - if it exists identify the name and switch to it
            // - else create number for it and format name before switching to it

            const workspace_num = blk: {
                const name_num: ?u32 = std.fmt.parseUnsigned(u32, name, 10) catch null;
                if (name_num != null and name_num.? < 10) {
                    break :blk name_num.?;
                }
                for (workspaces) |workspace| {
                    const info = workspace.get_name_info();
                    if (std.mem.eql(u8, info.name, name)) {
                        break :blk workspace.num;
                    }
                }
                var group_num_max: u32 = 0;
                for (workspaces) |workspace| {
                    if (std.mem.eql(u8, workspace.get_group_name(), active_workspace_group) and workspace.num > group_num_max) {
                        group_num_max = workspace.num;
                    }
                }
                break :blk group_num_max + 1;
            };

            const workspace_group_name = if (std.mem.eql(u8, active_workspace_group, "<default>")) "" else active_workspace_group;

            const command_len =
                "workspace ".len +
                count_digits(workspace_num) +
                ":".len +
                workspace_group_name.len +
                (if (workspace_group_name.len == 0) 0 else ":".len) +
                name.len;

            try I3.exec_command_len(socket, .RUN_COMMAND, @intCast(command_len));
            var writer = socket.writer();

            try writer.writeAll("workspace ");
            try std.fmt.formatInt(workspace_num, 10, .lower, .{}, writer);
            try writer.writeByte(':');
            if (workspace_group_name.len > 0) {
                try writer.writeAll(workspace_group_name);
                try writer.writeByte(':');
            }
            try socket.writeAll(name);

            try I3.read_reply_expect_single_success_true(socket, alloc, .COMMAND);
        },
        .Move_Active_Container_To_Workspace => {
            const workspaces = try I3.get_workspaces(socket, alloc);

            const workspace_user_name = if (args_iter.next()) |arg| arg else blk: {
                var active_group_workspaces = try std.ArrayList(I3.Workspace.NameInfo).initCapacity(alloc, workspaces.len);
                var group_name_len_max: u64 = 0;
                for (workspaces) |workspace| {
                    if (is_in_active_group(workspace)) {
                        const name_info = workspace.get_name_info();
                        active_group_workspaces.appendAssumeCapacity(name_info);
                        if (name_info.group_name.len > group_name_len_max) {
                            group_name_len_max = name_info.group_name.len;
                        }
                    }
                }

                var selection = try Rofi.select_writer(alloc, "Workspace");
                // TODO: Pango markup help text here

                for (active_group_workspaces.items) |name_info| {
                    try selection.writer.writeByteNTimes(' ', group_name_len_max -| name_info.group_name.len);
                    try selection.writer.writeAll(name_info.group_name);
                    try selection.writer.writeByte(':');
                    try selection.writer.writeAll(name_info.name);
                    try selection.writer.writeByte('\n');
                }
                const choice = try selection.finish() orelse return;
                std.debug.print("selection: {s}\n", .{choice});
                break :blk choice;
            };

            const active_workspace_group = get_active_workspace_group(workspaces);

            var workspace_name = workspace_user_name;
            var workspace_group_name = active_workspace_group orelse "<default>";
            var workspace_logical_group_index: u32 = 0;
            var workspace_num = blk: for (workspaces) |workspace| {
                if (workspace.focused) {
                    break :blk workspace.num % INACTIVE_WORKSPACE_GROUP_FACTOR;
                }
            } else 1;

            if (std.mem.indexOfScalar(u8, workspace_user_name, ':')) |colon_pos| {
                workspace_name = workspace_user_name[colon_pos + 1 ..];
                workspace_group_name = workspace_user_name[0..colon_pos];
                const is_new_group = blk: for (workspaces) |workspace| {
                    if (std.mem.eql(u8, workspace_group_name, workspace.get_group_name())) {
                        break :blk false;
                    }
                } else true;

                if (is_new_group) {
                    var workspace_logical_group_index_max: u32 = 0;
                    for (workspaces) |workspace| {
                        const logical_group_index = @divTrunc(workspace.num, INACTIVE_WORKSPACE_GROUP_FACTOR);
                        if (logical_group_index > workspace_logical_group_index_max) {
                            workspace_logical_group_index_max = logical_group_index;
                        }
                    }
                    workspace_logical_group_index = workspace_logical_group_index_max + 1;
                }
            }

            const workspace_num_str = if (std.mem.lastIndexOfScalar(u8, workspace_name, ':')) |last_colon_pos|
                workspace_name[last_colon_pos + 1 ..]
            else
                workspace_name;

            if (std.fmt.parseInt(u32, workspace_num_str, 10) catch null) |num| {
                workspace_num = num;
            }

            for (workspaces) |workspace| {
                const name_info = workspace.get_name_info();
                if (std.mem.eql(u8, name_info.group_name, workspace_group_name)) {
                    workspace_logical_group_index = @divTrunc(workspace.num, INACTIVE_WORKSPACE_GROUP_FACTOR);
                    break;
                }
            }
            if (workspace_logical_group_index > 0) {
                workspace_num += (INACTIVE_WORKSPACE_GROUP_FACTOR * workspace_logical_group_index);
            }

            const command_len =
                "move container to workspace ".len +
                workspace_name_parts_len(
                workspace_num,
                workspace_group_name,
                workspace_name,
            );
            try I3.exec_command_len(socket, .RUN_COMMAND, @intCast(command_len));
            var writer = socket.writer();
            try writer.writeAll("move container to workspace ");
            try write_workspace_name_parts(
                writer,
                workspace_num,
                workspace_group_name,
                workspace_name,
            );
            try I3.read_reply_expect_single_success_true(socket, alloc, .COMMAND);
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

fn write_workspace_name_parts(writer: anytype, num: u32, group_name: []const u8, name: []const u8) !void {
    try std.fmt.formatInt(num, 10, .lower, .{}, writer);
    try writer.writeByte(':');
    if (group_name.len > 0 and !std.mem.eql(u8, group_name, "<default>")) {
        try writer.writeAll(group_name);
        try writer.writeByte(':');
    }
    try writer.writeAll(name);
}

fn workspace_name_parts_len(num: u32, group_name: []const u8, name: []const u8) u32 {
    var len: u64 = 0;
    len += count_digits(num);
    len += ":".len;
    if (group_name.len > 0 and !std.mem.eql(u8, group_name, "<default>")) {
        len += group_name.len;
        len += ":".len;
    }
    len += name.len;
    return @intCast(len);
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

fn get_active_workspace_group(workspaces: []I3.Workspace) ?[]const u8 {
    var active_workspace_group: ?[]const u8 = null;
    for (workspaces) |workspace| {
        if (is_in_active_group(workspace)) {
            active_workspace_group = workspace.get_group_name();
            break;
        }
    }
    if (SAFETY_CHECKS_ENABLE) {
        check_active_group_consistency(workspaces, active_workspace_group);
    }

    return active_workspace_group;
}

fn check_active_group_consistency(workspaces: []I3.Workspace, _active_workpace_group: ?[]const u8) void {
    var active_workpace_group: ?[]const u8 = _active_workpace_group;
    for (workspaces) |workspace| {
        if (is_in_active_group(workspace)) {
            if (active_workpace_group) |group| {
                std.debug.assert(std.mem.eql(u8, workspace.get_group_name(), group));
            } else {
                active_workpace_group = workspace.get_group_name();
            }
        }
    }
}

fn is_in_active_group(workspace: I3.Workspace) bool {
    return workspace.num < INACTIVE_WORKSPACE_GROUP_FACTOR;
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
            const info_a = a.get_name_info();
            const info_b = b.get_name_info();

            if (!std.mem.eql(u8, info_a.group_name, info_b.group_name)) {
                return std.mem.lessThan(u8, info_a.group_name, info_b.group_name);
            }
            return std.mem.lessThan(u8, info_a.name, info_b.name);
        }

        const NameInfo = struct {
            num: ?[]const u8,
            group_name: []const u8,
            name: []const u8,
        };

        pub fn get_name_info(self: Workspace) NameInfo {
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
                    const part = std.mem.lastIndexOfScalar(u8, self.name, ':').?;
                    return .{ .num = self.name[0..part], .group_name = "<default>", .name = self.name[part + 1 ..] };
                },
                else => {
                    const part_a = std.mem.indexOfScalar(u8, self.name, ':').?;
                    const part_b = std.mem.indexOfScalarPos(u8, self.name, part_a + 1, ':').?;
                    return .{
                        .num = self.name[0..part_a],
                        .group_name = self.name[part_a + 1 .. part_b],
                        .name = self.name[part_b + 1 ..],
                    };
                },
            }
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
        var buf_alloc = std.heap.stackFallback(expected_response_2.len + 1, alloc);
        const response = try read_reply(socket, buf_alloc.get(), expected_reply);
        const equals_expected_response = if (response.len >= expected_response_2.len) std.mem.eql(u8, response[0..expected_response_2.len], expected_response_2) else std.mem.eql(u8, response[0..expected_response.len], expected_response);
        if (!equals_expected_response) {
            // TODO: parse out error message using original alloc and log / return it
            // can use stack fallback allocator instead of FixedBufferAllocator to get full message if longer than expected (i.e. has error) or create new buf & memcpy buf contents into it
            std.debug.print("unexpected response: '{s}'\n", .{response});
            return error.UnsuccessfulResponse;
        }
        return;
    }
};

const Rofi = struct {
    pub fn select(alloc: Allocator, label: []const u8, items: [][]const u8) !?u32 {
        const args = [_][]const u8{ "rofi", "-dmenu", "-p", label, "-no-custom" };
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

fn count_digits(num: anytype) usize {
    if (num == 0) return 1;
    const val: u128 = if (num < 0) @intCast(-num) else num;
    return std.math.log10_int(val) + 1;
}

test count_digits {
    try std.testing.expectEqual(1, count_digits(1));
    try std.testing.expectEqual(1, count_digits(0));
    try std.testing.expectEqual(2, count_digits(10));
    try std.testing.expectEqual(2, count_digits(99));
    try std.testing.expectEqual(3, count_digits(100));
    try std.testing.expectEqual(3, count_digits(999));
    try std.testing.expectEqual(4, count_digits(-1000));
}
