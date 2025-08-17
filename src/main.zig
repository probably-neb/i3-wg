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
        // TODO: implement help
        return error.Help_Not_Implemented;
    };

    const socket = try I3.connect(alloc);
    defer socket.close();

    const i3_workspaces = try I3.get_workspaces(socket, alloc);

    var state = try alloc.create(State);
    try state.init_in_place_with_workspace_init(I3.Workspace, alloc, i3_workspaces, Workspace.init_in_place_from_i3);
    try do_cmd(state, &args, alloc);
    try exec_i3_commands(I3, socket, alloc, state.commands[0..state.commands_count]);
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
        var positionals: ArrayList([]const u8) = .init(alloc);
        while (args_iter.next()) |positional| {
            positionals.append(positional) catch return null;
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

    const GroupMap = std.StringArrayHashMapUnmanaged(void);

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

        for (items, 0..) |item, index| {
            const workspace = &state.workspace_store[index];
            const focused = init_workspace(workspace, item);
            const group_entry = state.groups.getOrPutAssumeCapacity(workspace.group_name);
            if (group_entry.found_existing) {
                workspace.group_name = group_entry.key_ptr.*;
            }
            state.workspaces[index] = workspace;
            if (focused) {
                state.focused = workspace;
            }
        }
    }

    fn push_cmd(state: *State, cmd: Cmd) *Cmd {
        state.commands[state.commands_count] = cmd;
        state.commands_count += 1;
        return &state.commands[state.commands_count - 1];
    }

    fn rename_workspace(state: *State, workspace: *const Workspace) *Workspace {
        const new_workspace = state.replace_workspace(workspace);
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

    fn replace_workspace(state: *State, workspace: *const Workspace) *Workspace {
        const index = mem.indexOfScalar(*const Workspace, state.workspaces, workspace) orelse unreachable;
        return state.replace_workspace_at(workspace, @intCast(index));
    }

    fn replace_workspace_at(state: *State, workspace: *const Workspace, index: u32) *Workspace {
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
        const count_colons = blk: {
            var count: u32 = 0;
            for (name) |c| {
                count += @intFromBool(c == ':');
            }
            break :blk count;
        };
        var possible_num = name;
        switch (count_colons) {
            0 => {
                this.group_name = "<default>";
                this.name = name;
                possible_num = name;
            },
            1 => {
                const part = mem.lastIndexOfScalar(u8, name, ':').?;
                this.group_name = GROUP_NAME_DEFAULT;
                this.name = name[part + 1 ..];
                possible_num = name[part + 1 ..];
            },
            else => {
                const part_a = mem.indexOfScalar(u8, name, ':').?;
                const part_b = mem.indexOfScalarPos(u8, name, part_a + 1, ':').?;
                possible_num = name[0..part_a];
                this.group_name = name[part_a + 1 .. part_b];
                this.name = name[part_b + 1 ..];
            },
        }
        if (std.fmt.parseInt(u32, possible_num, 10) catch null) |num| {
            this.num = num;
        }
    }

    pub fn sort_by_output_less_than(_: void, a: *const Workspace, b: *const Workspace) bool {
        return mem.lessThan(u8, a.output, b.output);
    }

    pub fn sort_by_name_less_than(_: void, a: *const Workspace, b: *const Workspace) bool {
        return mem.lessThan(u8, a.name, b.name);
    }

    pub fn sort_by_group_name_less_than(_: void, a: *const Workspace, b: *const Workspace) bool {
        // TODO: consider caching group_names
        return mem.lessThan(u8, a.get_group_name(), b.get_group_name());
    }

    // PERF: rewrite
    pub fn sort_by_logical_num_and_name_less_than(_: void, a: *const Workspace, b: *const Workspace) bool {
        const a_logical = @divTrunc(a.num, INACTIVE_WORKSPACE_GROUP_FACTOR);
        const b_logical = @divTrunc(b.num, INACTIVE_WORKSPACE_GROUP_FACTOR);
        if (a_logical != b_logical) {
            return a_logical < b_logical;
        }

        return mem.lessThan(u8, a.name, b.name);
    }
};

fn do_cmd(state: *State, args: *Args, alloc: Allocator) !void {
    switch (args.cmd) {
        .Switch_Active_Workspace_Group => {
            const workspaces = state.workspaces;
            const group_names = try alloc.dupe([]const u8, state.groups.keys());
            sort_alphabetically(group_names);
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

                    const group_name = workspace.group_name;
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

                mem.sort(*const Workspace, workspaces, {}, Workspace.sort_by_logical_num_and_name_less_than);

                // TODO: determine if iterations + retries are still necessary with reverse
                var idx: usize = workspaces.len;
                while (idx > 0) : (idx -= 1) {
                    const index = idx - 1;
                    const workspace = workspaces[index];
                    if (completed.isSet(index)) continue;

                    const num_actual = workspace.num % INACTIVE_WORKSPACE_GROUP_FACTOR;
                    const num_logical_orig = @divTrunc(workspace.num, INACTIVE_WORKSPACE_GROUP_FACTOR);
                    const is_group_new_active = !is_new and mem.eql(u8, workspace.group_name, new_workspace_group_name);
                    const num_logical_new = if (is_group_new_active) 0 else new_logical_group_index_map[num_logical_orig];
                    debug.print(
                        "workspace {s} name='{s}' with logical group {d} and actual {d} becomes logical group {d} and actual {d}\n",
                        .{
                            workspace.i3.?.name,
                            workspace.name,
                            num_logical_orig,
                            num_actual,
                            num_logical_new,
                            num_actual,
                        },
                    );

                    const new_combined_num = (num_logical_new * INACTIVE_WORKSPACE_GROUP_FACTOR) + num_actual;
                    // TODO: check if workspace rename is even necessary
                    const new_workspace = state.rename_workspace(workspace);
                    new_workspace.num = new_combined_num;
                }
            }

            var buf: std.ArrayList(u8) = .init(alloc);
            try std.fmt.formatInt(new_workspace_num, 10, .lower, .{}, buf.writer());
            const new_workspace_name = buf.items;
            // TODO: if we already know it's new, just create workspace
            const new_workspace = try state.find_or_create_workspace(alloc, new_workspace_group_name, new_workspace_name, new_workspace_num);
            state.switch_to_workspace(new_workspace);
        },
        .Assign_Workspace_To_Group => {
            const workspaces = state.workspaces;
            const active_workspace = state.focused orelse return error.NoFocusedWorkspace;

            const group_name = if (args.next()) |_| return error.TODO_Taking_Name_To_Move_To else blk: {
                const group_names = try alloc.dupe([]const u8, state.groups.keys());
                sort_alphabetically(group_names);
                const choice = try Rofi.select_or_new(alloc, "Workspace Group", group_names) orelse return;
                switch (choice) {
                    .new => |_| return error.TODO_Allow_New_Group,
                    .existing => |group_name_idx| break :blk group_names[group_name_idx],
                }
            };

            const group_logical_num = blk: for (workspaces) |workspace| {
                if (mem.eql(u8, workspace.group_name, group_name)) {
                    break :blk @divTrunc(workspace.num, INACTIVE_WORKSPACE_GROUP_FACTOR);
                }
            } else unreachable;

            const active_workspace_actual_num = active_workspace.num % INACTIVE_WORKSPACE_GROUP_FACTOR;

            const workspace_with_num_exists = blk: for (workspaces) |workspace| {
                const workspace_actual_num = workspace.num % INACTIVE_WORKSPACE_GROUP_FACTOR;
                const is_actual_num_same = workspace_actual_num == active_workspace_actual_num;
                const is_group_name_same = std.mem.eql(u8, workspace.group_name, group_name);
                if (is_actual_num_same and is_group_name_same) {
                    break :blk true;
                }
            } else false;

            if (workspace_with_num_exists) {
                return error.TODO_Copying_Over_Containers;
            }

            const active_workspace_num = (group_logical_num * INACTIVE_WORKSPACE_GROUP_FACTOR) + active_workspace_actual_num;

            const new_workspace = state.rename_workspace(active_workspace);
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
            const active_workspace_group = get_active_workspace_group(workspaces) orelse return error.NoActiveGroup;

            const name = if (args.next()) |arg| arg else blk: {
                mem.sort(*const Workspace, workspaces, {}, Workspace.sort_by_logical_num_and_name_less_than);
                var group_name_len_max: u64 = 0;
                var name_len_max: u64 = 0;

                for (workspaces) |workspace| {
                    group_name_len_max = @max(group_name_len_max, workspace.group_name.len);
                    name_len_max = @max(name_len_max, workspace.name.len);
                }

                var selection = try Rofi.select_or_new_writer(alloc, "Workspace");
                // TODO: Pango markup help text here

                for (workspaces) |workspace| {
                    try selection.writer.writeByteNTimes(' ', group_name_len_max -| workspace.group_name.len);
                    try selection.writer.writeAll(workspace.group_name);
                    try selection.writer.writeByteNTimes(' ', name_len_max -| workspace.name.len + 2);
                    try selection.writer.writeAll(workspace.name);
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
            // TODO:
            // - identify whether chosen workspace already exists (and is active workspace group)
            // - if it exists identify he name and switch to it
            // - else create number for it and format name before switching to it

            const workspace_to_switch_to = blk: {
                // TODO: clone this logic (extract to fn?) to move container to workspace
                const maybe_num = std.fmt.parseInt(u32, name, 10) catch null;

                const group_num_max = gnm: {
                    var group_num_max: u32 = 0;
                    for (workspaces) |workspace| {
                        if (is_in_active_group(workspace)) {
                            group_num_max = @max(group_num_max, workspace.num);
                        }
                    }
                    break :gnm group_num_max;
                };

                if (maybe_num) |num| {
                    if (num < INACTIVE_WORKSPACE_GROUP_FACTOR) {
                        for (workspaces) |workspace| {
                            if (is_in_active_group(workspace) and num == workspace.num) {
                                break :blk workspace;
                            }
                        } else {
                            const workspace_num = if (num < 10) num else group_num_max + 1;
                            break :blk try state.find_or_create_workspace(alloc, active_workspace_group, name, workspace_num);
                        }
                    }
                } else {
                    // otherwise look for a workspace named $name and if we find it return it so we get the workspace number correct
                    for (workspaces) |workspace| {
                        if (is_in_active_group(workspace) and mem.eql(u8, workspace.name, name)) {
                            break :blk workspace;
                        }
                    }
                }

                break :blk try state.find_or_create_workspace(alloc, active_workspace_group, name, group_num_max + 1);
            };

            state.switch_to_workspace(workspace_to_switch_to);
        },
        .Move_Active_Container_To_Workspace => {
            const workspaces = state.workspaces;

            const workspace_user_name = if (args.next()) |arg| arg else blk: {
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

                for (active_group_workspaces.items) |workspace| {
                    try selection.writer.writeByteNTimes(' ', group_name_len_max -| workspace.group_name.len);
                    try selection.writer.writeAll(workspace.group_name);
                    try selection.writer.writeByte(':');
                    try selection.writer.writeAll(workspace.name);
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

            if (parse_workspace_name_num(workspace_name)) |num| {
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

fn exec_i3_commands(I3_Impl: anytype, socket: anytype, alloc: Allocator, commands: []State.Cmd) !void {
    for (commands) |command| {
        switch (command) {
            .move_container_to_workspace => |workspace| {
                const name = try alloc_print_workspace_name_or_i3_name_if_set(alloc, workspace);
                try I3_Impl.move_active_container_to_workspace(socket, alloc, name);
            },
            .rename => |data| {
                const source = try alloc_print_workspace_name_or_i3_name_if_set(alloc, data.source);
                const target = try alloc_print_workspace_name_or_i3_name_if_set(alloc, data.target);
                try I3_Impl.rename_workspace(socket, alloc, source, target);
            },
            .set_focused => |workspace| {
                const name = try alloc_print_workspace_name_or_i3_name_if_set(alloc, workspace);
                try I3_Impl.switch_to_workspace(socket, alloc, name);
            },
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
        debug.print("{s}[{s}]\n", .{ prefix, workspace.name });
        debug.print("{s}  group: {s}\n", .{ prefix, workspace.group_name });
        debug.print("{s}  id: {d}\n", .{ prefix, if (workspace.i3) |i3_data| i3_data.id else 0 });
        debug.print("{s}  num: {d}\n", .{ prefix, workspace.num });
    }
}

fn alloc_print_workspace_name_or_i3_name_if_set(alloc: Allocator, workspace: *const Workspace) ![]const u8 {
    if (workspace.i3) |i3_data| {
        return i3_data.name;
    }
    return alloc_print_workspace_name(alloc, workspace);
}

fn alloc_print_workspace_name(alloc: Allocator, workspace: *const Workspace) ![]const u8 {
    const group_name = workspace.group_name;
    const num = workspace.num;
    const name = workspace.name;
    const buf = try alloc.alloc(u8, workspace_name_parts_len(num, group_name, name));
    var buf_stream = std.io.fixedBufferStream(buf);
    try write_workspace_name_parts(buf_stream.writer(), num, group_name, name);
    return buf;
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

fn sort_alphabetically(strings: [][]const u8) void {
    const cmp = struct {
        fn less_than(_: void, a: []const u8, b: []const u8) bool {
            return mem.lessThan(u8, a, b);
        }
    };

    mem.sort([]const u8, strings, {}, cmp.less_than);
}

fn get_active_workspace_group(workspaces: []*const Workspace) ?[]const u8 {
    var active_workspace_group: ?[]const u8 = null;
    for (workspaces) |workspace| {
        if (is_in_active_group(workspace)) {
            active_workspace_group = workspace.group_name;
            break;
        }
    }
    if (SAFETY_CHECKS_ENABLE) {
        check_active_group_consistency(workspaces, active_workspace_group);
    }

    return active_workspace_group;
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

fn init_workspace_from_test_name(workspace: *Workspace, test_name: []const u8) bool {
    var focused = false;
    var name = test_name;
    if (mem.endsWith(u8, name, "<-")) {
        focused = true;
        name = name[0 .. name.len - 2];
    }
    Workspace.init_in_place_from_name(workspace, name);
    return focused;
}

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

    var cmd_stream = std.ArrayList(u8).init(alloc);

    try exec_i3_commands(I3.Mock, cmd_stream.writer().any(), alloc, state.commands[0..state.commands_count]);

    var commands = std.ArrayList([]const u8).init(alloc);
    var cmd_stream_out = std.io.fixedBufferStream(cmd_stream.items);
    while (try cmd_stream_out.getEndPos() > try cmd_stream_out.getPos()) {
        const msg_length = try I3.read_msg_header(cmd_stream_out.reader());
        _ = try I3.read_msg_kind(I3.Command, cmd_stream_out.reader());
        const msg = try alloc.alloc(u8, msg_length);
        try std.testing.expectEqual(msg_length, try cmd_stream_out.reader().readAtLeast(msg, msg_length));
        try commands.append(msg);
    }

    for (expected_commands, commands.items) |expected, actual| {
        try std.testing.expectEqualStrings(expected, actual);
    }
}

test "basic_change_focus" {
    try check_do_cmd(
        &.{
            "1:1<-",
            "2:2",
        },
        "focus-workspace 2",
        &.{"workspace 2:2"},
    );
}
