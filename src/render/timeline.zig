const std = @import("std");
const tui = @import("../tui.zig");
const config = @import("../config.zig");
const timeline_mod = @import("../timeline.zig");
const Tui = tui.Tui;

fn cpuDensityChar(cpu_pct: f32) []const u8 {
    if (cpu_pct >= 75.0) return "▓";
    if (cpu_pct >= 50.0) return "▒";
    if (cpu_pct >= 25.0) return "░";
    return "·";
}

/// Render the timeline scrubber bar.
pub fn renderTimelineBar(
    app_tui: *Tui,
    theme: config.Theme,
    x: u16,
    y: u16,
    width: u16,
    tl: *const timeline_mod.Timeline,
    scrub_offset: usize,
    is_scrubbing: bool,
    diff_anchor: ?usize,
) !void {
    if (width < 12) return;
    const snap_count = tl.snapshotCount();
    // Diff anchor absolute index
    const anchor_abs: ?usize = if (diff_anchor) |anchor| (if (snap_count > 0) snap_count - 1 - @min(anchor, snap_count - 1) else null) else null;

    try app_tui.moveCursor(x, y);

    // Left nav indicator
    const can_go_older = is_scrubbing and scrub_offset + 1 < snap_count;
    const left_nav = if (app_tui.hasNerdFonts()) "󰒮" else "◀";
    const right_nav = if (app_tui.hasNerdFonts()) "󰒭" else "▶";
    const bookmark_marker = if (app_tui.hasNerdFonts()) "󰃀" else "▼";
    const anchor_marker = if (app_tui.hasNerdFonts()) "󰛿" else "◆";
    const cursor_bookmark = if (app_tui.hasNerdFonts()) "󰃀" else "▼";
    const cursor_marker = if (app_tui.hasNerdFonts()) "󱞪" else "|";
    try app_tui.writeStyled(
        if (can_go_older) .{ .fg = theme.tab_active, .bold = true } else .{ .fg = theme.muted },
        left_nav,
    );

    const suffix_reserve: u16 = 12;
    const bar_width: usize = if (width > 4 + suffix_reserve) @as(usize, width) - 4 - @as(usize, suffix_reserve) else 2;

    try app_tui.bufWrite(" ");

    if (snap_count == 0) {
        try app_tui.writeStyled(.{ .fg = theme.muted }, "Recording...");
    } else {
        // Determine the visible window: last bar_width snapshots (newest on right)
        const visible_snaps = @min(snap_count, bar_width);
        const oldest_visible_abs = snap_count -| visible_snaps;

        // Scrub cursor absolute index (from oldest)
        const scrub_abs: usize = if (snap_count > 0) snap_count - 1 - scrub_offset else 0;

        for (0..bar_width) |col| {
            // col 0 = oldest visible, col bar_width-1 = newest
            const abs_idx = oldest_visible_abs + col;
            const in_range = abs_idx < snap_count;
            const is_cursor = is_scrubbing and in_range and abs_idx == scrub_abs;

            if (!in_range) {
                // Left-pad area before history starts
                try app_tui.bufWrite(" ");
                continue;
            }

            if (is_cursor) {
                // Show combined cursor+bookmark indicator if bookmarked
                if (tl.hasBookmarkAtAbsIndex(abs_idx)) {
                    try app_tui.writeStyled(.{ .bg = theme.tab_active, .fg = theme.selection_fg, .bold = true }, cursor_bookmark);
                } else {
                    try app_tui.writeStyled(.{ .bg = theme.selection_bg, .fg = theme.selection_fg, .bold = true }, cursor_marker);
                }
                continue;
            }

            // Bookmark marker (priority over events)
            if (tl.hasBookmarkAtAbsIndex(abs_idx)) {
                try app_tui.writeStyled(.{ .fg = theme.tab_active, .bold = true }, bookmark_marker);
                continue;
            }

            // Diff anchor marker
            if (anchor_abs != null and abs_idx == anchor_abs.?) {
                try app_tui.writeStyled(.{ .fg = theme.usage_warn, .bold = true }, anchor_marker);
                continue;
            }

            // Get the snapshot and look up any events at that moment
            const snap = tl.getSnapshotAtIndex(abs_idx) orelse {
                try app_tui.bufWrite(" ");
                continue;
            };
            const ts = snap.timestamp_ms;
            const ev_mask = tl.eventMaskInRange(ts - 600, ts + 600);

            if (ev_mask & (@as(u8, 1) << @intFromEnum(timeline_mod.EventKind.thermal_high)) != 0) {
                try app_tui.writeStyled(.{ .fg = theme.usage_critical, .bold = true }, "T");
            } else if (ev_mask & (@as(u8, 1) << @intFromEnum(timeline_mod.EventKind.cpu_spike)) != 0) {
                try app_tui.writeStyled(.{ .fg = theme.usage_warn, .bold = true }, "C");
            } else if (ev_mask & (@as(u8, 1) << @intFromEnum(timeline_mod.EventKind.mem_pressure)) != 0) {
                try app_tui.writeStyled(.{ .fg = theme.memory_critical, .bold = true }, "M");
            } else if (ev_mask & (@as(u8, 1) << @intFromEnum(timeline_mod.EventKind.disk_spike)) != 0) {
                try app_tui.writeStyled(.{ .fg = theme.disk_title }, "D");
            } else if (ev_mask & (@as(u8, 1) << @intFromEnum(timeline_mod.EventKind.net_spike)) != 0) {
                try app_tui.writeStyled(.{ .fg = theme.network_title }, "N");
            } else if (ev_mask & (@as(u8, 1) << @intFromEnum(timeline_mod.EventKind.proc_birth)) != 0) {
                try app_tui.writeStyled(.{ .fg = theme.usage_good }, "+");
            } else if (ev_mask & (@as(u8, 1) << @intFromEnum(timeline_mod.EventKind.proc_death)) != 0) {
                try app_tui.writeStyled(.{ .fg = theme.muted }, "-");
            } else {
                // No event: show CPU density block
                const ch: []const u8 = cpuDensityChar(snap.cpu_usage_pct);
                try app_tui.writeStyled(.{ .fg = theme.muted }, ch);
            }
        }
    }

    // Right nav indicator
    try app_tui.bufWrite(" ");
    const can_go_newer = is_scrubbing and scrub_offset > 0;
    try app_tui.writeStyled(
        if (can_go_newer) .{ .fg = theme.tab_active, .bold = true } else .{ .fg = theme.muted },
        right_nav,
    );

    // Time label
    if (is_scrubbing) {
        if (tl.getSnapshot(0)) |newest| {
            if (tl.getSnapshot(scrub_offset)) |cur| {
                const delta_s = @divTrunc(newest.timestamp_ms - cur.timestamp_ms, 1000);
                var dur_buf: [16]u8 = undefined;
                const dur = timeline_mod.Timeline.formatDuration(&dur_buf, delta_s);
                var tbuf: [24]u8 = undefined;
                const label = std.fmt.bufPrint(&tbuf, "  T-{s}", .{dur}) catch "  T-?";
                try app_tui.writeStyled(.{ .fg = theme.usage_warn, .bold = true }, label);
            }
        }
    } else if (snap_count > 0) {
        var dur_buf: [16]u8 = undefined;
        const dur = timeline_mod.Timeline.formatDuration(&dur_buf, @intCast(snap_count));
        var tbuf: [24]u8 = undefined;
        const label = std.fmt.bufPrint(&tbuf, "  {s}", .{dur}) catch "  ?";
        try app_tui.writeStyled(.{ .fg = theme.muted }, label);
    }
}
