const std = @import("std");
const net = std.net;
const mem = std.mem;
const debug = std.debug;
const ArrayList = std.ArrayList;
const Allocator = mem.Allocator;

const I3 = @import("i3.zig");
const Rofi = @import("rofi.zig");

const INACTIVE_WORKSPACE_GROUP_FACTOR = 10_000;

const build_mode = @import("builtin").mode;

const SAFETY_CHECKS_ENABLE = build_mode == .Debug or build_mode == .ReleaseSafe;
const DEBUG_ENABLE = build_mode == .Debug;

const Cli_Command = enum {
    Switch_Active_Workspace_Group,
    Assign_Workspace_To_Group,
    Rename_Workspace,
    Focus_Workspace,
    Move_Active_Container_To_Workspace,
    Pretty_List_Workspaces,

    pub const Map = std.StaticStringMap(@This()).initComptime(.{
        .{ "switch-active-workspace-group", .Switch_Active_Workspace_Group },
        .{ "assign-workspace-to-group", .Assign_Workspace_To_Group },
        .{ "rename-workspace", .Rename_Workspace },
        .{ "focus-workspace", .Focus_Workspace },
        .{ "move-active-container-to-workspace", .Move_Active_Container_To_Workspace },
        .{ "dbg-pretty-print-workspaces", .Pretty_List_Workspaces },
    });
};

pub fn main() !void {
    const base_alloc = std.heap.page_allocator;
    var arena_alloc = std.heap.ArenaAllocator.init(base_alloc);
    const alloc = arena_alloc.allocator();

    var args_iter = try std.process.argsWithAllocator(alloc);
    _ = args_iter.next();

    const maybe_cmd: ?Cli_Command = if (args_iter.next()) |cmd_str|
        // TODO: suggest command in case of misspelling
        Cli_Command.Map.get(cmd_str)
    else
        null;
    const cmd: Cli_Command = maybe_cmd orelse {
        // TODO: implement help
        return error.Help_Not_Implemented;
    };

    const socket_path = try std.process.getEnvVarOwned(alloc, "I3SOCK");
    const socket = try net.connectUnixSocket(socket_path);
    defer socket.close();

    var state: State = undefined;
    const i3_workspaces = try I3.get_workspaces(socket, alloc);
    _ = i3_workspaces;
    const workspace_count = try I3.load_workspaces(&state.workspace_store, socket, alloc);
    state.workspaces = try alloc.alloc((*const I3.Workspace), workspace_count);
    for (0..workspace_count) |i| {
        state.workspaces[i] = &state.workspace_store[i];
    }
    state.focused = focused: for (state.workspaces) |workspace| {
        if (workspace.*.focused) {
            break :focused workspace;
        }
    } else null;
    // TODO: actually use
    if (false) {
        const cmd_with_args = try fill_cmd_args(cmd, &state, &args_iter, alloc);
        _ = cmd_with_args;
    }
    try do_cmd(&state, cmd, &args_iter, socket, alloc);
}

const State = struct {
    workspace_store: [WORKSPACE_COUNT_MAX]I3.Workspace,
    workspaces: []*const I3.Workspace,
    focused: ?*const I3.Workspace,

    const WORKSPACE_COUNT_MAX: usize = 512;
};

const Workspace = struct {};

const Cli_Command_With_Arguments = struct {
    cmd: Cli_Command,
    workspace_name: []const u8,
    group_name: []const u8,
    is_new: bool,

    fn zero(cmd: Cli_Command) @This() {
        return .{
            .cmd = cmd,
            .workspace_name = "",
            .group_name = "",
            .is_new = false,
        };
    }
};

// TODO: rename alloc -> arena
fn fill_cmd_args(cmd: Cli_Command, state: *const State, args_iter: *std.process.ArgIterator, alloc: Allocator) !Cli_Command_With_Arguments {
    var get_group = false;
    var get_workspace = false;
    var rofi_label: []const u8 = "";
    var result: Cli_Command_With_Arguments = .zero(cmd);

    switch (cmd) {
        .Pretty_List_Workspaces => {
            return result;
        },
        .Switch_Active_Workspace_Group => {
            get_group = true;
            rofi_label = "Switch Active Workspace Group";
        },
        .Assign_Workspace_To_Group => {
            get_group = true;
            rofi_label = "Workspace Group";
        },
        .Rename_Workspace => {
            get_workspace = true;
        },
        .Focus_Workspace => {
            get_workspace = true;
        },
        .Move_Active_Container_To_Workspace => {
            get_workspace = true;
        },
    }

    const workspaces = state.workspaces;
    if (get_group) get_group: {
        const group_names = try extract_workspace_group_names(alloc, workspaces);
        if (args_iter.next()) |group_name| {
            result.group_name = group_name;
            result.is_new = blk: for (group_names) |existing_group_name| {
                if (mem.eql(u8, group_name, existing_group_name)) {
                    break :blk false;
                }
            } else true;
            break :get_group;
        }
        // TODO: ensure default group is always shown?
        const choice = try Rofi.select_or_new(alloc, rofi_label, group_names) orelse return error.Aborted;
        // TODO: if new_workspace_group_name already exists, don't rename all workspaces
        // TODO: allow entering `group_name:workspace_name` to create new workspace with non number workspace name

        // FIXME: is_new should also be true if new_workspace_group_name == "<default>" and no existing workspaces are in default group
        result.group_name = switch (choice) {
            .new => |name| name,
            .existing => |index| group_names[index],
        };
        result.is_new = choice == .new;
    }

    if (get_workspace) get_workspace: {
        if (args_iter.next()) |workspace_name| {
            result.workspace_name = workspace_name;
            break :get_workspace;
        }
        mem.sort(I3.Workspace, workspaces, {}, I3.Workspace.sort_by_logical_num_and_name_less_than);
        var names = try ArrayList(I3.Workspace.NameInfo).initCapacity(alloc, workspaces.len);
        var group_name_len_max: u64 = 0;
        var name_len_max: u64 = 0;

        for (workspaces) |workspace| {
            const pair = I3.Workspace.get_name_info(workspace);
            if (pair.group_name.len > group_name_len_max) {
                group_name_len_max = pair.group_name.len;
            }
            if (pair.name.len > name_len_max) {
                name_len_max = pair.name.len;
            }
            names.appendAssumeCapacity(pair);
        }

        var selection = try Rofi.select_or_new_writer(alloc, "Workspace");
        // TODO: Pango markup help text here

        for (names.items) |pair| {
            try selection.writer.writeByteNTimes(' ', group_name_len_max -| pair.group_name.len);
            try selection.writer.writeAll(pair.group_name);
            try selection.writer.writeByteNTimes(' ', name_len_max -| pair.name.len + 2);
            try selection.writer.writeAll(pair.name);
            try selection.writer.writeByte('\n');
        }
        const choice = (try selection.finish()) orelse return error.Aborted;
        var choice_iter = mem.tokenizeScalar(u8, choice, ' ');
        _ = choice_iter.next();
        const name = choice_iter.rest();
        if (name.len == 0) {
            return error.InvalidChoice;
        }
        result.workspace_name = name;
    }

    return result;
}

fn do_cmd(state: *State, cmd: Cli_Command, args_iter: *std.process.ArgIterator, socket: net.Stream, alloc: Allocator) !void {
    switch (cmd) {
        .Switch_Active_Workspace_Group => {
            const workspaces = state.workspaces;
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

            const is_default = !is_new and mem.eql(u8, new_workspace_group_name, "<default>");

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
                        if (mem.eql(u8, existing_group_name, group_name)) break :group_name_index index;
                    } else unreachable;

                    debug.assert(group_logical_indices[group_name_index] == 0 or group_logical_indices[group_name_index] == logical_group_index);
                    group_logical_indices[group_name_index] = logical_group_index;

                    if (is_in_active_group(workspace) and active_group.len == 0) {
                        active_group = group_name;
                    } else if (is_in_active_group(workspace)) {
                        // TODO: gracefull handling
                        debug.assert(mem.eql(u8, group_name, active_group));
                    }
                }
                logical_group_count += 1;
                debug.assert(logical_group_count >= group_names.len);
                if (SAFETY_CHECKS_ENABLE) {
                    check_active_group_consistency(workspaces, if (active_group.len > 0) active_group else null);
                }

                if (active_group.len > 0 and mem.eql(u8, active_group, new_workspace_group_name)) {
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

                mem.sort(*const I3.Workspace, workspaces, {}, I3.Workspace.sort_by_logical_num_and_name_less_than);

                // TODO: determine if iterations + retries are still necessary with reverse
                while (iterations < workspaces.len and completed.count() < workspaces.len) : (iterations += 1) {
                    var idx: usize = workspaces.len;
                    while (idx > 0) : (idx -= 1) {
                        const index = idx - 1;
                        const workspace = workspaces[index];
                        if (completed.isSet(index)) continue;

                        const info = workspace.get_name_info();

                        const num_actual = workspace.num % INACTIVE_WORKSPACE_GROUP_FACTOR;
                        const num_logical_orig = @divTrunc(workspace.num, INACTIVE_WORKSPACE_GROUP_FACTOR);
                        const is_group_new_active = !is_new and mem.eql(u8, info.group_name, new_workspace_group_name);
                        const num_logical_new = if (is_group_new_active) 0 else new_logical_group_index_map[num_logical_orig];
                        debug.print(
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

                        const is_group_default = mem.eql(u8, info.group_name, "<default>");
                        // TODO: check if workspace rename is even necessary

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
            const workspaces = state.workspaces;
            const active_workspace = blk: {
                for (workspaces) |workspace| {
                    if (workspace.focused) {
                        break :blk workspace;
                    }
                } else unreachable;
            };

            const group_name = if (args_iter.next()) |_| return error.TODO_Taking_Name_To_Move_To else blk: {
                const group_names = try extract_workspace_group_names(alloc, workspaces);
                const choice = try Rofi.select_or_new(alloc, "Workspace Group", group_names) orelse return;
                switch (choice) {
                    .new => |_| return error.TODO_Allow_New_Group,
                    .existing => |group_name_idx| break :blk group_names[group_name_idx],
                }
                // const random_group_names = []const u8{"foo", "bar", "baz"};
                // TODO: allow creating new group
                // var select = try Rofi.select_writer(alloc, "Workspace Group");
                // for (group_names) |group_name| {
                //     try select.writer.writeAll(group_name);
                //     try select.writer.writeByte('\n');
                // }
                // const group_name = try select.finish() orelse return;

                // const group_name = group_names[group_name_idx];
                // break :blk group_name;
            };

            const group_logical_num = blk: for (workspaces) |workspace| {
                if (std.mem.eql(u8, workspace.get_group_name(), group_name)) {
                    break :blk @divTrunc(workspace.num, INACTIVE_WORKSPACE_GROUP_FACTOR);
                }
            } else unreachable;

            const active_workspace_name_info = active_workspace.get_name_info();

            const active_workspace_actual_num = active_workspace.num % INACTIVE_WORKSPACE_GROUP_FACTOR;

            const workspace_with_num_exists = blk: for (workspaces) |workspace| {
                const workspace_actual_num = workspace.num % INACTIVE_WORKSPACE_GROUP_FACTOR;
                const is_actual_num_same = workspace_actual_num == active_workspace_actual_num;
                const is_group_name_same = std.mem.eql(u8, workspace.get_group_name(), group_name);
                if (is_actual_num_same and is_group_name_same) {
                    break :blk true;
                }
            } else false;

            if (workspace_with_num_exists) {
                return error.TODO_Copying_Over_Containers;
            }

            const active_workspace_num = (group_logical_num * INACTIVE_WORKSPACE_GROUP_FACTOR) + active_workspace_actual_num;

            try I3.exec_command_len(
                socket,
                .RUN_COMMAND,
                @intCast("rename workspace ".len +
                    active_workspace.name.len +
                    " to ".len +
                    workspace_name_parts_len(active_workspace_num, group_name, active_workspace_name_info.name)),
            );
            var writer = socket.writer();
            try writer.writeAll("rename workspace ");
            try writer.writeAll(active_workspace.name);
            try writer.writeAll(" to ");
            try write_workspace_name_parts(writer, active_workspace_num, group_name, active_workspace_name_info.name);
            return;
        },
        .Rename_Workspace => {
            return error.NotImplemented;
        },
        .Focus_Workspace => {
            const workspaces = state.workspaces;

            // TODO: is no active workspace group actually an error here?
            // FIXME: how to handle no active group and no group name...
            const active_workspace_group = get_active_workspace_group(workspaces) orelse return error.NoActiveGroup;

            const name = if (args_iter.next()) |arg| arg else blk: {
                mem.sort(*const I3.Workspace, workspaces, {}, I3.Workspace.sort_by_logical_num_and_name_less_than);
                var names = try ArrayList(I3.Workspace.NameInfo).initCapacity(alloc, workspaces.len);
                var group_name_len_max: u64 = 0;
                var name_len_max: u64 = 0;

                for (workspaces) |workspace| {
                    const pair = I3.Workspace.get_name_info(workspace);
                    if (pair.group_name.len > group_name_len_max) {
                        group_name_len_max = pair.group_name.len;
                    }
                    if (pair.name.len > name_len_max) {
                        name_len_max = pair.name.len;
                    }
                    names.appendAssumeCapacity(pair);
                }

                var selection = try Rofi.select_or_new_writer(alloc, "Workspace");
                // TODO: Pango markup help text here

                for (names.items) |pair| {
                    try selection.writer.writeByteNTimes(' ', group_name_len_max -| pair.group_name.len);
                    try selection.writer.writeAll(pair.group_name);
                    try selection.writer.writeByteNTimes(' ', name_len_max -| pair.name.len + 2);
                    try selection.writer.writeAll(pair.name);
                    try selection.writer.writeByte('\n');
                }
                const maybe_choice = try selection.finish();
                if (maybe_choice == null) return;
                const choice = maybe_choice.?;
                var choice_iter = mem.tokenizeScalar(u8, choice, ' ');
                _ = choice_iter.next();
                const name = choice_iter.rest();
                if (name.len == 0) {
                    return error.InvalidChoice;
                }
                break :blk name;
            };
            debug.print("name = {s}\n", .{name});
            // TODO:
            // - identify whether chosen workspace already exists (and is active workspace group)
            // - if it exists identify he name and switch to it
            // - else create number for it and format name before switching to it

            const workspace_name = blk: {
                // TODO: clone this logic (extract to fn?) to move container to workspace
                const maybe_num = std.fmt.parseInt(u32, name, 10) catch null;

                const group_num_max = gnm: {
                    var group_num_max: u32 = 0;
                    for (workspaces) |workspace| {
                        const is_in_active_workspace_group = is_in_active_group(workspace);
                        if (is_in_active_workspace_group and workspace.num <= 10 and workspace.num > group_num_max) {
                            group_num_max = workspace.num;
                        }
                    }
                    break :gnm group_num_max;
                };

                var workspace_name = try ArrayList(u8).initCapacity(alloc, 3 + active_workspace_group.len + name.len);
                const writer = workspace_name.writer();

                if (maybe_num) |num| {
                    debug.print("is num\n", .{});
                    if (num < INACTIVE_WORKSPACE_GROUP_FACTOR) {
                        for (workspaces) |workspace| {
                            const is_in_active_workspace_group = is_in_active_group(workspace);
                            if (is_in_active_workspace_group and num == workspace.num) {
                                debug.print("workspace '{s}' exists\n", .{workspace.name});
                                workspace_name.deinit();
                                break :blk workspace.name;
                            }
                        } else {
                            const workspace_num = if (num < 10) num else group_num_max + 1;
                            try write_workspace_name_parts(writer, workspace_num, active_workspace_group, name);
                            debug.print("creating workspace named '{s}'\n", .{workspace_name.items});
                            break :blk workspace_name.items;
                        }
                    }
                } else {
                    // otherwise look for a workspace named $name and if we find it return it so we get the workspace number correct
                    for (workspaces) |workspace| {
                        const is_in_active_workspace_group = is_in_active_group(workspace);
                        const name_info = workspace.get_name_info();
                        if (is_in_active_workspace_group and mem.eql(u8, name_info.name, name)) {
                            break :blk workspace.name;
                        }
                    }
                }

                debug.print("creating non-num workspace named '{s}'\n", .{workspace_name.items});
                try write_workspace_name_parts(writer, group_num_max + 1, active_workspace_group, name);
                break :blk workspace_name.items;
            };

            const command_len = "workspace ".len + workspace_name.len;
            try I3.exec_command_len(socket, .RUN_COMMAND, @intCast(command_len));
            var writer = socket.writer();
            try writer.writeAll("workspace ");
            try writer.writeAll(workspace_name);

            try I3.read_reply_expect_single_success_true(socket, alloc, .COMMAND);
        },
        .Move_Active_Container_To_Workspace => {
            const workspaces = state.workspaces;

            const workspace_user_name = if (args_iter.next()) |arg| arg else blk: {
                var active_group_workspaces = try ArrayList(I3.Workspace.NameInfo).initCapacity(alloc, workspaces.len);
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

                var selection = try Rofi.select_or_new_writer(alloc, "Workspace");
                // TODO: Pango markup help text here

                for (active_group_workspaces.items) |name_info| {
                    try selection.writer.writeByteNTimes(' ', group_name_len_max -| name_info.group_name.len);
                    try selection.writer.writeAll(name_info.group_name);
                    try selection.writer.writeByte(':');
                    try selection.writer.writeAll(name_info.name);
                    try selection.writer.writeByte('\n');
                }
                const choice = try selection.finish() orelse return;
                debug.print("selection: {s}\n", .{choice});
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

            if (mem.indexOfScalar(u8, workspace_user_name, ':')) |colon_pos| {
                workspace_name = workspace_user_name[colon_pos + 1 ..];
                workspace_group_name = workspace_user_name[0..colon_pos];
                const is_new_group = blk: for (workspaces) |workspace| {
                    if (mem.eql(u8, workspace_group_name, workspace.get_group_name())) {
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

            if (parse_workspace_name_num(workspace_name)) |num| {
                workspace_num = num;
            }

            for (workspaces) |workspace| {
                const name_info = workspace.get_name_info();
                if (mem.eql(u8, name_info.group_name, workspace_group_name)) {
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
            try pretty_list_workspaces(alloc, state);
        },
    }
}

fn pretty_list_workspaces(alloc: Allocator, state: *const State) !void {
    if (state.workspaces.len == 0) {
        return;
    }
    const workspaces = try alloc.dupe((*const I3.Workspace), state.workspaces);
    mem.sort(*const I3.Workspace, workspaces, {}, I3.Workspace.sort_by_output_less_than);
    var ouput_start_index: u32 = 0;
    var output_end_index: u32 = 1;
    var found_multiple_outputs = false;
    while (output_end_index < workspaces.len) : (output_end_index += 1) {
        const output_a = workspaces[output_end_index - 1].output;
        const output_b = workspaces[output_end_index].output;
        if (!mem.eql(u8, output_a, output_b)) {
            mem.sort(*const I3.Workspace, workspaces[ouput_start_index..output_end_index], {}, I3.Workspace.sort_by_name_less_than);
            ouput_start_index = output_end_index;
            found_multiple_outputs = true;
        }
    }
    mem.sort(*const I3.Workspace, workspaces[ouput_start_index..output_end_index], {}, I3.Workspace.sort_by_name_less_than);

    var output = workspaces[0].output;
    const prefix = if (found_multiple_outputs) blk: {
        debug.print("{s}:\n", .{output});
        break :blk "   ";
    } else "";
    for (workspaces) |workspace| {
        if (found_multiple_outputs and !mem.eql(u8, workspace.output, output)) {
            debug.print("{s}:\n", .{workspace.output});
            output = workspace.output;
        }
        debug.print("{s}[{s}]\n", .{ prefix, workspace.name });
        debug.print("{s}  group: {s}\n", .{ prefix, workspace.get_group_name() });
        debug.print("{s}  id: {d}\n", .{ prefix, workspace.id });
        debug.print("{s}  num: {d}\n", .{ prefix, workspace.num });
    }
}

fn write_workspace_name_parts(writer: anytype, num: u32, group_name: []const u8, name: []const u8) !void {
    try std.fmt.formatInt(num, 10, .lower, .{}, writer);
    try writer.writeByte(':');
    if (group_name.len > 0 and !mem.eql(u8, group_name, "<default>")) {
        try writer.writeAll(group_name);
        try writer.writeByte(':');
    }
    try writer.writeAll(name);
}

fn workspace_name_parts_len(num: u32, group_name: []const u8, name: []const u8) u32 {
    var len: u64 = 0;
    len += count_digits(num);
    len += ":".len;
    if (group_name.len > 0 and !mem.eql(u8, group_name, "<default>")) {
        len += group_name.len;
        len += ":".len;
    }
    len += name.len;
    return @intCast(len);
}

fn extract_workspace_group_names(alloc: Allocator, workspaces: []*const I3.Workspace) ![][]const u8 {
    var names = try ArrayList([]const u8).initCapacity(alloc, workspaces.len);
    for (workspaces) |workspace| {
        const group_name = workspace.get_group_name();
        names.appendAssumeCapacity(group_name);
    }
    {
        mem.sort(
            []const u8,
            names.items,
            {},
            struct {
                fn less_than(_: void, a: []const u8, b: []const u8) bool {
                    return mem.lessThan(u8, a, b);
                }
            }.less_than,
        );
        var i: u32 = 1;
        while (i < names.items.len) {
            if (mem.eql(u8, names.items[i - 1], names.items[i])) {
                _ = names.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }
    return names.items;
}

fn get_active_workspace_group(workspaces: []*const I3.Workspace) ?[]const u8 {
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

fn check_active_group_consistency(workspaces: []*const I3.Workspace, _active_workspace_group: ?[]const u8) void {
    var active_workspace_group = _active_workspace_group;
    for (workspaces) |workspace| {
        if (is_in_active_group(workspace)) {
            if (active_workspace_group) |group| {
                debug.assert(mem.eql(u8, workspace.get_group_name(), group));
            } else {
                active_workspace_group = workspace.get_group_name();
            }
        }
    }
}

fn is_in_active_group(workspace: *const I3.Workspace) bool {
    return workspace.num < INACTIVE_WORKSPACE_GROUP_FACTOR;
}

fn parse_workspace_name_num(workspace_name: []const u8) ?u32 {
    var name = workspace_name;
    if (mem.lastIndexOfScalar(u8, name, ':')) |colon_pos| {
        name = name[colon_pos + 1 ..];
    }
    return std.fmt.parseInt(u32, name, 10) catch null;
}
fn split_N_times(comptime T: type, buf: []const T, needle: T, comptime N: comptime_int) [N][]const T {
    var elems: [N][]const T = undefined;
    var iter = mem.tokenizeScalar(T, buf, needle);
    inline for (0..N) |i| {
        elems[i] = iter.next() orelse debug.panic("Not Enough Segments in Buf. Failed to split N ({}) times", .{N});
    }
    if (iter.next()) |_| {
        debug.panic("Too Many Segments in Buf. Failed to split N ({}) times", .{N});
    }
    return elems;
}

fn split_N_times_seq(comptime T: type, buf: []const T, needle: []const T, comptime N: comptime_int) [N][]const T {
    var elems: [N][]const T = undefined;
    var iter = mem.tokenizeSequence(T, buf, needle);
    inline for (0..N) |i| {
        elems[i] = iter.next() orelse debug.panic("Not Enough Segments in Buf. Failed to split N ({}) times", .{N});
    }
    if (iter.next()) |_| {
        debug.panic("Too Many Segments in Buf. Failed to split N ({}) times", .{N});
    }
    return elems;
}

fn strip_prefix_exact(comptime T: type, buf: []const T, prefix: []const T) []const T {
    debug.assert(buf.len > prefix.len);
    debug.assert(mem.eql(T, buf[0..prefix.len], prefix));
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
