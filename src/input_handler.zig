const std = @import("std");
const render = @import("render.zig");
const process_commands = @import("process_commands.zig");
const tui_mod = @import("tui.zig");
const Tui = tui_mod.Tui;
const sysinfo = @import("sysinfo.zig");
const SysInfo = sysinfo.SysInfo;
const config = @import("config.zig");
const timeline_mod = @import("timeline.zig");
const process_tracer = @import("process_tracer.zig");
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
    tabs: [5]TabRegion = undefined,
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

pub const EditAction = enum {
    none,
    submit,
    cancel,
};

pub fn applyInputBytes(dest: []u8, len: *usize, input: []const u8) EditAction {
    for (input) |ch| {
        switch (ch) {
            '\r', '\n' => return .submit,
            '\x1b' => return .cancel,
            127, '\x08' => {
                if (len.* > 0) len.* = len.* - 1;
            },
            else => if (ch >= 32 and ch <= 126 and len.* < dest.len) {
                dest[len.*] = ch;
                len.* += 1;
            },
        }
    }

    return .none;
}

pub const Context = struct {
    allocator: std.mem.Allocator,
    sys_info: *SysInfo,
    app_tui: *Tui,
    cached_procs: []sysinfo.ProcStats,
    cached_threads: *[]sysinfo.ThreadStats,
    cached_connections: *[]sysinfo.common.NetConnection,
    sort_by: *sysinfo.SortBy,
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
    causality_view: *bool,
    causality_pid: *u32,
    causality_name_buf: *[64]u8,
    causality_name_len: *u8,
    causality_connections: *[]sysinfo.common.NetConnection,
    lifeline_view: *bool,
    lifeline_name_buf: *[64]u8,
    lifeline_name_len: *u8,
    active_tracer: *?*process_tracer.ProcessTracer,
    is_following: *bool,
    follow_pid: *u32,
    status_buf: *[160]u8,
    status_len: *usize,
    current_tab: *u8,
    mouse_regions: *const MouseRegions,
    quit_flag: *bool,
    input_buf: *[128]u8,
    input_len: *usize,
    process_columns: *config.ProcessColumns,
    io_process_columns: *config.ProcessColumns,
    is_scrubbing: *bool,
    scrub_offset: *usize,
    timeline: *timeline_mod.Timeline,
    diff_anchor: *?usize,
    refresh_interval_ms: *?u32,
    top_n: *?usize,
    pipeline_view: *bool,
    pipeline_row_count: *usize,
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
        sysinfo.sortProcStats(ctx.cached_procs, ctx.sort_by.*);
    }

    return handled_any or (!ctx.quit_flag.* and write_len > 0);
}

fn handleColumnPickerToken(ctx: *Context, token: Tui.InputToken) bool {
    switch (token) {
        .mouse, .arrow_up, .arrow_down, .arrow_left, .arrow_right => return true,
        .enter, .escape => {
            ctx.show_column_picker.* = false;
            return true;
        },
        .byte => |ch| {
            if (ch == 'C') {
                ctx.show_column_picker.* = false;
                return true;
            }

            const column_idx: usize = if (ch >= '1' and ch <= '9')
                @as(usize, ch - '1')
            else if (ch == '0' and config.process_column_order.len >= 10)
                9
            else
                return false;
            if (column_idx >= config.process_column_order.len) return false;

            const column = config.process_column_order[column_idx];
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
        .mouse, .arrow_up, .arrow_down, .arrow_left, .arrow_right => return true,
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
            _ = applyInputBytes(ctx.cmd_buf, ctx.cmd_len, input_byte[0..]);
            return true;
        },
    }
}

fn handleFilterModeToken(ctx: *Context, token: Tui.InputToken) bool {
    switch (token) {
        .mouse, .arrow_up, .arrow_down, .arrow_left, .arrow_right => return true,
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
            _ = applyInputBytes(ctx.filter_buf, ctx.filter_len, input_byte[0..]);
            return true;
        },
    }
}

fn handleMainModeToken(ctx: *Context, token: Tui.InputToken, sort_dirty: *bool) !bool {
    const list_count = if (ctx.current_tab.* == 4)
        ctx.cached_connections.*.len
    else if (ctx.thread_view.*)
        ctx.cached_threads.*.len
    else if (ctx.pipeline_view.*)
        ctx.pipeline_row_count.*
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
        .arrow_left => {
            // Scrub further into the past
            if (ctx.is_scrubbing.*) {
                const max_offset = ctx.timeline.snapshotCount() -| 1;
                if (ctx.scrub_offset.* < max_offset) ctx.scrub_offset.* += 1;
            }
            return true;
        },
        .arrow_right => {
            // Scrub toward the present
            if (ctx.is_scrubbing.*) {
                if (ctx.scrub_offset.* > 0) ctx.scrub_offset.* -= 1;
            }
            return true;
        },
        .enter => {
            if (!ctx.is_scrubbing.*) try enterThreadView(ctx);
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
            '5' => {
                try setCurrentTab(ctx.allocator, ctx.sys_info, ctx.cached_connections, ctx.current_tab, ctx.selected_idx, ctx.scroll_offset, 5);
                return true;
            },
            '\t' => {
                if (ctx.current_tab.* == 5) {
                    render.triggerAiDiagnostic();
                    return true;
                }
                return false;
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
                if (!ctx.thread_view.* and !ctx.is_scrubbing.*) {
                    ctx.sort_by.* = .cpu;
                    sort_dirty.* = true;
                }
                return true;
            },
            'm' => {
                if (!ctx.thread_view.* and !ctx.is_scrubbing.*) {
                    ctx.sort_by.* = .mem;
                    sort_dirty.* = true;
                }
                return true;
            },
            'p' => {
                if (!ctx.thread_view.* and !ctx.is_scrubbing.*) {
                    ctx.sort_by.* = .pid;
                    sort_dirty.* = true;
                }
                return true;
            },
            'n' => {
                if (!ctx.thread_view.* and !ctx.is_scrubbing.*) {
                    ctx.sort_by.* = .name;
                    sort_dirty.* = true;
                }
                return true;
            },
            'u' => {
                if (!ctx.thread_view.* and !ctx.is_scrubbing.*) {
                    ctx.sort_by.* = .wakeups;
                    sort_dirty.* = true;
                }
                return true;
            },
            'v' => {
                if (!ctx.thread_view.* and !ctx.is_scrubbing.*) {
                    ctx.tree_view.* = !ctx.tree_view.*;
                }
                return true;
            },
            'C' => {
                if (!ctx.thread_view.* and !ctx.is_scrubbing.* and ctx.current_tab.* != 4) {
                    ctx.show_column_picker.* = true;
                }
                return true;
            },
            '/' => {
                if (!ctx.thread_view.* and !ctx.is_scrubbing.*) {
                    ctx.is_filtering.* = true;
                }
                return true;
            },
            ':' => {
                if (!ctx.thread_view.* and !ctx.is_scrubbing.*) {
                    ctx.is_cmd_mode.* = true;
                }
                return true;
            },
            't' => {
                if (!ctx.is_scrubbing.*) signalSelectedProcess(ctx, posix.SIG.TERM);
                return true;
            },
            'K' => {
                if (!ctx.is_scrubbing.*) signalSelectedProcess(ctx, posix.SIG.KILL);
                return true;
            },
            'T' => {
                if (ctx.timeline.snapshotCount() >= 2) {
                    ctx.is_scrubbing.* = !ctx.is_scrubbing.*;
                    ctx.scrub_offset.* = 0;
                } else {
                    render.setStatus(ctx.status_buf, ctx.status_len, "Timeline: not enough data yet", .{});
                }
                return true;
            },
            '[' => {
                // Fast scrub: jump 10 snapshots older
                if (ctx.is_scrubbing.*) {
                    const max_offset = ctx.timeline.snapshotCount() -| 1;
                    ctx.scrub_offset.* = @min(ctx.scrub_offset.* + 10, max_offset);
                }
                return true;
            },
            ']' => {
                // Fast scrub: jump 10 snapshots newer
                if (ctx.is_scrubbing.*) {
                    ctx.scrub_offset.* = ctx.scrub_offset.* -| 10;
                }
                return true;
            },
            'b' => {
                // Drop bookmark at current scrub position
                if (ctx.is_scrubbing.*) {
                    if (ctx.timeline.addBookmark(ctx.scrub_offset.*)) {
                        render.setStatus(ctx.status_buf, ctx.status_len, "Bookmark added ({d}/{d})", .{ ctx.timeline.bookmark_count, timeline_mod.MAX_BOOKMARKS });
                    } else if (ctx.timeline.bookmark_count >= timeline_mod.MAX_BOOKMARKS) {
                        render.setStatus(ctx.status_buf, ctx.status_len, "Max bookmarks reached ({d})", .{timeline_mod.MAX_BOOKMARKS});
                    } else {
                        render.setStatus(ctx.status_buf, ctx.status_len, "Bookmark already exists here", .{});
                    }
                }
                return true;
            },
            'B' => {
                // Remove nearest bookmark
                if (ctx.is_scrubbing.*) {
                    if (ctx.timeline.removeBookmarkNearest(ctx.scrub_offset.*)) {
                        render.setStatus(ctx.status_buf, ctx.status_len, "Bookmark removed ({d} remaining)", .{ctx.timeline.bookmark_count});
                    } else {
                        render.setStatus(ctx.status_buf, ctx.status_len, "No bookmarks to remove", .{});
                    }
                }
                return true;
            },
            '{' => {
                // Jump to previous bookmark (further into past)
                if (ctx.is_scrubbing.*) {
                    if (ctx.timeline.prevBookmarkOffset(ctx.scrub_offset.*)) |offset| {
                        ctx.scrub_offset.* = offset;
                    } else {
                        render.setStatus(ctx.status_buf, ctx.status_len, "No older bookmark", .{});
                    }
                }
                return true;
            },
            '}' => {
                // Jump to next bookmark (toward present)
                if (ctx.is_scrubbing.*) {
                    if (ctx.timeline.nextBookmarkOffset(ctx.scrub_offset.*)) |offset| {
                        ctx.scrub_offset.* = offset;
                    } else {
                        render.setStatus(ctx.status_buf, ctx.status_len, "No newer bookmark", .{});
                    }
                }
                return true;
            },
            'd' => {
                // Toggle diff anchor for before/after comparison
                if (ctx.is_scrubbing.*) {
                    if (ctx.diff_anchor.* != null) {
                        ctx.diff_anchor.* = null;
                        render.setStatus(ctx.status_buf, ctx.status_len, "Diff view closed", .{});
                    } else {
                        ctx.diff_anchor.* = ctx.scrub_offset.*;
                        render.setStatus(ctx.status_buf, ctx.status_len, "Diff anchor set. Navigate to compare point", .{});
                    }
                }
                return true;
            },
            'g' => {
                if (!ctx.thread_view.* and !ctx.causality_view.* and !ctx.is_scrubbing.* and ctx.current_tab.* != 4 and ctx.current_tab.* != 5) {
                    try enterCausalityView(ctx);
                }
                return true;
            },

            'f' => {
                if (!ctx.thread_view.* and !ctx.causality_view.* and !ctx.lifeline_view.* and !ctx.pipeline_view.* and !ctx.is_scrubbing.* and ctx.filtered_count.* > 0) {
                    if (ctx.is_following.*) {
                        ctx.is_following.* = false;
                        ctx.follow_pid.* = 0;
                    } else if (ctx.selected_idx.* < ctx.filtered_count.*) {
                        ctx.follow_pid.* = ctx.cached_procs[ctx.filtered_indices[ctx.selected_idx.*]].pid;
                        ctx.is_following.* = true;
                    }
                }
                return true;
            },
            'L' => {
                if (!ctx.thread_view.* and !ctx.causality_view.* and !ctx.lifeline_view.* and !ctx.pipeline_view.* and !ctx.is_scrubbing.* and ctx.current_tab.* != 4) {
                    try enterLifelineView(ctx);
                }
                return true;
            },
            'P' => {
                if (!ctx.thread_view.* and !ctx.causality_view.* and !ctx.lifeline_view.* and !ctx.is_scrubbing.* and ctx.current_tab.* != 4 and ctx.current_tab.* != 5) {
                    ctx.pipeline_view.* = !ctx.pipeline_view.*;
                    ctx.selected_idx.* = 0;
                    ctx.scroll_offset.* = 0;
                }
                return true;
            },
            else => return false,
        },
    }
}

fn activeColumns(ctx: *Context) *config.ProcessColumns {
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
        // Pre-compute lowercased target once outside the loop
        var l_target: [64]u8 = undefined;
        const target_len = @min(target.len, 64);
        @memcpy(l_target[0..target_len], target[0..target_len]);
        for (l_target[0..target_len]) |*c| c.* = std.ascii.toLower(c.*);
        const t_str = l_target[0..target_len];

        var l_name: [64]u8 = undefined;
        for (ctx.cached_procs) |proc| {
            const name_len = proc.name().len;
            @memcpy(l_name[0..name_len], proc.name());
            const n_str = l_name[0..name_len];
            for (n_str) |*c| c.* = std.ascii.toLower(c.*);

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
    } else if (std.mem.startsWith(u8, cmd, "pid ")) {
        const pid_str = std.mem.trim(u8, cmd[4..], " ");
        const target_pid = std.fmt.parseInt(u32, pid_str, 10) catch {
            render.setStatus(ctx.status_buf, ctx.status_len, "Invalid PID: {s}", .{pid_str});
            return;
        };
        var found = false;
        for (ctx.filtered_indices[0..ctx.filtered_count.*], 0..) |proc_idx, list_idx| {
            if (ctx.cached_procs[proc_idx].pid == target_pid) {
                ctx.selected_idx.* = list_idx;
                ctx.scroll_offset.* = if (list_idx > 5) list_idx - 5 else 0;
                render.setStatus(ctx.status_buf, ctx.status_len, "Jumped to PID {d}", .{target_pid});
                found = true;
                break;
            }
        }
        if (!found) {
            render.setStatus(ctx.status_buf, ctx.status_len, "PID {d} not found", .{target_pid});
        }
    } else if (std.mem.startsWith(u8, cmd, "signal ")) {
        const rest = cmd[7..];
        if (std.mem.indexOf(u8, rest, " ")) |space_idx| {
            const sig_name = rest[0..space_idx];
            const target = rest[space_idx + 1 ..];
            const valid_signals = [_][]const u8{ "STOP", "CONT", "HUP", "INT", "USR1", "USR2", "QUIT" };
            var sig_valid = false;
            for (valid_signals) |s| {
                if (std.mem.eql(u8, sig_name, s)) {
                    sig_valid = true;
                    break;
                }
            }
            if (!sig_valid) {
                render.setStatus(ctx.status_buf, ctx.status_len, "Unknown signal: {s}. Try STOP/CONT/HUP/INT/USR1/USR2/QUIT", .{sig_name});
                return;
            }
            var l_target: [64]u8 = undefined;
            const target_len = @min(target.len, 64);
            @memcpy(l_target[0..target_len], target[0..target_len]);
            for (l_target[0..target_len]) |*c| c.* = std.ascii.toLower(c.*);
            const t_str = l_target[0..target_len];
            var l_name: [64]u8 = undefined;
            var matches: usize = 0;
            for (ctx.cached_procs) |proc| {
                const name_len = proc.name().len;
                @memcpy(l_name[0..name_len], proc.name());
                const n_str = l_name[0..name_len];
                for (n_str) |*c| c.* = std.ascii.toLower(c.*);
                if (std.mem.indexOf(u8, n_str, t_str) != null) {
                    sendSignalByName(proc.pid, sig_name);
                    matches += 1;
                }
            }
            if (matches == 0) {
                render.setStatus(ctx.status_buf, ctx.status_len, "No processes matched '{s}'", .{target});
            } else {
                render.setStatus(ctx.status_buf, ctx.status_len, "Sent SIG{s} to {d} matching processes", .{ sig_name, matches });
            }
        } else {
            render.setStatus(ctx.status_buf, ctx.status_len, "Usage: signal <SIG> <name>", .{});
        }
    } else if (std.mem.startsWith(u8, cmd, "renice ")) {
        const rest = cmd[7..];
        if (std.mem.indexOf(u8, rest, " ")) |space_idx| {
            const value_str = rest[0..space_idx];
            const target = rest[space_idx + 1 ..];
            const nice_val = std.fmt.parseInt(i32, value_str, 10) catch {
                render.setStatus(ctx.status_buf, ctx.status_len, "Invalid nice value: {s}", .{value_str});
                return;
            };
            if (nice_val < -20 or nice_val > 19) {
                render.setStatus(ctx.status_buf, ctx.status_len, "Nice value must be -20 to 19", .{});
                return;
            }
            var l_target: [64]u8 = undefined;
            const target_len = @min(target.len, 64);
            @memcpy(l_target[0..target_len], target[0..target_len]);
            for (l_target[0..target_len]) |*c| c.* = std.ascii.toLower(c.*);
            const t_str = l_target[0..target_len];
            var l_name: [64]u8 = undefined;
            var matches: usize = 0;
            for (ctx.cached_procs) |proc| {
                const name_len = proc.name().len;
                @memcpy(l_name[0..name_len], proc.name());
                const n_str = l_name[0..name_len];
                for (n_str) |*c| c.* = std.ascii.toLower(c.*);
                if (std.mem.indexOf(u8, n_str, t_str) != null) {
                    _ = setpriority(PRIO_PROCESS, @intCast(proc.pid), nice_val);
                    matches += 1;
                }
            }
            if (matches == 0) {
                render.setStatus(ctx.status_buf, ctx.status_len, "No processes matched '{s}'", .{target});
            } else {
                render.setStatus(ctx.status_buf, ctx.status_len, "Reniced {d} matching processes to {d}", .{ matches, nice_val });
            }
        } else {
            render.setStatus(ctx.status_buf, ctx.status_len, "Usage: renice <value> <name>", .{});
        }
    } else if (std.mem.startsWith(u8, cmd, "interval ")) {
        const val_str = std.mem.trim(u8, cmd[9..], " ");
        if (std.mem.eql(u8, val_str, "reset") or std.mem.eql(u8, val_str, "off")) {
            ctx.refresh_interval_ms.* = null;
            render.setStatus(ctx.status_buf, ctx.status_len, "Refresh interval reset to default", .{});
        } else {
            const ms = std.fmt.parseInt(u32, val_str, 10) catch {
                render.setStatus(ctx.status_buf, ctx.status_len, "Invalid interval: {s}", .{val_str});
                return;
            };
            if (ms < 100) {
                render.setStatus(ctx.status_buf, ctx.status_len, "Interval must be >= 100ms", .{});
                return;
            }
            ctx.refresh_interval_ms.* = ms;
            render.setStatus(ctx.status_buf, ctx.status_len, "Refresh interval set to {d}ms", .{ms});
        }
    } else if (std.mem.startsWith(u8, cmd, "top ")) {
        const val_str = std.mem.trim(u8, cmd[4..], " ");
        if (std.mem.eql(u8, val_str, "off") or std.mem.eql(u8, val_str, "reset")) {
            ctx.top_n.* = null;
            render.setStatus(ctx.status_buf, ctx.status_len, "Top-N filter cleared", .{});
        } else {
            const n = std.fmt.parseInt(usize, val_str, 10) catch {
                render.setStatus(ctx.status_buf, ctx.status_len, "Invalid number: {s}", .{val_str});
                return;
            };
            if (n == 0) {
                render.setStatus(ctx.status_buf, ctx.status_len, "N must be > 0", .{});
                return;
            }
            ctx.top_n.* = n;
            render.setStatus(ctx.status_buf, ctx.status_len, "Showing top {d} processes", .{n});
        }
    } else if (cmd.len > 0) {
        render.setStatus(ctx.status_buf, ctx.status_len, "Unknown command: {s}", .{cmd});
    }
}

const PRIO_PROCESS: c_int = 0;
extern fn setpriority(which: c_int, who: c_uint, prio: c_int) c_int;

fn sendSignalByName(pid: u32, sig_name: []const u8) void {
    if (std.mem.eql(u8, sig_name, "STOP")) {
        _ = posix.kill(@intCast(pid), posix.SIG.STOP) catch {};
    } else if (std.mem.eql(u8, sig_name, "CONT")) {
        _ = posix.kill(@intCast(pid), posix.SIG.CONT) catch {};
    } else if (std.mem.eql(u8, sig_name, "HUP")) {
        _ = posix.kill(@intCast(pid), posix.SIG.HUP) catch {};
    } else if (std.mem.eql(u8, sig_name, "INT")) {
        _ = posix.kill(@intCast(pid), posix.SIG.INT) catch {};
    } else if (std.mem.eql(u8, sig_name, "USR1")) {
        _ = posix.kill(@intCast(pid), posix.SIG.USR1) catch {};
    } else if (std.mem.eql(u8, sig_name, "USR2")) {
        _ = posix.kill(@intCast(pid), posix.SIG.USR2) catch {};
    } else if (std.mem.eql(u8, sig_name, "QUIT")) {
        _ = posix.kill(@intCast(pid), posix.SIG.QUIT) catch {};
    }
}

fn enterLifelineView(ctx: *Context) !void {
    if (ctx.current_tab.* == 4 or ctx.causality_view.* or ctx.thread_view.* or ctx.lifeline_view.* or ctx.pipeline_view.* or ctx.filtered_count.* == 0 or ctx.selected_idx.* >= ctx.filtered_count.*) {
        return;
    }

    const proc = ctx.cached_procs[ctx.filtered_indices[ctx.selected_idx.*]];

    // Allocate and initialize ProcessTracer
    if (ctx.active_tracer.*) |tracer| {
        tracer.deinit();
        ctx.active_tracer.* = null;
    }
    ctx.active_tracer.* = try process_tracer.ProcessTracer.init(ctx.allocator, proc.pid);

    ctx.lifeline_view.* = true;
    @memcpy(ctx.lifeline_name_buf.*[0..proc.name_len], proc.name());
    ctx.lifeline_name_len.* = proc.name_len;
    ctx.selected_idx.* = 0;
    ctx.scroll_offset.* = 0;
}

fn enterCausalityView(ctx: *Context) !void {
    if (ctx.current_tab.* == 4 or ctx.causality_view.* or ctx.thread_view.* or ctx.pipeline_view.* or ctx.filtered_count.* == 0 or ctx.selected_idx.* >= ctx.filtered_count.*) {
        return;
    }

    const proc = ctx.cached_procs[ctx.filtered_indices[ctx.selected_idx.*]];
    ctx.causality_pid.* = proc.pid;
    ctx.causality_name_len.* = proc.name_len;
    @memcpy(ctx.causality_name_buf.*[0..proc.name_len], proc.name());
    ctx.causality_view.* = true;
    ctx.selected_idx.* = 0;
    ctx.scroll_offset.* = 0;

    // Load connections for this process
    if (ctx.causality_connections.*.len > 0) {
        ctx.allocator.free(ctx.causality_connections.*);
    }
    ctx.causality_connections.* = fetchProcConnections(ctx.allocator, ctx.sys_info, proc.pid) catch &.{};
}

pub fn fetchProcConnections(allocator: std.mem.Allocator, sys_info: *SysInfo, pid: u32) ![]sysinfo.common.NetConnection {
    const all_conns = try sys_info.getNetConnections(allocator);
    defer allocator.free(all_conns);

    var count: usize = 0;
    for (all_conns) |conn| {
        if (conn.pid == pid) count += 1;
    }

    if (count == 0) return &.{};

    const result = try allocator.alloc(sysinfo.common.NetConnection, count);
    var i: usize = 0;
    for (all_conns) |conn| {
        if (conn.pid == pid) {
            result[i] = conn;
            i += 1;
        }
    }
    return result;
}

fn enterThreadView(ctx: *Context) !void {
    if (ctx.current_tab.* == 4 or ctx.thread_view.* or ctx.causality_view.* or ctx.pipeline_view.* or ctx.filtered_count.* == 0 or ctx.selected_idx.* >= ctx.filtered_count.*) {
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
    if (ctx.diff_anchor.* != null) {
        ctx.diff_anchor.* = null;
    } else if (ctx.is_scrubbing.*) {
        ctx.is_scrubbing.* = false;
        ctx.scrub_offset.* = 0;
    } else if (ctx.causality_view.*) {
        ctx.causality_view.* = false;
        if (ctx.causality_connections.*.len > 0) {
            ctx.allocator.free(ctx.causality_connections.*);
            ctx.causality_connections.* = &.{};
        }
        ctx.selected_idx.* = 0;
        ctx.scroll_offset.* = 0;
    } else if (ctx.thread_view.*) {
        ctx.thread_view.* = false;
        if (ctx.cached_threads.*.len > 0) {
            ctx.allocator.free(ctx.cached_threads.*);
            ctx.cached_threads.* = &.{};
        }
        ctx.selected_idx.* = 0;
        ctx.scroll_offset.* = 0;
    } else if (ctx.lifeline_view.*) {
        ctx.lifeline_view.* = false;
        if (ctx.active_tracer.*) |tracer| {
            tracer.deinit();
            ctx.active_tracer.* = null;
        }
        ctx.selected_idx.* = 0;
        ctx.scroll_offset.* = 0;
    } else if (ctx.pipeline_view.*) {
        ctx.pipeline_view.* = false;
        ctx.selected_idx.* = 0;
        ctx.scroll_offset.* = 0;
    } else if (ctx.is_following.*) {
        ctx.is_following.* = false;
        ctx.follow_pid.* = 0;
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
    cached_connections: *[]sysinfo.common.NetConnection,
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
