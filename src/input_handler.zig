const std = @import("std");
const ztop = @import("ztop");
const render = ztop.render;
const process_commands = ztop.process_commands;
const text_input = ztop.text_input;
const Tui = ztop.tui.Tui;
const SysInfo = ztop.sysinfo.SysInfo;
const posix = std.posix;

pub const Rect = struct {
    x: u16 = 0,
    y: u16 = 0,
    width: u16 = 0,
    height: u16 = 0,

    pub fn contains(self: Rect, x: u16, y: u16) bool {
        return self.width > 0 and self.height > 0 and
            x >= self.x and y >= self.y and
            x - self.x < self.width and
            y - self.y < self.height;
    }
};

pub const TabRegion = struct {
    tab: u8,
    rect: Rect,
};

pub const MouseRegions = struct {
    tabs: [4]TabRegion = undefined,
    tab_count: usize = 0,
    list_rect: Rect = .{},

    pub fn reset(self: *MouseRegions) void {
        self.tab_count = 0;
        self.list_rect = .{};
    }

    pub fn addTab(self: *MouseRegions, tab: u8, rect: Rect) void {
        if (self.tab_count >= self.tabs.len) return;
        self.tabs[self.tab_count] = .{ .tab = tab, .rect = rect };
        self.tab_count += 1;
    }

    pub fn tabAt(self: *const MouseRegions, x: u16, y: u16) ?u8 {
        for (self.tabs[0..self.tab_count]) |tab| {
            if (tab.rect.contains(x, y)) return tab.tab;
        }
        return null;
    }
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    sys_info: *SysInfo,
    app_tui: *Tui,
    cached_procs: []ztop.sysinfo.ProcStats,
    cached_threads: *[]ztop.sysinfo.ThreadStats,
    cached_connections: *[]ztop.sysinfo.common.NetConnection,
    sort_by: *ztop.sysinfo.SortBy,
    selected_idx: *usize,
    scroll_offset: *usize,
    show_help: *bool,
    show_column_picker: *bool,
    filter_buf: *[32]u8,
    filter_len: *usize,
    is_filtering: *bool,
    cmd_buf: *[128]u8,
    cmd_len: *usize,
    is_cmd_mode: *bool,
    filtered_indices: []const usize,
    filtered_count: *usize,
    tree_view: *bool,
    zombie_parents: []process_commands.ZombieParentEntry,
    zombie_summary: *process_commands.ZombieParentSummary,
    show_zombie_parents: *bool,
    thread_view: *bool,
    thread_view_pid: *u32,
    thread_view_name_buf: *[64]u8,
    thread_view_name_len: *u8,
    status_buf: *[160]u8,
    status_len: *usize,
    current_tab: *u8,
    mouse_regions: *const MouseRegions,
    quit_flag: *bool,
    input_buf: *[128]u8,
    input_len: *usize,
    process_columns: *ztop.config.ProcessColumns,
    io_process_columns: *ztop.config.ProcessColumns,
};

pub fn handleAvailableInput(ctx: *Context) !bool {
    var buf: [16]u8 = undefined;
    const n = ctx.app_tui.in.readStreaming(ctx.app_tui.io, &.{buf[0..]}) catch 0;
    if (n == 0) return false;

    if (ctx.input_len.* + n > ctx.input_buf.len) {
        ctx.input_len.* = 0;
    }

    const write_len = @min(n, ctx.input_buf.len - ctx.input_len.*);
    @memcpy(ctx.input_buf.*[ctx.input_len.* .. ctx.input_len.* + write_len], buf[0..write_len]);
    ctx.input_len.* += write_len;

    var handled_any = false;
    var sort_dirty = false;

    while (ctx.input_len.* > 0) {
        const parsed = switch (Tui.parseInputToken(ctx.input_buf.*[0..ctx.input_len.*])) {
            .parsed => |token| token,
            .incomplete => break,
            .invalid => |used| {
                const consume = @max(@as(usize, 1), used);
                std.mem.copyForwards(u8, ctx.input_buf.*[0 .. ctx.input_len.* - consume], ctx.input_buf.*[consume..ctx.input_len.*]);
                ctx.input_len.* -= consume;
                continue;
            },
        };

        std.mem.copyForwards(u8, ctx.input_buf.*[0 .. ctx.input_len.* - parsed.used], ctx.input_buf.*[parsed.used..ctx.input_len.*]);
        ctx.input_len.* -= parsed.used;

        var handled = false;
        const token = parsed.token;

        if (ctx.show_help.*) {
            ctx.show_help.* = false;
            handled = true;
        } else if (ctx.show_column_picker.*) {
            handled = handleColumnPickerToken(ctx, token);
        } else if (ctx.is_cmd_mode.*) {
            handled = handleCommandModeToken(ctx, token);
        } else if (ctx.is_filtering.*) {
            handled = handleFilterModeToken(ctx, token);
        } else {
            handled = try handleMainModeToken(ctx, token, &sort_dirty);
        }

        handled_any = handled_any or handled;
    }

    if (sort_dirty) {
        ztop.sysinfo.sortProcStats(ctx.cached_procs, ctx.sort_by.*);
    }

    return handled_any or (!ctx.quit_flag.* and write_len > 0);
}

fn handleColumnPickerToken(ctx: *Context, token: Tui.InputToken) bool {
    switch (token) {
        .mouse, .arrow_up, .arrow_down => return true,
        .enter, .escape => {
            ctx.show_column_picker.* = false;
            return true;
        },
        .byte => |ch| {
            if (ch == 'C') {
                ctx.show_column_picker.* = false;
                return true;
            }

            if (ch < '1' or ch > '8') return false;

            const column = ztop.config.process_column_order[@as(usize, ch - '1')];
            const visible = activeColumns(ctx).toggle(column);
            render.setStatus(
                ctx.status_buf,
                ctx.status_len,
                "{s} {s} column",
                .{ if (visible) "Showing" else "Hiding", column.label() },
            );
            return true;
        },
    }
}

fn handleCommandModeToken(ctx: *Context, token: Tui.InputToken) bool {
    switch (token) {
        .mouse, .arrow_up, .arrow_down => return true,
        .enter => {
            ctx.is_cmd_mode.* = false;
            executeCommand(ctx);
            ctx.cmd_len.* = 0;
            return true;
        },
        .escape => {
            ctx.is_cmd_mode.* = false;
            ctx.cmd_len.* = 0;
            return true;
        },
        .byte => |ch| {
            const input_byte = [1]u8{ch};
            _ = text_input.applyInputBytes(ctx.cmd_buf, ctx.cmd_len, input_byte[0..]);
            return true;
        },
    }
}

fn handleFilterModeToken(ctx: *Context, token: Tui.InputToken) bool {
    switch (token) {
        .mouse, .arrow_up, .arrow_down => return true,
        .enter => {
            ctx.is_filtering.* = false;
            return true;
        },
        .escape => {
            ctx.is_filtering.* = false;
            ctx.filter_len.* = 0;
            return true;
        },
        .byte => |ch| {
            const input_byte = [1]u8{ch};
            _ = text_input.applyInputBytes(ctx.filter_buf, ctx.filter_len, input_byte[0..]);
            return true;
        },
    }
}

fn handleMainModeToken(ctx: *Context, token: Tui.InputToken, sort_dirty: *bool) !bool {
    const list_count = if (ctx.current_tab.* == 4)
        ctx.cached_connections.*.len
    else if (ctx.thread_view.*)
        ctx.cached_threads.*.len
    else
        ctx.filtered_count.*;

    switch (token) {
        .mouse => |mouse| {
            switch (mouse.action) {
                .scroll_up => {
                    if (ctx.mouse_regions.list_rect.contains(mouse.x, mouse.y)) {
                        moveSelection(ctx.selected_idx, list_count, -1);
                    }
                    return true;
                },
                .scroll_down => {
                    if (ctx.mouse_regions.list_rect.contains(mouse.x, mouse.y)) {
                        moveSelection(ctx.selected_idx, list_count, 1);
                    }
                    return true;
                },
                .press => {
                    if (mouse.button == .left) {
                        if (ctx.mouse_regions.tabAt(mouse.x, mouse.y)) |tab| {
                            try setCurrentTab(
                                ctx.allocator,
                                ctx.sys_info,
                                ctx.cached_connections,
                                ctx.current_tab,
                                ctx.selected_idx,
                                ctx.scroll_offset,
                                tab,
                            );
                            return true;
                        } else if (listIndexAt(ctx.mouse_regions.*, mouse.x, mouse.y, ctx.scroll_offset.*, list_count)) |idx| {
                            ctx.selected_idx.* = idx;
                            return true;
                        }
                    }
                },
                else => {},
            }
            return false;
        },
        .arrow_up => {
            moveSelection(ctx.selected_idx, list_count, -1);
            return true;
        },
        .arrow_down => {
            moveSelection(ctx.selected_idx, list_count, 1);
            return true;
        },
        .enter => {
            try enterThreadView(ctx);
            return true;
        },
        .escape => {
            clearCurrentView(ctx);
            return true;
        },
        .byte => |ch| switch (ch) {
            '1' => {
                try setCurrentTab(ctx.allocator, ctx.sys_info, ctx.cached_connections, ctx.current_tab, ctx.selected_idx, ctx.scroll_offset, 1);
                return true;
            },
            '2' => {
                try setCurrentTab(ctx.allocator, ctx.sys_info, ctx.cached_connections, ctx.current_tab, ctx.selected_idx, ctx.scroll_offset, 2);
                return true;
            },
            '3' => {
                try setCurrentTab(ctx.allocator, ctx.sys_info, ctx.cached_connections, ctx.current_tab, ctx.selected_idx, ctx.scroll_offset, 3);
                return true;
            },
            '4' => {
                try setCurrentTab(ctx.allocator, ctx.sys_info, ctx.cached_connections, ctx.current_tab, ctx.selected_idx, ctx.scroll_offset, 4);
                return true;
            },
            'q' => {
                ctx.quit_flag.* = true;
                return true;
            },
            '?', 'h' => {
                ctx.show_help.* = true;
                return true;
            },
            'j' => {
                moveSelection(ctx.selected_idx, list_count, 1);
                return true;
            },
            'k' => {
                moveSelection(ctx.selected_idx, list_count, -1);
                return true;
            },
            'c' => {
                if (!ctx.thread_view.*) {
                    ctx.sort_by.* = .cpu;
                    sort_dirty.* = true;
                }
                return true;
            },
            'm' => {
                if (!ctx.thread_view.*) {
                    ctx.sort_by.* = .mem;
                    sort_dirty.* = true;
                }
                return true;
            },
            'p' => {
                if (!ctx.thread_view.*) {
                    ctx.sort_by.* = .pid;
                    sort_dirty.* = true;
                }
                return true;
            },
            'n' => {
                if (!ctx.thread_view.*) {
                    ctx.sort_by.* = .name;
                    sort_dirty.* = true;
                }
                return true;
            },
            'v' => {
                if (!ctx.thread_view.*) {
                    ctx.tree_view.* = !ctx.tree_view.*;
                }
                return true;
            },
            'C' => {
                if (!ctx.thread_view.* and ctx.current_tab.* != 4) {
                    ctx.show_column_picker.* = true;
                }
                return true;
            },
            '/' => {
                if (!ctx.thread_view.*) {
                    ctx.is_filtering.* = true;
                }
                return true;
            },
            ':' => {
                if (!ctx.thread_view.*) {
                    ctx.is_cmd_mode.* = true;
                }
                return true;
            },
            't' => {
                signalSelectedProcess(ctx, posix.SIG.TERM);
                return true;
            },
            'K' => {
                signalSelectedProcess(ctx, posix.SIG.KILL);
                return true;
            },
            else => return false,
        },
    }
}

fn activeColumns(ctx: *Context) *ztop.config.ProcessColumns {
    if (ctx.current_tab.* == 2) return ctx.io_process_columns;
    return ctx.process_columns;
}

fn executeCommand(ctx: *Context) void {
    const cmd = ctx.cmd_buf.*[0..ctx.cmd_len.*];
    if (std.mem.eql(u8, cmd, "show zombie")) {
        ctx.zombie_summary.* = process_commands.collectZombieParents(ctx.cached_procs, ctx.zombie_parents);
        ctx.show_zombie_parents.* = true;
        ctx.filter_len.* = 0;
        ctx.selected_idx.* = 0;
        ctx.scroll_offset.* = 0;

        if (ctx.zombie_summary.zombie_count == 0) {
            render.setStatus(ctx.status_buf, ctx.status_len, "No zombie processes found", .{});
        } else if (ctx.zombie_summary.parent_count == 0) {
            render.setStatus(ctx.status_buf, ctx.status_len, "Found {d} zombies, but no visible parent processes", .{ctx.zombie_summary.zombie_count});
        } else {
            const parent_label = if (ctx.zombie_summary.parent_count == 1) "parent process" else "parent processes";
            const zombie_label = if (ctx.zombie_summary.zombie_count == 1) "zombie" else "zombies";
            render.setStatus(
                ctx.status_buf,
                ctx.status_len,
                "Showing {d} {s} for {d} {s}. Esc clears",
                .{ ctx.zombie_summary.parent_count, parent_label, ctx.zombie_summary.zombie_count, zombie_label },
            );
        }
    } else if (std.mem.startsWith(u8, cmd, "killall ")) {
        const target = cmd[8..];
        var matches: usize = 0;
        for (ctx.cached_procs) |proc| {
            var l_name: [64]u8 = undefined;
            const name_len = proc.name().len;
            @memcpy(l_name[0..name_len], proc.name());
            const n_str = l_name[0..name_len];
            for (n_str) |*c| c.* = std.ascii.toLower(c.*);

            var l_target: [64]u8 = undefined;
            const target_len = @min(target.len, 64);
            @memcpy(l_target[0..target_len], target[0..target_len]);
            const t_str = l_target[0..target_len];
            for (t_str) |*c| c.* = std.ascii.toLower(c.*);

            if (std.mem.indexOf(u8, n_str, t_str) != null) {
                _ = posix.kill(@intCast(proc.pid), posix.SIG.TERM) catch {};
                matches += 1;
            }
        }

        if (matches == 0) {
            render.setStatus(ctx.status_buf, ctx.status_len, "No processes matched '{s}'", .{target});
        } else {
            render.setStatus(ctx.status_buf, ctx.status_len, "Sent SIGTERM to {d} matching processes", .{matches});
        }
    } else if (std.mem.startsWith(u8, cmd, "search ")) {
        const target = cmd[7..];
        ctx.is_filtering.* = true;
        ctx.filter_len.* = @min(target.len, ctx.filter_buf.len);
        @memcpy(ctx.filter_buf.*[0..ctx.filter_len.*], target[0..ctx.filter_len.*]);
        ctx.status_len.* = 0;
    } else if (std.mem.eql(u8, cmd, "q") or std.mem.eql(u8, cmd, "quit")) {
        ctx.quit_flag.* = true;
    } else if (cmd.len > 0) {
        render.setStatus(ctx.status_buf, ctx.status_len, "Unknown command: {s}", .{cmd});
    }
}

fn enterThreadView(ctx: *Context) !void {
    if (ctx.current_tab.* == 4 or ctx.thread_view.* or ctx.filtered_count.* == 0 or ctx.selected_idx.* >= ctx.filtered_count.*) {
        return;
    }

    const proc = ctx.cached_procs[ctx.filtered_indices[ctx.selected_idx.*]];
    ctx.thread_view_pid.* = proc.pid;
    ctx.thread_view_name_len.* = proc.name_len;
    @memcpy(ctx.thread_view_name_buf.*[0..proc.name_len], proc.name());
    ctx.thread_view.* = true;
    ctx.selected_idx.* = 0;
    ctx.scroll_offset.* = 0;

    if (ctx.cached_threads.*.len > 0) {
        ctx.allocator.free(ctx.cached_threads.*);
    }
    ctx.cached_threads.* = ctx.sys_info.getThreadStats(ctx.allocator, ctx.thread_view_pid.*) catch &.{};
}

fn clearCurrentView(ctx: *Context) void {
    if (ctx.thread_view.*) {
        ctx.thread_view.* = false;
        if (ctx.cached_threads.*.len > 0) {
            ctx.allocator.free(ctx.cached_threads.*);
            ctx.cached_threads.* = &.{};
        }
        ctx.selected_idx.* = 0;
        ctx.scroll_offset.* = 0;
    } else {
        ctx.filter_len.* = 0;
        ctx.status_len.* = 0;
        ctx.zombie_summary.* = .{};
        ctx.show_zombie_parents.* = false;
    }
}

fn signalSelectedProcess(ctx: *Context, signal: posix.SIG) void {
    if (ctx.current_tab.* != 4 and !ctx.thread_view.* and ctx.filtered_count.* > 0 and ctx.selected_idx.* < ctx.filtered_count.*) {
        const pid = ctx.cached_procs[ctx.filtered_indices[ctx.selected_idx.*]].pid;
        _ = posix.kill(@intCast(pid), signal) catch {};
    }
}

fn setCurrentTab(
    allocator: std.mem.Allocator,
    sys_info: *SysInfo,
    cached_connections: *[]ztop.sysinfo.common.NetConnection,
    current_tab: *u8,
    selected_idx: *usize,
    scroll_offset: *usize,
    tab: u8,
) !void {
    if (current_tab.* == tab) return;

    current_tab.* = tab;
    if (tab == 4) {
        try render.refreshConnections(allocator, sys_info, cached_connections);
    }
    selected_idx.* = 0;
    scroll_offset.* = 0;
}

fn moveSelection(selected_idx: *usize, list_count: usize, delta: i32) void {
    if (list_count == 0 or delta == 0) return;

    if (delta < 0) {
        const amount: usize = @intCast(-delta);
        selected_idx.* = selected_idx.* -| amount;
    } else {
        const amount: usize = @intCast(delta);
        selected_idx.* = @min(selected_idx.* + amount, list_count - 1);
    }
}

fn listIndexAt(regions: MouseRegions, x: u16, y: u16, scroll_offset: usize, list_count: usize) ?usize {
    if (!regions.list_rect.contains(x, y)) return null;

    const row: usize = y - regions.list_rect.y;
    const idx = scroll_offset + row;
    if (idx >= list_count) return null;
    return idx;
}
