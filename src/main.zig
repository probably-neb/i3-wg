const std = @import("std");
const net = std.net;
const mem = std.mem;
const debug = std.debug;
const ArrayList = std.ArrayList;
const Allocator = mem.Allocator;
const Io = std.Io;

const I3 = @import("i3.zig");
const Rofi = @import("rofi.zig");

const INACTIVE_WORKSPACE_GROUP_FACTOR = 10_000;

const build_mode = @import("builtin").mode;

const SAFETY_CHECKS_ENABLE = build_mode == .Debug or build_mode == .ReleaseSafe;
const DEBUG_ENABLE = build_mode == .Debug;

const GROUP_NAME_DEFAULT: []const u8 = "<default>";

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

    var args = Args.from_process_args(alloc) orelse {
        var buf: [1024]u8 = undefined;
        var stdout_writer = std.fs.File.stdout().writer(&buf);
        const stdout = &stdout_writer.interface;
        try stdout.writeAll(@embedFile("./help.txt"));
        std.process.exit(0);
    };

    const socket = try I3.connect(alloc);
    defer socket.close();
    var socket_buf: [512]u8 = undefined;
    var socket_writer_impl = socket.writer(&socket_buf);
    const socket_writer = &socket_writer_impl.interface;
    var socket_buf_2: [512]u8 = undefined;
    var socket_reader_impl = socket.reader(&socket_buf_2);
    const socket_reader = socket_reader_impl.interface();

    const i3_workspaces = try I3.get_workspaces(socket_writer, socket_reader, alloc);

    var state = try alloc.create(State);
    try state.init_in_place_with_workspace_init(I3.Workspace, alloc, i3_workspaces, Workspace.init_in_place_from_i3);
    try do_cmd(state, &args, alloc);
    try exec_i3_commands(socket_writer, socket_reader, alloc, state.commands[0..state.commands_count]);
}

const Args = struct {
    cmd: Cli_Command,
    positionals: []const []const u8,
    positional_index: u32,

    fn from_process_args(alloc: Allocator) ?Args {
        var args_iter = try std.process.argsWithAllocator(alloc);
        debug.assert(args_iter.skip());
        return from_iter(alloc, &args_iter);
    }

    fn from_cmd_str(alloc: Allocator, args: []const u8) ?Args {
        var iter = mem.tokenizeScalar(u8, args, ' ');
        return from_iter(alloc, &iter);
    }

    fn from_iter(alloc: Allocator, args_iter: anytype) ?Args {
        const cmd_str = args_iter.next() orelse return null;
        const cmd = Cli_Command.Map.get(cmd_str) orelse return null;
        var positionals: ArrayList([]const u8) = .empty;
        while (args_iter.next()) |positional| {
            positionals.append(alloc, positional) catch return null;
        }

        return .{
            .cmd = cmd,
            .positionals = positionals.items,
            .positional_index = 0,
        };
    }

    fn next(this: *Args) ?[]const u8 {
        if (this.positional_index >= this.positionals.len) {
            return null;
        }
        this.positional_index += 1;
        return this.positionals[this.positional_index - 1];
    }
};

const State = struct {
    workspace_store: [WORKSPACE_COUNT_MAX]Workspace,
    workspace_count: u32,
    workspaces: []*const Workspace,
    groups: GroupMap,
    focused: ?*const Workspace,
    commands: [COMMAND_COUNT_MAX]Cmd,
    commands_count: u32,

    const GroupMap = std.StringArrayHashMapUnmanaged(u32);

    const WORKSPACE_COUNT_MAX: usize = 512;
    const COMMAND_COUNT_MAX: usize = 512;

    const zero = State{
        .workspace_store = undefined,
        .workspace_count = 0,
        .workspaces = &.{},
        .groups = undefined,
        .focused = null,
        .commands = undefined,
        .commands_count = 0,
    };

    const Cmd = union(enum) {
        rename: struct {
            source: *const Workspace,
            target: *const Workspace,
        },
        set_focused: *const Workspace,
        move_container_to_workspace: *const Workspace,
    };

    fn init_in_place_with_workspace_init(state: *State, comptime Item: type, alloc: Allocator, items: []const Item, init_workspace: *const fn (*Workspace, Item) bool) !void {
        state.* = .zero;
        state.groups = try .init(alloc, &.{}, &.{});
        try state.groups.ensureTotalCapacity(alloc, items.len);
        state.workspaces = try alloc.alloc((*const Workspace), items.len);
        state.workspace_count = @intCast(items.len);

        var active_workspace_group: ?[]const u8 = null;
        for (items, 0..) |item, index| {
            const workspace = &state.workspace_store[index];
            const focused = init_workspace(workspace, item);
            const group_entry = state.groups.getOrPutAssumeCapacity(workspace.group_name);
            if (group_entry.found_existing) {
                workspace.group_name = group_entry.key_ptr.*;
                debug.assert(group_entry.value_ptr.* == group_index_global(workspace.num));
            } else {
                group_entry.value_ptr.* = group_index_global(workspace.num);
                if (group_entry.value_ptr.* == 0) {
                    active_workspace_group = group_entry.key_ptr.*;
                }
            }
            state.workspaces[index] = workspace;
            if (focused) {
                state.focused = workspace;
            }
        }

        if (SAFETY_CHECKS_ENABLE) {
            check_active_group_consistency(state.workspaces, active_workspace_group);
        }
    }

    fn push_cmd(state: *State, cmd: Cmd) *Cmd {
        state.commands[state.commands_count] = cmd;
        state.commands_count += 1;
        return &state.commands[state.commands_count - 1];
    }

    fn rename_workspace(state: *State, workspace: *const Workspace, workspace_index: ?usize) *Workspace {
        const index = workspace_index orelse mem.indexOfScalar(*const Workspace, state.workspaces, workspace) orelse unreachable;
        const new_workspace = state.replace_workspace_at(workspace, index);
        _ = state.push_cmd(.{
            .rename = .{
                .source = workspace,
                .target = new_workspace,
            },
        });
        return new_workspace;
    }

    fn switch_to_workspace(state: *State, workspace: *const Workspace) void {
        _ = state.push_cmd(.{ .set_focused = workspace });
    }

    fn move_container_to_workspace(state: *State, workspace: *const Workspace) void {
        _ = state.push_cmd(.{ .move_container_to_workspace = workspace });
    }

    fn replace_workspace_at(state: *State, workspace: *const Workspace, index: usize) *Workspace {
        state.workspace_store[state.workspace_count] = workspace.*;
        state.workspace_store[state.workspace_count].i3 = null;
        state.workspace_count += 1;
        const result = &state.workspace_store[state.workspace_count - 1];
        state.workspaces[index] = result;
        return result;
    }

    fn find_or_create_workspace(state: *State, alloc: Allocator, group_name: []const u8, name: []const u8, num: u32) !*const Workspace {
        for (state.workspaces) |workspace| {
            const group_eql = mem.eql(u8, workspace.group_name, group_name);
            const name_eql = mem.eql(u8, workspace.name, name);
            const num_eql = workspace.num == num;
            if (group_eql and name_eql and num_eql) {
                return workspace;
            }
        }

        return create_workspace(state, alloc, group_name, name, num);
    }

    fn create_workspace(state: *State, alloc: Allocator, group_name: []const u8, name: []const u8, num: u32) !*Workspace {
        state.workspace_store[state.workspace_count] = .{
            .name = name,
            .group_name = group_name,
            .num = num,
            .i3 = null,
            .output = "",
        };
        const new_workspace = &state.workspace_store[state.workspace_count];
        state.workspace_count += 1;
        if (!alloc.resize(state.workspaces, state.workspaces.len + 1)) {
            const workspaces = try alloc.alloc(*const Workspace, state.workspaces.len + 1);
            @memcpy(workspaces[0..state.workspaces.len], state.workspaces);
            workspaces[state.workspaces.len] = new_workspace;
            state.workspaces = workspaces;
        }
        return new_workspace;
    }
};

const Workspace = struct {
    name: []const u8,
    group_name: []const u8,
    num: u32,
    i3: ?struct {
        id: i64,
        name: []const u8,
    },
    output: []const u8,

    const zero = Workspace{
        .name = "",
        .group_name = "",
        .num = 0,
        .i3 = null,
        .output = "",
    };

    fn init_in_place_from_i3(this: *Workspace, i3_workspace: I3.Workspace) bool {
        this.init_in_place_from_name(i3_workspace.name);
        this.i3 = .{
            .id = i3_workspace.id,
            .name = i3_workspace.name,
        };
        this.output = i3_workspace.output;
        this.num = i3_workspace.num;
        return i3_workspace.focused;
    }

    fn init_in_place_from_name(this: *Workspace, name: []const u8) void {
        this.* = .zero;
        const info = parse_workspace_name(name);
        this.group_name = info.group_name;
        this.name = info.name;
        // FIXME: How to handle?
        this.num = info.num orelse 0;
    }

    pub fn sort_by_output_less_than(_: void, a: *const Workspace, b: *const Workspace) bool {
        return mem.lessThan(u8, a.output, b.output);
    }

    pub fn sort_by_name_less_than(_: void, a: *const Workspace, b: *const Workspace) bool {
        return mem.lessThan(u8, a.name, b.name);
    }

    pub fn sort_by_group_index_and_name_less_than(_: void, a: *const Workspace, b: *const Workspace) bool {
        const a_group = group_index_global(a.num);
        const b_group = group_index_global(b.num);
        if (a_group != b_group) {
            return a_group < b_group;
        }

        return mem.lessThan(u8, a.name, b.name);
    }
};

fn do_cmd(state: *State, args: *Args, alloc: Allocator) !void {
    switch (args.cmd) {
        .Switch_Active_Workspace_Group => {
            const workspaces = state.workspaces;
            // TODO: ensure default group is always shown?
            // TODO: if new_workspace_group_name already exists, don't rename all workspaces
            // TODO: allow entering `group_name:workspace_name` to create new workspace with non number workspace name

            // ?TODO: consider if focused workspace is also in active workspace group, using it's number
            // TODO: if switching to exisiting group, and not doing current ws number, switch to lowest number in that group
            const user_group_name = args.next() orelse blk: {
                const group_names = try alloc.dupe([]const u8, state.groups.keys());
                sort_alphabetically(group_names);
                const choice = try Rofi.select_or_new(alloc, "Switch Active Workspace Group", group_names) orelse return error.Aborted;
                const new_workspace_group_name = switch (choice) {
                    .new => |name| name,
                    .existing => |index| group_names[index],
                };
                break :blk new_workspace_group_name;
            };
            const new_workspace_group_name, const is_new = if (state.groups.getEntry(user_group_name)) |entry|
                .{ entry.key_ptr.*, false }
            else
                .{ user_group_name, true };
            const new_workspace_num = 1;

            renaming: {
                mem.sort(*const Workspace, workspaces, {}, Workspace.sort_by_group_index_and_name_less_than);

                var lowest_unused_group_index: u32 = 1;
                for (workspaces) |workspace| {
                    const global_group_index = group_index_global(workspace.num);
                    if (lowest_unused_group_index == global_group_index) {
                        lowest_unused_group_index = global_group_index + 1;
                    }
                }
                const active_group = if (workspaces.len > 0 and is_in_active_group(workspaces[0]))
                    workspaces[0].group_name
                else
                    "";
                if (SAFETY_CHECKS_ENABLE) {
                    check_active_group_consistency(workspaces, if (active_group.len > 0) active_group else null);
                }

                if (active_group.len > 0 and mem.eql(u8, active_group, new_workspace_group_name)) {
                    break :renaming;
                }

                var idx: usize = workspaces.len;
                while (idx > 0) : (idx -= 1) {
                    const index = idx - 1;
                    const workspace = workspaces[index];

                    const group_index = group_index_global(workspace.num);
                    const is_group_new_active = !is_new and workspace.group_name.ptr == new_workspace_group_name.ptr;
                    const group_index_new = if (is_group_new_active)
                        0
                    else if (group_index < lowest_unused_group_index)
                        group_index + 1
                    else
                        group_index;

                    if (group_index_new == group_index) continue;

                    const new_combined_num = (group_index_new * INACTIVE_WORKSPACE_GROUP_FACTOR) + group_index_local(workspace.num);
                    // PERF: workspace index here
                    const new_workspace = state.rename_workspace(workspace, null);
                    new_workspace.num = new_combined_num;
                }
            }

            const new_workspace_name = try std.fmt.allocPrint(alloc, "{d}", .{new_workspace_num});
            // PERF: if we already know it's new, just create workspace
            const new_workspace = try state.find_or_create_workspace(alloc, new_workspace_group_name, new_workspace_name, new_workspace_num);
            state.switch_to_workspace(new_workspace);
        },
        .Assign_Workspace_To_Group => {
            const workspaces = state.workspaces;
            const active_workspace = state.focused orelse return error.NoFocusedWorkspace;

            const user_group_name = args.next() orelse blk: {
                const group_names = try alloc.dupe([]const u8, state.groups.keys());
                sort_alphabetically(group_names);
                const choice = try Rofi.select_or_new(alloc, "Workspace Group", group_names) orelse return;
                break :blk switch (choice) {
                    .new => |group_name| group_name,
                    .existing => |group_name_idx| group_names[group_name_idx],
                };
            };

            const group_name = (try state.groups.getOrPut(alloc, user_group_name)).key_ptr.*;

            var group_logical_num_max: u32 = 0;
            const group_logical_num = blk: for (workspaces) |workspace| {
                const global_num = group_index_global(workspace.num);
                group_logical_num_max = @max(group_logical_num_max, global_num);
                if (workspace.group_name.ptr == group_name.ptr) {
                    break :blk global_num;
                }
            } else group_logical_num_max + 1;

            const workspace_with_num_exists = blk: for (workspaces) |workspace| {
                if (workspace.group_name.ptr == group_name.ptr and group_index_local(active_workspace.num) == group_index_local(workspace.num)) {
                    break :blk true;
                }
            } else false;

            if (workspace_with_num_exists) {
                return error.TODO_Copying_Over_Containers;
            }

            const active_workspace_num = (group_logical_num * INACTIVE_WORKSPACE_GROUP_FACTOR) + group_index_local(active_workspace.num);

            // PERF: workspace index
            const new_workspace = state.rename_workspace(active_workspace, null);
            new_workspace.group_name = group_name;
            new_workspace.num = active_workspace_num;
        },
        .Rename_Workspace => {
            return error.NotImplemented;
        },
        .Focus_Workspace => {
            const workspaces = state.workspaces;

            // TODO: is no active workspace group actually an error here?
            // FIXME: how to handle no active group and no group name...
            const active_workspace_group = get_active_workspace_group(state) orelse return error.NoActiveGroup;

            const name_info = if (args.next()) |arg| blk: {
                var name_info = parse_workspace_name(arg);
                if (name_info.group_name.len == 0 or name_info.group_name.ptr == GROUP_NAME_DEFAULT.ptr) {
                    name_info.group_name = active_workspace_group;
                }
                const global_group_index = state.groups.get(name_info.group_name) orelse mem.max(u32, state.groups.values());
                const local_group_index = if (name_info.num) |num|
                    group_index_local(num)
                else if (group_index_local_max(state, name_info.group_name)) |num|
                    num + 1
                else
                    1;

                name_info.num = global_group_index * INACTIVE_WORKSPACE_GROUP_FACTOR + local_group_index;

                break :blk name_info;
            } else blk: {
                mem.sort(*const Workspace, workspaces, {}, Workspace.sort_by_group_index_and_name_less_than);
                var group_name_len_max: u64 = 0;
                var name_len_max: u64 = 0;

                for (workspaces) |workspace| {
                    group_name_len_max = @max(group_name_len_max, workspace.group_name.len);
                    name_len_max = @max(name_len_max, workspace.name.len);
                }

                var selection = try Rofi.select_writer(alloc, "Workspace");
                // TODO: Pango markup help text here
                var writer = selection.writer;

                for (workspaces) |workspace| {
                    _ = try writer.splatByte(' ', group_name_len_max -| workspace.group_name.len);
                    try writer.writeAll(workspace.group_name);
                    try writer.writeByte(':');
                    try writer.writeAll(workspace.name);
                    try writer.writeByte('\n');
                }
                try writer.flush();
                const choice = (try selection.finish()) orelse return;
                break :blk parse_workspace_name(choice);
            };
            // TODO:
            // - identify whether chosen workspace already exists (and is active workspace group)
            // - if it exists identify he name and switch to it
            // - else create number for it and format name before switching to it

            const workspace_to_switch_to = try state.find_or_create_workspace(alloc, name_info.group_name, name_info.name, name_info.num.?);

            state.switch_to_workspace(workspace_to_switch_to);
        },
        .Move_Active_Container_To_Workspace => {
            const workspaces = state.workspaces;

            const workspace_user_name = args.next() orelse blk: {
                var active_group_workspaces = std.ArrayListUnmanaged(*const Workspace).fromOwnedSlice(try alloc.dupe(*const Workspace, state.workspaces));
                var group_name_len_max: u64 = 0;
                var i: u32 = 0;
                while (i < active_group_workspaces.items.len) {
                    const workspace = active_group_workspaces.items[i];
                    if (is_in_active_group(workspace)) {
                        group_name_len_max = @max(workspace.group_name.len, group_name_len_max);
                        i += 1;
                    } else {
                        _ = active_group_workspaces.swapRemove(i);
                    }
                }
                mem.sort(*const Workspace, active_group_workspaces.items, {}, Workspace.sort_by_name_less_than);

                var selection = try Rofi.select_or_new_writer(alloc, "Workspace");
                // TODO: Pango markup help text here
                var writer = selection.writer;

                for (active_group_workspaces.items) |workspace| {
                    _ = try writer.splatByte(' ', group_name_len_max -| workspace.group_name.len);
                    try writer.writeAll(workspace.group_name);
                    try writer.writeByte(':');
                    try writer.writeAll(workspace.name);
                    try writer.writeByte('\n');
                }
                try writer.flush();
                const choice = try selection.finish() orelse return;
                debug.print("selection: {s}\n", .{choice});
                break :blk choice;
            };

            const active_workspace_group = get_active_workspace_group(state);

            var workspace_name = workspace_user_name;
            var workspace_group_name = active_workspace_group orelse GROUP_NAME_DEFAULT;
            var workspace_logical_group_index: u32 = 0;
            var workspace_num = blk: for (workspaces) |workspace| {
                if (workspace == state.focused) {
                    break :blk workspace.num % INACTIVE_WORKSPACE_GROUP_FACTOR;
                }
            } else 1;

            if (mem.indexOfScalar(u8, workspace_user_name, ':')) |colon_pos| {
                workspace_name = workspace_user_name[colon_pos + 1 ..];
                workspace_group_name = workspace_user_name[0..colon_pos];
                const is_new_group = blk: for (workspaces) |workspace| {
                    if (mem.eql(u8, workspace_group_name, workspace.group_name)) {
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

            if (parse_workspace_name(workspace_name).num) |num| {
                workspace_num = num;
            }

            for (workspaces) |workspace| {
                if (mem.eql(u8, workspace.group_name, workspace_group_name)) {
                    workspace_logical_group_index = @divTrunc(workspace.num, INACTIVE_WORKSPACE_GROUP_FACTOR);
                    break;
                }
            }
            if (workspace_logical_group_index > 0) {
                workspace_num += (INACTIVE_WORKSPACE_GROUP_FACTOR * workspace_logical_group_index);
            }

            const workspace_to_move_to = try state.find_or_create_workspace(alloc, workspace_group_name, workspace_name, workspace_num);
            state.move_container_to_workspace(workspace_to_move_to);
        },
        .Pretty_List_Workspaces => {
            try pretty_list_workspaces(alloc, state);
        },
    }
}

// PERF: batch calls
fn exec_i3_commands(writer: *Io.Writer, reader: *Io.Reader, alloc: Allocator, commands: []State.Cmd) !void {
    for (commands) |command| {
        switch (command) {
            .move_container_to_workspace => |workspace| {
                try I3.move_active_container_to_workspace(writer, "{f}", fmt_workspace_name(workspace));
            },
            .rename => |data| {
                try I3.rename_workspace(writer, "{f}", fmt_workspace_name(data.source), "{f}", fmt_workspace_name(data.target));
            },
            .set_focused => |workspace| {
                try I3.switch_to_workspace(writer, "{f}", fmt_workspace_name(workspace));
            },
        }
        try writer.flush();
        if (!@import("builtin").is_test) {
            try I3.read_reply_expect_single_success_true(reader, alloc, .COMMAND);
        }
    }
}

fn pretty_list_workspaces(alloc: Allocator, state: *const State) !void {
    if (state.workspaces.len == 0) {
        return;
    }
    const workspaces = try alloc.dupe((*const Workspace), state.workspaces);
    mem.sort(*const Workspace, workspaces, {}, Workspace.sort_by_output_less_than);
    var ouput_start_index: u32 = 0;
    var output_end_index: u32 = 1;
    var found_multiple_outputs = false;
    while (output_end_index < workspaces.len) : (output_end_index += 1) {
        const output_a = workspaces[output_end_index - 1].output;
        const output_b = workspaces[output_end_index].output;
        if (!mem.eql(u8, output_a, output_b)) {
            mem.sort(*const Workspace, workspaces[ouput_start_index..output_end_index], {}, Workspace.sort_by_name_less_than);
            ouput_start_index = output_end_index;
            found_multiple_outputs = true;
        }
    }
    mem.sort(*const Workspace, workspaces[ouput_start_index..output_end_index], {}, Workspace.sort_by_name_less_than);

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
        debug.print("{s}[{f}]\n", .{ prefix, fmt_workspace_name(workspace) });
        debug.print("{s}   name: {s}\n", .{ prefix, workspace.name });
        debug.print("{s}  group: {s}\n", .{ prefix, workspace.group_name });
        debug.print("{s}     id: {d}\n", .{ prefix, if (workspace.i3) |i3_data| i3_data.id else 0 });
        debug.print("{s}    num: {d}\n", .{ prefix, workspace.num });
    }
}

fn fmt_workspace_name(workspace: *const Workspace) WorkspaceNameFormat {
    return .{ .workspace = workspace };
}

const WorkspaceNameFormat = struct {
    workspace: *const Workspace,

    pub fn format(this: *const @This(), writer: *Io.Writer) !void {
        if (this.workspace.i3) |i3_data| {
            try writer.writeAll(i3_data.name);
            return;
        }
        try writer.printInt(this.workspace.num, 10, .lower, .{});
        try writer.writeByte(':');
        if (this.workspace.group_name.len > 0 and !mem.eql(u8, this.workspace.group_name, GROUP_NAME_DEFAULT)) {
            try writer.writeAll(this.workspace.group_name);
            try writer.writeByte(':');
        }
        try writer.writeAll(this.workspace.name);
    }
};

fn sort_alphabetically(strings: [][]const u8) void {
    const cmp = struct {
        fn less_than(_: void, a: []const u8, b: []const u8) bool {
            return mem.lessThan(u8, a, b);
        }
    };

    mem.sort([]const u8, strings, {}, cmp.less_than);
}

fn get_active_workspace_group(state: *const State) ?[]const u8 {
    var iter = state.groups.iterator();
    while (iter.next()) |entry| {
        if (entry.value_ptr.* == 0) {
            return entry.key_ptr.*;
        }
    }
    return null;
}

fn check_active_group_consistency(workspaces: []*const Workspace, _active_workspace_group: ?[]const u8) void {
    var active_workspace_group = _active_workspace_group;
    for (workspaces) |workspace| {
        if (is_in_active_group(workspace)) {
            if (active_workspace_group) |group| {
                debug.assert(mem.eql(u8, workspace.group_name, group));
            } else {
                active_workspace_group = workspace.group_name;
            }
        }
    }
}

fn group_index_local_max(state: *const State, group_name: []const u8) ?u32 {
    const global_num = state.groups.get(group_name) orelse return null;
    var max: ?u32 = null;
    for (state.workspaces) |workspace| {
        if (group_index_global(workspace.num) != global_num) continue;
        max = @max(max orelse 0, group_index_local(workspace.num));
    }
    return max;
}

/// Calculates the global (relative to other groups) index of the workspace number
fn group_index_global(workspace_num: u32) u32 {
    return @divTrunc(workspace_num, INACTIVE_WORKSPACE_GROUP_FACTOR);
}

/// Calculates the local (relative to other workspaces in the same group) index of the workspace number
fn group_index_local(workspace_num: u32) u32 {
    return workspace_num % INACTIVE_WORKSPACE_GROUP_FACTOR;
}

fn is_in_active_group(workspace: *const Workspace) bool {
    // return group_global_index(workspace) == 0
    return workspace.num < INACTIVE_WORKSPACE_GROUP_FACTOR;
}

const NameInfo = struct { num: ?u32, group_name: []const u8, name: []const u8 };

fn try_parse_num(possible_num: []const u8) ?u32 {
    return std.fmt.parseInt(u32, mem.trim(u8, possible_num, &std.ascii.whitespace), 10) catch null;
}

fn parse_workspace_name(name: []const u8) NameInfo {
    var info: NameInfo = .{ .num = null, .group_name = "", .name = "" };
    const count_colons = blk: {
        var count: u32 = 0;
        for (name) |c| {
            count += @intFromBool(c == ':');
        }
        break :blk count;
    };
    switch (count_colons) {
        0 => {
            info.group_name = GROUP_NAME_DEFAULT;
            info.name = name;
            info.num = try_parse_num(name);
        },
        1 => {
            const part = mem.lastIndexOfScalar(u8, name, ':').?;
            info.name = name[part + 1 ..];
            if (try_parse_num(name[0..part])) |num| {
                info.num = num;
                info.group_name = GROUP_NAME_DEFAULT;
            } else {
                info.num = try_parse_num(name[part + 1 ..]);
                info.group_name = name[0..part];
            }
        },
        else => {
            const part_a = mem.indexOfScalar(u8, name, ':').?;
            const part_b = mem.indexOfScalarPos(u8, name, part_a + 1, ':').?;
            info.num = try_parse_num(name[0..part_a]);
            info.group_name = name[part_a + 1 .. part_b];
            info.name = name[part_b + 1 ..];
        },
    }
    info.name = mem.trim(u8, info.name, &std.ascii.whitespace);
    info.group_name = mem.trim(u8, info.group_name, &std.ascii.whitespace);
    return info;
}

fn count_digits(num: anytype) usize {
    if (num == 0) return 1;
    const val: u128 = if (num < 0) @intCast(-num) else num;
    return std.math.log10_int(val) + 1;
}

fn init_workspace_from_test_name(workspace: *Workspace, test_name: []const u8) bool {
    var focused = false;
    var name = test_name;
    if (mem.endsWith(u8, name, "<-")) {
        focused = true;
        name = name[0 .. name.len - 2];
    }
    Workspace.init_in_place_from_name(workspace, name);
    workspace.i3 = .{
        .id = @bitCast(@intFromPtr(workspace)),
        .name = name,
    };
    return focused;
}

// TODO: make expected commands be []const u8 with cmd per line,
// and do single expectEqualStrings call
fn check_do_cmd(
    workspace_names: []const []const u8,
    args_str: []const u8,
    expected_commands: []const []const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var state: State = undefined;
    try state.init_in_place_with_workspace_init([]const u8, alloc, workspace_names, init_workspace_from_test_name);
    var args = Args.from_cmd_str(alloc, args_str).?;
    try do_cmd(&state, &args, alloc);

    var cmd_stream: Io.Writer.Allocating = .init(alloc);

    try exec_i3_commands(&cmd_stream.writer, @constCast(&std.Io.Reader.failing), alloc, state.commands[0..state.commands_count]);

    var commands: std.ArrayList([]const u8) = .empty;
    var cmd_stream_out: Io.Reader = Io.Reader.fixed(cmd_stream.written());
    while (cmd_stream_out.peekByte() != error.EndOfStream) {
        const msg_length = try I3.read_msg_header(&cmd_stream_out);
        _ = try I3.read_msg_kind(I3.Command, &cmd_stream_out);
        const msg = try cmd_stream_out.readAlloc(alloc, msg_length);
        try std.testing.expectEqual(msg_length, msg.len);
        try commands.append(alloc, msg);
    }

    if (expected_commands.len != commands.items.len) {
        const print = debug.print;
        print("Command Count Mismatch:\n\nExpected commands:\n", .{});
        for (expected_commands) |expected| {
            print("  {s}\n", .{expected});
        }
        print("\nActual commands:\n", .{});
        for (commands.items) |actual| {
            print("  {s}\n", .{actual});
        }
        return error.UnexpectedCommands;
    }

    for (expected_commands, commands.items) |expected, actual| {
        try std.testing.expectEqualStrings(expected, actual);
    }
}

const refAllDecls = std.testing.refAllDeclsRecursive;
test refAllDecls {
    refAllDecls(@This());
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

test parse_workspace_name {
    const cases: []const struct { []const u8, NameInfo } = &.{
        .{ "2:2", .{ .name = "2", .num = 2, .group_name = GROUP_NAME_DEFAULT } },
        .{ "10002:foo:3", .{ .name = "3", .num = 10002, .group_name = "foo" } },
        .{ "foo:bar", .{ .name = "bar", .num = null, .group_name = "foo" } },
        .{ "foo:1", .{ .name = "1", .num = 1, .group_name = "foo" } },
    };

    for (cases) |case| {
        const name, const expected = case;
        const actual = parse_workspace_name(name);
        std.testing.expectEqualStrings(expected.group_name, actual.group_name) catch |err| {
            debug.print("Group name incorrect for workspace {s}\n", .{name});
            return err;
        };
        std.testing.expectEqualStrings(expected.name, actual.name) catch |err| {
            debug.print("Workspace name incorrect for workspace {s}\n", .{name});
            return err;
        };
        std.testing.expectEqual(expected.num, actual.num) catch |err| {
            debug.print("Num incorrect for workspace {s}\n", .{name});
            return err;
        };
    }
}

test "cmd" {
    // if (@as(?anyerror, error.SkipZigTest)) |err| {
    //     return err;
    // }
    const @"focus-workspace" = struct {
        test "basic" {
            try check_do_cmd(
                &.{
                    "1:1<-",
                    "2:2",
                },
                "focus-workspace 2",
                &.{"workspace 2:2"},
            );
        }

        test "multi-group" {
            try check_do_cmd(
                &.{
                    "1:active:1",
                    "2:active:2",
                    "3:active:3<-",
                    "10001:inactive:1",
                    "10002:inactive:2",
                },
                "focus-workspace 1",
                &.{"workspace 1:active:1"},
            );
        }

        test "multi-group-from-inactive-group" {
            try check_do_cmd(
                &.{
                    "1:active:1",
                    "2:active:2",
                    "3:active:3",
                    "10001:inactive:1",
                    "10002:inactive:2<-",
                },
                "focus-workspace 1",
                &.{"workspace 1:active:1"},
            );
        }

        test "default-i3-names" {
            try check_do_cmd(
                &.{
                    "1",
                    "2",
                    "3<-",
                },
                "focus-workspace 1",
                &.{"workspace 1"},
            );
        }
    };
    const @"switch-active-workspace-group" = struct {
        test "basic" {
            try check_do_cmd(
                &.{
                    "1:1<-",
                    "10001:other:1",
                },
                "switch-active-workspace-group other",
                &.{
                    "rename workspace 10001:other:1 to 1:other:1",
                    "rename workspace 1:1 to 10001:1",
                    "workspace 1:other:1",
                },
            );
        }

        test "from-named-group-to-other-group" {
            try check_do_cmd(
                &.{
                    "1:active:1<-",
                    "10001:inactive:1",
                },
                "switch-active-workspace-group inactive",
                &.{
                    "rename workspace 10001:inactive:1 to 1:inactive:1",
                    "rename workspace 1:active:1 to 10001:active:1",
                    "workspace 1:inactive:1",
                },
            );
        }

        test "new" {
            try check_do_cmd(
                &.{
                    "1<-",
                },
                "switch-active-workspace-group new",
                &.{
                    "rename workspace 1 to 10001:1",
                    "workspace 1:new:1",
                },
            );
        }

        test "new-with-inactives" {
            try check_do_cmd(
                &.{
                    // NOTE: shuffled lines to ensure sort order doesn't matter
                    "20001:bar:3",
                    "30004:baz:4",
                    "1<-",
                    "10001:foo:1",
                    "10002:foo:2",
                },
                "switch-active-workspace-group new",
                &.{
                    "rename workspace 30004:baz:4 to 40004:baz:4",
                    "rename workspace 20001:bar:3 to 30001:bar:3",
                    "rename workspace 10002:foo:2 to 20002:foo:2",
                    "rename workspace 10001:foo:1 to 20001:foo:1",
                    "rename workspace 1 to 10001:1",
                    "workspace 1:new:1",
                },
            );
        }

        test "new-with-hole-in-group-indices" {
            try check_do_cmd(
                &.{
                    "1:foo:1<-",
                    "20001:bar:1",
                },
                "switch-active-workspace-group new",
                &.{
                    "rename workspace 1:foo:1 to 10001:foo:1",
                    // NOTE: no rename of 20001:bar:1
                    "workspace 1:new:1",
                },
            );
        }
    };

    const @"move-active-container-to-workspace" = struct {
        test "basic" {
            try check_do_cmd(
                &.{
                    // NOTE: shuffled lines to ensure sort order doesn't matter
                    "1<-",
                    "2",
                },
                "move-active-container-to-workspace 2",
                &.{
                    "move container to workspace 2",
                },
            );
        }

        test "create" {
            try check_do_cmd(
                &.{
                    // NOTE: shuffled lines to ensure sort order doesn't matter
                    "20001:bar:3",
                    "30004:baz:4<-",
                    "1",
                    "10001:foo:1",
                    "10002:foo:2",
                },
                "move-active-container-to-workspace 2",
                &.{
                    "move container to workspace 2:2",
                },
            );
        }
    };

    const @"assign-workspace-to-group" = struct {
        test "create" {
            try check_do_cmd(
                &.{
                    "1",
                    "2",
                    "10001:foo:1",
                    "10002:foo:2<-",
                },
                "assign-workspace-to-group bar",
                &.{
                    "rename workspace 10002:foo:2 to 20002:bar:2",
                },
            );
        }
    };

    _ = @"focus-workspace";
    _ = @"switch-active-workspace-group";
    _ = @"move-active-container-to-workspace";
    _ = @"assign-workspace-to-group";
}
